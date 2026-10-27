"""The offload round trip, without a GPU: the runner's seeds, and the cull at
home on import.

Run: python framework/python/tests/test_jobs.py

Ported from phase1/tool/test_offload.py. The import step installs into
a workspace rather than an --out directory; nothing else changed.

What this exists for. The offload path had quietly fallen behind the local
generator (SUMMARY 9.37): its jobs asked for no over-generation, so nothing was
ever culled; its runner seeded takes without the band, so tense-0-v3 and
tense-1-v3 shared a seed; and its prompts were forced into positive-only
phrasing while every local set since 9.31 is negated. None of that failed --
it would have produced a different kind of set, silently, on someone else's
GPU. So what is pinned here is that a job's pool comes home and is chosen by
the same cull_by_movement a local run uses, with the local seed scheme.

The model is a stub that makes synthetic audio from the seed. Everything else
is real: offload_run.run_set, loopify, the guard, verify, bench_palette's
measurements and the cull. No GPU, no model, no real book.
"""

import argparse
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from music_book_gen import jobs, loopify
from music_book_gen import measure as bench_palette
from music_book_gen import prompts as gb
from music_book_gen import runner as offload_run
from music_book_gen.workspace import Workspace

RATE = 32000
ATTEMPTS = 2
PLAN = {"calm-0": 1, "tense-0": 2, "tense-1": 2}

# Fundamental per (band, variant). Each tense band has one take whose register
# belongs to the other band, which is what the gate is for.
F0 = {(0, 0): 220, (0, 1): 260, (0, 2): 900, (0, 3): 300,
      (1, 0): 700, (1, 1): 800, (1, 2): 250, (1, 3): 850}


def fake_generate(prompts: list[str], seed: int, tried: list):
    """Synthetic clips, decided by the seed alone -- as a real model's are,
    for a given prompt. calm-0-v1 is a sub-bass drone at every seed it will
    try, so it never passes the guard and comes home as the least-bad take."""
    band, rest = divmod(seed, gb.BAND_SEED_STRIDE)
    variant, attempt = divmod(rest, ATTEMPTS)
    clips = []
    for prompt in prompts:
        tried.append((prompt, seed))
        t = np.arange(30 * RATE) / RATE
        if prompt.startswith("calm") and variant == 1:
            x = 0.2 * np.sin(2 * np.pi * 40 * t)
        else:
            f0 = F0[band, variant]
            tone = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in range(1, 5))
            wobble = 0.6 + 0.4 * np.sin(2 * np.pi * (1 + variant) * t)
            x = 0.1 * tone * wobble
        clips.append(np.stack([x, x], axis=1).astype(np.float32))
    return clips


def make_job() -> dict:
    cues = []
    for slot in gb.slots_for(["calm", "tense"], "full", PLAN, overgen=2):
        cues.append({
            "stem": slot["stem"], "cue": slot["cue"],
            "variant": slot["variant"], "keep": slot["keep"],
            "mood": slot["mood"], "band": slot["band"],
            "band_name": gb.BAND_NAMES[slot["band"]],
            "seed_base": gb.seed_base(0, slot["band"], slot["variant"],
                                      ATTEMPTS),
            "key": "G minor",
            "prompt": f"{slot['cue']} prompt",
        })
    return {
        "book": "test-book", "palette": "full",
        "settings": {"model": "stub", "seconds": 30, "tokens_per_second": 50,
                     "guidance": 3.0, "attempts": ATTEMPTS, "seed": 0,
                     "batch": 4, "overgen": 2, "register_gate": True,
                     "phrasing": "negated"},
        "boundaries": [{"index": 0, "start": 0, "end": 9, "palette": 0}],
        "sets": [{"dir": "arc-000", "arc": 0, "start": 0, "end": 9,
                  "title": "", "theme": {"genre_seed": "test",
                                         "overall_theme": "test",
                                         "instrumentation": "test"},
                  "cues": cues}],
    }


def import_into(job_path: Path, results, home: Path, force=False):
    """[results] is one directory or a list of them. [home] becomes a
    workspace -- the framework installs into one, not an --out dir."""
    folders = results if isinstance(results, list) else [results]
    home.mkdir(parents=True, exist_ok=True)
    if not (home / "workspace.json").exists():
        (home / "workspace.json").write_text(json.dumps(
            {"format": 1, "book": "test-book", "title": "t"}))
        (home / "arcs.json").write_text(json.dumps({"arcs": [
            {"index": 0, "start": 0, "end": 9, "title": "",
             "palette": 0}]}))
    job = json.loads(job_path.read_text(encoding="utf-8"))
    jobs.import_results(job, [Path(f) for f in folders],
                        Workspace(home), force=force)


