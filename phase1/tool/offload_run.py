"""Generate a job's beds on whatever GPU this is running on.

Deliberately standalone. This file and loopify.py are the whole of what has to
be uploaded alongside a job -- no repo, no theme cache, no phase0 import, no
Ollama. Every prompt was resolved by `offload.py export` before the job left
home, so this is a text-to-audio loop and nothing else.

    pip install torch transformers soundfile numpy
    python offload_run.py job.json --out beds
    #   then zip `beds` and take it home to `offload.py import`

On Modal, tool/offload_modal.py does all of that.

Rejection sampling happens **here**, with the GPU, rather than at home. A bed
that fails the audibility guard needs generating again with a different seed,
and deciding that across a network would mean shipping rejects both ways.

Batch size comes from the job, and it is the reason for going to another
machine at all: batch 2 needs about 9.8 GiB at guidance 3.0, which the 8 GB
laptop this was written on cannot hold without spilling into system RAM.

Be careful reading VRAM figures across guidance settings -- classifier-free
guidance doubles the effective batch, so the 11.7 GiB measured for batch 4 was
at guidance 1.0, and batch 4 at guidance 3.0 is about 17.4 GiB and will not fit
a 16 GB card. On 16 GB, batch 2 is safe and batch 3 (about 13.6 GiB,
extrapolated rather than measured) is worth trying. Pass --batch to override
whatever the job asked for.
"""

import argparse
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import loopify  # noqa: E402


def load_model(name: str, guidance: float, tokens: int):
    import torch
    from transformers import AutoProcessor, MusicgenForConditionalGeneration

    device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cpu":
        print("!  no CUDA device; this will be extremely slow", file=sys.stderr)
    else:
        total = torch.cuda.get_device_properties(0).total_memory / 2**30
        print(f"{torch.cuda.get_device_name(0)}, {total:.1f} GiB")

    started = time.time()
    processor = AutoProcessor.from_pretrained(name)
    model = MusicgenForConditionalGeneration.from_pretrained(
        name, dtype=torch.float16 if device == "cuda" else torch.float32,
    ).to(device)
    print(f"loaded {name} in {time.time() - started:.1f}s")

    def generate(prompts: list[str], seed: int):
        torch.manual_seed(seed)
        inputs = processor(text=prompts, padding=True,
                           return_tensors="pt").to(device)
        with torch.no_grad():
            audio = model.generate(**inputs, do_sample=True,
                                   guidance_scale=guidance,
                                   max_new_tokens=tokens)
        return [audio[i].to(torch.float32).cpu().numpy().T
                for i in range(audio.shape[0])]

    return generate, model.config.audio_encoder.sampling_rate


