"""Generation jobs: out of a workspace, and back into it.

A job is every take of a bed set's over-generated pool, with its prompt and
its first seed already resolved, so whatever runs it -- runner.py on this
machine, on Kaggle, on Modal, anywhere -- needs no book, no themes and no
rules of its own. It holds prompts, keys and seeds: **no book text**.

    export   workspace -> job        (themes.json, arcs.json, allocation.json)
    import   pool      -> workspace  (verify every file, cull at home, install
                                      the survivors as arc-NNN/, write
                                      palette.json, measure the distances)

The movement cull and the register gate run here, on import, through
cull.cull_by_movement -- one cull whatever ran the job -- and the pool that came
home is left untouched so it can be culled again.

Adapted from phase1/tool/offload.py; what changed is only where things are
read from and written to (a workspace rather than the reader app's caches).
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from . import loopify
from . import measure
from .cull import cull_by_movement
from .prompts import (BAND_NAMES, MOOD_MODE, MOOD_PARAMS, SECONDS,
                      TOKENS_PER_SECOND, allocation_for, guard_rank,
                      prompt_for, seed_base, slots_for, tonic_for)
from .workspace import Workspace

DEFAULT_MODEL = "facebook/musicgen-stereo-medium"


def export_job(ws: Workspace, arcs: list[int] | None = None, *,
               overgen: int = 2, model: str = DEFAULT_MODEL,
               guidance: float = 3.0, attempts: int = 4, seed: int = 0,
               batch: int = 2, positive_only: bool = False,
               register_gate: bool = True, palette: str = "full") -> dict:
    """The job for [arcs] (default: every set that has an allocation).

    Only arcs that *represent* a set are exported -- an arc grouped onto an
    earlier one plays that one's beds. An arc with no plan is exported at one
    bed per cue, which is what the generator did before allocation existed.
    """
    themes = ws.themes()
    allocation = ws.allocation()
    boundaries = ws.arcs()
    representing = [a for a in boundaries if a.get("palette", a["index"])
                    == a["index"]]
    if arcs is None:
        planned = {s["palette"] for s in allocation.get("sets", [])}
        chosen = [a for a in representing if a["index"] in planned]
    else:
        chosen = [a for a in representing if a["index"] in arcs]
        missing = set(arcs) - {a["index"] for a in chosen}
        if missing:
            raise SystemExit(f"arc(s) {sorted(missing)} do not represent a "
                             "set: they play another arc's beds, or do not "
                             "exist")
    if not chosen:
        raise SystemExit("nothing to export: run `music_book plan` first")

    sets = []
    for arc in chosen:
        theme = themes.get("arcs", {}).get(str(arc["index"]))
        if theme is None:
            raise SystemExit(f"arc {arc['index']} has no theme: run "
                             "`music_book arcs` first")
        # Seeded from the set's identity, so re-running one cue lands in the
        # key of the beds it sits beside (see tonic_for).
        theme = dict(theme, key_seed=f"{ws.book_id}#arc{arc['index']}")
        plan = allocation_for(allocation, arc["index"])
        sets.append({
            "dir": f"arc-{arc['index']:03d}",
            "arc": arc["index"],
            "start": arc["start"],
            "end": arc["end"],
            "theme": {k: theme[k] for k in
                      ("genre_seed", "overall_theme", "instrumentation")},
            "cues": [
                {
                    "stem": slot["stem"],
                    "cue": slot["cue"],
                    "variant": slot["variant"],
                    "keep": slot["keep"],
                    "mood": slot["mood"],
                    "band": slot["band"],
                    "band_name": (None if slot["band"] is None
                                  else BAND_NAMES[slot["band"]]),
                    "seed_base": seed_base(seed, slot["band"],
                                           slot["variant"], attempts),
                    "key": f"{tonic_for(theme)} "
                           f"{MOOD_MODE.get(slot['mood'], 'minor')}",
                    "prompt": prompt_for(slot["mood"], theme,
                                         positive_only=positive_only,
                                         band=slot["band"]),
                }
                for slot in slots_for(sorted(MOOD_PARAMS), palette, plan,
                                      overgen=overgen)
            ],
        })
    return {
        "book": ws.book_id,
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "palette": palette,
        "settings": {
            "model": model,
            "seconds": SECONDS,
            "tokens_per_second": TOKENS_PER_SECOND,
            "guidance": guidance,
            "attempts": attempts,
            "seed": seed,
            "batch": batch,
            "overgen": overgen,
            "register_gate": register_gate,
            "phrasing": "positive-only" if positive_only else "negated",
        },
        "sets": sets,
    }


def verify(path: Path, claimed: dict) -> tuple[str | None, dict]:
    """Re-measure a returned bed instead of believing what came with it.

    Returns (problem, measured). A problem means the file is not what the far
    side says it is -- missing, unreadable, the wrong length or rate, or
    measuring differently from its row -- and that take is not installed. An
    inaudible bed is not a problem: the pool is returned usable or not, and
    the cull decides, on the guard's verdict recomputed here.
    """
    if not path.exists():
        return "missing", {}
    try:
        audio, rate = loopify.load(path)
    except Exception as error:  # noqa: BLE001 -- any unreadable file fails
        return f"unreadable ({type(error).__name__})", {}
    expected = int(loopify.SAMPLE_RATE * loopify.LOOP_SECONDS)
    if rate != loopify.SAMPLE_RATE:
        return f"rate {rate}, expected {loopify.SAMPLE_RATE}", {}
    if abs(audio.shape[0] - expected) > rate // 10:
        return (f"{audio.shape[0] / rate:.1f}s, expected "
                f"{loopify.LOOP_SECONDS:.0f}s"), {}
    audible = loopify.energy_above(audio, loopify.SPEAKER_FLOOR_HZ, rate)
    centroid = loopify.centroid_hz(audio, rate)
    said = claimed.get("energy_above_200hz")
    if said is not None and abs(said - audible) > 0.05:
        return (f"manifest says {100 * said:.1f}% above 200 Hz, "
                f"file measures {100 * audible:.1f}%"), {}
    loud = audible >= loopify.MIN_ENERGY_ABOVE_FLOOR
    return None, {
        "energy_above_200hz": round(audible, 4),
        "centroid_hz": round(centroid, 1),
        "audible": bool(loud),
        "usable": bool(loud and centroid <= loopify.MAX_CENTROID_HZ),
    }


def merge_loops(manifest_path: Path, entries: list[dict]) -> list[dict]:
    """Fresh rows laid over whatever the manifest had, keyed by cue and take."""
    existing: list[dict] = []
    if manifest_path.exists():
        try:
            existing = json.loads(
                manifest_path.read_text(encoding="utf-8")).get("loops", [])
        except (json.JSONDecodeError, OSError):
            existing = []

    def key(row):
        return (row.get("cue") or row["mood"], row.get("variant") or 0)

    merged = {key(row): row for row in existing}
    for row in entries:
        merged[key(row)] = row
    return sorted(merged.values(), key=key)


def import_results(job: dict, results: list[Path], ws: Workspace, *,
                   force: bool = False, distances: bool = True) -> list[str]:
    """Verify the returned pool, cull it, install the survivors into [ws].

    [results] are one or more directories the runner wrote -- one per GPU on
    Kaggle, or a second job for takes a first ran out of time for -- merged
    into one pool. Refuses (SystemExit) on any take that is not what its row
    claims, unless [force], which culls and installs what did verify.
    Returns the set directories installed.
    """
    settings = job["settings"]
    total, bad, staged = 0, [], []
    for spec in job["sets"]:
        rows = {}
        for folder in results:
            manifest_path = folder / spec["dir"] / "manifest.json"
            if not manifest_path.exists():
                continue
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for row in manifest.get("loops", []):
                key = (row.get("cue") or row["mood"], row.get("variant") or 0)
                rows[key] = (row, folder / spec["dir"])
        if not rows:
            print(f"  {spec['dir']}: no manifest in any results directory, "
                  "skipped", file=sys.stderr)
            continue
        pool = {}
        for cue in spec["cues"]:
            total += 1
            stem = cue.get("stem", cue["cue"])
            hit = rows.get((cue["cue"], cue.get("variant", 0)))
            if hit is None:
                bad.append(f"{spec['dir']}/{stem}: not in any manifest")
                continue
            row, source = hit
            problem, measured = verify(source / row["file"], row)
            if problem:
                bad.append(f"{spec['dir']}/{stem}: {problem}")
                continue
            pool[stem] = (cue, dict(row, **measured), source)
        staged.append((spec, pool))

    print(f"{total - len(bad)}/{total} take(s) verified")
    for line in bad:
        print(f"  ! {line}")
    if bad and not force:
        raise SystemExit("refusing to install a set with failures; fix them, "
                         "regenerate those takes, or pass --force to cull and "
                         "install what did verify")

    gate = settings.get("register_gate", True)
    installed = []
    for spec, pool in staged:
        target = ws.root / spec["dir"]
        entries = []
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            wanted, best = {}, {}
            for stem, (cue, row, source) in pool.items():
                for suffix in (".wav", ".raw.wav"):
                    origin = source / f"{stem}{suffix}"
                    if origin.exists():
                        shutil.copyfile(origin, work / f"{stem}{suffix}")
                keep = cue.get("keep") or sum(
                    1 for c in spec["cues"] if c["cue"] == cue["cue"])
                wanted[stem] = {"stem": stem, "cue": cue["cue"],
                                "mood": cue["mood"], "band": cue["band"],
                                "variant": cue.get("variant", 0),
                                "keep": keep, "prompt": cue["prompt"]}
                best[stem] = (guard_rank(row), None, None, row)
            survivors = cull_by_movement(work, wanted, best,
                                         register_gate=gate)
            target.mkdir(parents=True, exist_ok=True)
            for new, slot in survivors.items():
                for suffix in (".wav", ".raw.wav"):
                    origin = work / f"{new}{suffix}"
                    if origin.exists():
                        shutil.copyfile(origin, target / f"{new}{suffix}")
                row = dict(best[new][3], file=f"{new}.wav",
                           variant=slot["variant"])
                if not row["usable"]:
                    print(f"  !  {spec['dir']}/{new}: no take of this cue "
                          "passed the guard; the least-bad was kept")
                entries.append(row)

        manifest = {
            "library": f"generated for {ws.book_id} arc {spec['arc']}",
            "note": "Generated by framework/python (music_book_gen), culled "
                    "and installed on import.",
            "book": ws.book_id,
            "palette": job.get("palette", "full"),
            "arc": spec["arc"],
            "theme": spec["theme"],
            "loops": merge_loops(target / "manifest.json", entries),
        }
        (target / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"  installed {len(entries)} of {len(pool)} take(s) in {target}")
        # A set without measured distances never leads into a change: every
        # pair reads as the set's average. Cheap, and needs no GPU.
        if distances:
            measure.write_distances(target)
        installed.append(str(target))

    # The cues this plan makes, not every cue the palette could have.
    ws.write_palette(job.get("palette", "full"),
                     len({c["cue"] for s in job["sets"] for c in s["cues"]}))
    return installed