def far_side(root: Path) -> tuple[Path, Path, dict, list]:
    """Export a job, run it through the real runner. Returns the job file,
    the results directory, the job, and every (prompt, seed) tried."""
    job = make_job()
    job_path = root / "job.json"
    job_path.write_text(json.dumps(job), encoding="utf-8")
    tried: list = []
    results = root / "beds"
    offload_run.run_set(job["sets"][0],
                        lambda p, s: fake_generate(p, s, tried), RATE,
                        job["settings"], results / "arc-000", batch=4)
    return job_path, results, job, tried


def seeds_follow_seed_base(job: dict, results: Path, tried: list):
    rows = json.loads((results / "arc-000" / "manifest.json").read_text())
    rows = {(r["cue"], r["variant"]): r for r in rows["loops"]}
    for cue in job["sets"][0]["cues"]:
        row = rows[cue["cue"], cue["variant"]]
        assert row["seed"] == cue["seed_base"] + row["attempt"] - 1, (
            cue["stem"], row["seed"], cue["seed_base"])
    # The bug this replaces: tense-0-vN and tense-1-vN on one seed.
    by_band = {b: {s for p, s in tried if p.startswith(f"tense-{b}")}
               for b in (0, 1)}
    assert not by_band[0] & by_band[1], by_band[0] & by_band[1]
    print("  ok  every take is seeded from its seed_base, and the bands of "
          "a mood never share a seed")


def pool_comes_home_whole(job: dict, results: Path):
    on_disk = {p.name for p in (results / "arc-000").glob("*.wav")
               if not p.name.endswith(".raw.wav")}
    want = {f"{c['stem']}.wav" for c in job["sets"][0]["cues"]}
    assert on_disk == want, sorted(on_disk ^ want)
    rows = json.loads((results / "arc-000" / "manifest.json").read_text())
    calm_v1 = next(r for r in rows["loops"]
                   if r["cue"] == "calm-0" and r["variant"] == 1)
    assert not calm_v1["usable"], calm_v1
    print("  ok  the runner writes every take of the pool, usable or not")


def cull_runs_at_home(job_path: Path, results: Path, root: Path):
    home = root / "home"
    import_into(job_path, results, home)
    manifest = json.loads((home / "arc-000" / "manifest.json").read_text())
    rows = manifest["loops"]
    for cue, keep in PLAN.items():
        got = sorted(r["variant"] for r in rows if r["cue"] == cue)
        assert got == list(range(keep)), (cue, got)
    names = {r["file"] for r in rows}
    beds = {p.name for p in (home / "arc-000").glob("*.wav")
            if not p.name.endswith(".raw.wav")}
    assert names == beds, sorted(names ^ beds)
    # calm-0-v1 never passed the guard; the usable take is the one kept.
    calm = next(r for r in rows if r["cue"] == "calm-0")
    assert calm["usable"] and "register" not in calm, calm
    # Both tense bands went through the gate, and it filled them, so no still
    # take is brighter than any peak take -- the whole point of it.
    tense = [r for r in rows if r["mood"] == "tense"]
    assert all(r["register"]["inside"] for r in tense), tense
    bright = {b: [bench_palette.measure(home / "arc-000" / r["file"])
                  ["centroid"] for r in tense if r["band"] == b]
              for b in (0, 1)}
    assert max(bright[0]) <= min(bright[1]), bright
    assert all("movement" in r for r in rows)
    assert (home / "palette.json").exists()
    # The download is untouched, so the pool can be culled again.
    assert len(list((results / "arc-000").glob("*.raw.wav"))) == 10
    print("  ok  import culls the pool with the local cull and the register "
          "gate, and installs only the survivors")


def truncated_download_is_refused(job_path: Path, results: Path, root: Path):
    broken = root / "broken"
    shutil.copytree(results, broken)
    victim = broken / "arc-000" / "tense-0-v1.wav"
    loopify.write_wav(victim, np.zeros((RATE * 2, 2), dtype=np.float32))
    try:
        import_into(job_path, broken, root / "refused")
    except SystemExit as refusal:
        assert "refusing" in str(refusal), refusal
    else:
        raise AssertionError("a truncated take was installed")
    assert not (root / "refused" / "arc-000").exists()

    import_into(job_path, broken, root / "forced", force=True)
    rows = json.loads(
        (root / "forced" / "arc-000" / "manifest.json").read_text())["loops"]
    assert sum(1 for r in rows if r["cue"] == "tense-0") == 2, rows
    print("  ok  a truncated take is refused; --force culls the rest without it")