def run_set(spec: dict, generate, rate: int, settings: dict, out: Path,
            batch: int, deadline: float | None = None) -> list[dict]:
    """One bed set, in waves: every bed at its first seed, then what still fails.

    Per bed that is seeds in sequence stopping at the first pass, which is what
    the local generator does. Grouping them is what lets several share a decode
    loop.

    A job may ask for several takes of one cue -- that is what the allocation is
    for. Takes share a prompt, so they must not share a seed, and each owns a
    disjoint run of `attempts` seeds so a re-seeded reject cannot collide with
    another take either. The job carries each take's first seed, resolved by
    generate_beds.seed_base at export, so this side has no seed scheme of its
    own to drift -- which it once had, without the band in it.

    Every take is kept, usable or not. The job is the over-generated pool;
    choosing among it is the cull's job, at home on import.

    Resumable. A take that passes the guard is written with its report
    beside it (`<stem>.report.json`, after the audio, so a report means the
    audio is whole), and a run that finds one does not generate that take
    again. Cloud GPUs are preemptible -- Modal restarts a preempted function
    on the same input, and GPU functions cannot opt out -- so without this a
    preemption two hours in would start the set over, and bill for it twice.

    [deadline] (a time.time() value) stops it starting anything new, so a
    session with a hard limit -- Kaggle's is about 12 hours -- ends by writing
    its manifest rather than being killed before it can. A take that was never
    started has no row; import reports it missing rather than guessing.
    """
    out.mkdir(parents=True, exist_ok=True)
    wanted = {c.get("stem", c["cue"]): c for c in spec["cues"]}
    best: dict[str, tuple] = {}
    pending = list(wanted)
    for stem in list(pending):
        done = out / f"{stem}.report.json"
        if done.exists() and (out / f"{stem}.wav").exists():
            best[stem] = (None, None, None,
                          json.loads(done.read_text(encoding="utf-8")))
            pending.remove(stem)
    if len(pending) < len(wanted):
        print(f"  resuming: {len(wanted) - len(pending)} of {len(wanted)} "
              f"take(s) already settled", flush=True)

    def out_of_time() -> bool:
        return deadline is not None and time.time() > deadline

    for attempt in range(settings["attempts"]):
        if not pending or out_of_time():
            break
        # Takes that share a first seed share a decode loop: one seed per
        # batch, as in the local generator's (variant, band) groups.
        for base in sorted({wanted[c]["seed_base"] for c in pending}):
            group = [c for c in pending if wanted[c]["seed_base"] == base]
            seed = base + attempt
            for at in range(0, len(group), max(1, batch)):
                if out_of_time():
                    break
                chunk = group[at:at + max(1, batch)]
                started = time.time()
                clips = generate([wanted[c]["prompt"] for c in chunk], seed)
                each = (time.time() - started) / len(chunk)
                for stem, clip in zip(chunk, clips):
                    loop, report = loopify.process(clip, rate)
                    report["seed"] = seed
                    report["attempt"] = attempt + 1
                    report["batch"] = len(chunk)
                    why = ("" if report["usable"]
                           else "   rejected: too quiet to hear"
                           if not report["audible"]
                           else "   rejected: no body, all top end")
                    print(f"  {stem:16s} seed {seed}  {each:5.1f}s  "
                          f"{100 * report['energy_above_200hz']:5.1f}% "
                          f"above 200 Hz"
                          f"  centroid {report['centroid_hz']:6.0f} Hz{why}",
                          flush=True)
                    distance = abs(math.log((report["centroid_hz"] or 1) / 600))
                    rank = (not report["usable"], distance)
                    if stem not in best or rank < best[stem][0]:
                        best[stem] = (rank, clip, loop, report)
                    # Written as soon as it settles: a long run on a free tier
                    # can be cut off at any moment, and a session that dies must
                    # still leave behind everything it finished.
                    if report["usable"]:
                        loopify.write_wav_at(
                            out / f"{stem}.raw.wav", clip, rate)
                        loopify.write_wav(out / f"{stem}.wav", loop)
                        (out / f"{stem}.report.json").write_text(
                            json.dumps(report), encoding="utf-8")
        pending = [c for c in pending
                   if c not in best or not best[c][3]["usable"]]

    rows = []
    for stem, spec_cue in wanted.items():
        if stem not in best:
            continue  # never started: the deadline came first
        _, clip, loop, report = best[stem]
        if not report["usable"]:
            loopify.write_wav_at(out / f"{stem}.raw.wav", clip, rate)
            loopify.write_wav(out / f"{stem}.wav", loop)
        rows.append({
            "cue": spec_cue["cue"],
            "variant": spec_cue.get("variant", 0),
            "mood": spec_cue["mood"],
            "band": spec_cue["band"],
            "band_name": spec_cue["band_name"],
            "file": f"{stem}.wav",
            "description": spec_cue["prompt"],
            "model": settings["model"],
            "guidance": settings["guidance"],
            "key": spec_cue.get("key"),
            "source": "generated by phase1/tool/offload_run.py",
            "license": "see the model card for " + settings["model"],
            "attribution": None,
            **report,
        })

    (out / "manifest.json").write_text(
        json.dumps({
            "library": f"generated for {spec.get('arc', 'book')}",
            "note": "Generated off-machine; see tool/offload.py.",
            "arc": spec.get("arc"),
            "theme": spec["theme"],
            "loops": sorted(rows, key=lambda r: (r["cue"], r["variant"])),
        }, indent=2) + "\n", encoding="utf-8")
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job")
    parser.add_argument("--out", default="beds")
    parser.add_argument("--batch", type=int, default=None,
                        help="override the job's batch size for this card")
    parser.add_argument("--sets", type=int, default=0, metavar="N",
                        help="stop after N sets, to fit a session limit")
    parser.add_argument("--stop-after", type=float, default=0, metavar="S",
                        help="start nothing new after S seconds from launch, "
                             "and write what settled -- for a session with a "
                             "hard limit")
    args = parser.parse_args()
    launched = time.time()
    deadline = launched + args.stop_after if args.stop_after else None

    job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    settings = job["settings"]
    if any("seed_base" not in c for s in job["sets"] for c in s["cues"]):
        raise SystemExit("this job has no seed_base per take, so it predates "
                         "the band-aware seed scheme; re-export it with "
                         "tool/offload.py export")
    batch = args.batch or settings.get("batch", 1)
    out = Path(args.out).resolve()

    sets = job["sets"][:args.sets] if args.sets else job["sets"]
    beds = sum(len(s["cues"]) for s in sets)
    print(f"{job['book']}: {len(sets)} set(s), {beds} bed(s), batch {batch}")

    tokens = settings["seconds"] * settings["tokens_per_second"]
    generate, rate = load_model(settings["model"], settings["guidance"], tokens)

    started = time.time()
    unusable, not_started = [], []
    for spec in sets:
        print(f"\n== {spec['dir']}: {spec['theme']['genre_seed']} / "
              f"{spec['theme']['overall_theme']}", flush=True)
        rows = run_set(spec, generate, rate, settings, out / spec["dir"], batch,
                       deadline=deadline)
        unusable += [f"{spec['dir']}/{r['file'][:-4]}"
                     for r in rows if not r["usable"]]
        done = {r["file"][:-4] for r in rows}
        not_started += [f"{spec['dir']}/{c['stem']}" for c in spec["cues"]
                        if c["stem"] not in done]

    took = time.time() - started
    (out / "results.json").write_text(
        json.dumps({
            "book": job["book"],
            "sets": [s["dir"] for s in sets],
            "beds": beds,
            "unusable": unusable,
            "not_started": not_started,
            "seconds": round(took, 1),
            "batch": batch,
        }, indent=2) + "\n", encoding="utf-8")

    print(f"\n{beds - len(not_started)} of {beds} bed(s) in "
          f"{took / 60:.1f} min -> {out}")
    if unusable:
        print(f"{len(unusable)} never passed the guard, least-bad take kept: "
              f"{', '.join(unusable)}")
    if not_started:
        print(f"{len(not_started)} not started before --stop-after; export "
              f"them as a job of their own and import both results")
    print("zip this directory and run: python tool/offload.py import "
          f"--job {Path(args.job).name} --results <unzipped>")


if __name__ == "__main__":
    main()