def a_rerun_resumes(job: dict, results: Path, root: Path):
    # A preempted container restarts on the same input. Everything that had
    # passed the guard must be picked up rather than generated again; only
    # calm-0-v1, which never passed, is tried again -- at the same seeds.
    again = root / "again"
    shutil.copytree(results, again)
    (again / "arc-000" / "manifest.json").unlink()
    tried: list = []
    offload_run.run_set(job["sets"][0],
                        lambda p, s: fake_generate(p, s, tried), RATE,
                        job["settings"], again / "arc-000", batch=4)
    assert sorted(tried) == [("calm-0 prompt", 2), ("calm-0 prompt", 3)], tried
    rows = json.loads((again / "arc-000" / "manifest.json").read_text())
    assert len(rows["loops"]) == 10, len(rows["loops"])
    before = json.loads((results / "arc-000" / "manifest.json").read_text())
    assert ([(r["cue"], r["variant"], r["seed"]) for r in rows["loops"]]
            == [(r["cue"], r["variant"], r["seed"]) for r in before["loops"]])
    print("  ok  a rerun resumes from what settled, and regenerates only "
          "what never passed")


def a_split_pool_imports_as_one(job: dict, job_path: Path, results: Path,
                                root: Path):
    # Kaggle's two GPUs each come home as a directory of their own. Dealt
    # round-robin and imported together, they must give exactly the set one
    # directory gives.
    halves = [root / "gpu0", root / "gpu1"]
    source = results / "arc-000"
    manifest = json.loads((source / "manifest.json").read_text())
    for k, half in enumerate(halves):
        (half / "arc-000").mkdir(parents=True)
        mine = [c["stem"] for c in job["sets"][0]["cues"][k::2]]
        for stem in mine:
            for suffix in (".wav", ".raw.wav"):
                shutil.copyfile(source / f"{stem}{suffix}",
                                half / "arc-000" / f"{stem}{suffix}")
        rows = [r for r in manifest["loops"] if r["file"][:-4] in mine]
        (half / "arc-000" / "manifest.json").write_text(
            json.dumps(dict(manifest, loops=rows)))
    import_into(job_path, halves, root / "split")
    import_into(job_path, results, root / "whole")
    got = [json.loads((root / where / "arc-000" / "manifest.json").read_text())
           ["loops"] for where in ("split", "whole")]
    assert ([(r["cue"], r["variant"], r["seed"]) for r in got[0]]
            == [(r["cue"], r["variant"], r["seed"]) for r in got[1]]), got
    print("  ok  a pool split across two GPUs imports as the same set")


def a_spent_deadline_writes_an_empty_manifest(job: dict, root: Path):
    # --stop-after that has already run out: nothing starts, nothing crashes,
    # and the manifest says so rather than being absent.
    out = root / "late" / "arc-000"
    tried: list = []
    rows = offload_run.run_set(job["sets"][0],
                               lambda p, s: fake_generate(p, s, tried), RATE,
                               job["settings"], out, batch=4,
                               deadline=time.time() - 1)
    assert rows == [] and tried == [], (rows, tried)
    assert json.loads((out / "manifest.json").read_text())["loops"] == []
    print("  ok  a runner past its deadline starts nothing and still writes "
          "its manifest")


def an_old_job_is_refused_by_the_runner(root: Path):
    job = make_job()
    for cue in job["sets"][0]["cues"]:
        del cue["seed_base"]
    path = root / "old.json"
    path.write_text(json.dumps(job), encoding="utf-8")
    argv = sys.argv
    sys.argv = ["offload_run.py", str(path), "--out", str(root / "old")]
    try:
        offload_run.main()
    except SystemExit as refusal:
        assert "seed_base" in str(refusal), refusal
    else:
        raise AssertionError("a job without seed_base ran")
    finally:
        sys.argv = argv
    print("  ok  a job from before seed_base is refused, not run on a "
          "different seed scheme")


if __name__ == "__main__":
    root = Path(tempfile.mkdtemp())
    try:
        print("offload round trip")
        job_path, results, job, tried = far_side(root)
        seeds_follow_seed_base(job, results, tried)
        pool_comes_home_whole(job, results)
        cull_runs_at_home(job_path, results, root)
        truncated_download_is_refused(job_path, results, root)
        a_rerun_resumes(job, results, root)
        a_split_pool_imports_as_one(job, job_path, results, root)
        a_spent_deadline_writes_an_empty_manifest(job, root)
        an_old_job_is_refused_by_the_runner(root)
        print("all passed")
    finally:
        shutil.rmtree(root, ignore_errors=True)
