"""The generation half, from the command line.

    python -m music_book_gen prompts  <workspace> --arc N
    python -m music_book_gen export   <workspace> [--arc N ...] --out job.json
    python -m music_book_gen generate <workspace> --arc N        (this GPU)
    python -m music_book_gen import   <workspace> --job job.json --results D [D ...]
    python -m music_book_gen measure  <set dir>
    python -m music_book_gen kaggle   push|status|pull ...

`generate` is export, then runner.py on this machine's GPU as a process of its
own, then import -- the same three steps a cloud run takes, so a set made here
and a set made on Kaggle go through one generation loop and one cull.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from . import jobs, kaggle, measure
from .workspace import Workspace

PACKAGE = Path(__file__).resolve().parent


def _job_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--overgen", type=int, default=2, metavar="N",
                        help="generate N takes for every one the plan keeps; "
                             "the cull at import keeps the stillest (band 0) "
                             "or busiest (band 1). 3 moves the kept floor from "
                             "the median to the 33rd percentile (SUMMARY 9.36)")
    parser.add_argument("--model", default=jobs.DEFAULT_MODEL)
    parser.add_argument("--guidance", type=float, default=3.0)
    parser.add_argument("--attempts", type=int, default=4,
                        help="re-seeds before a take is given up on")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--positive-only", action="store_true",
                        help="phrase the constraint without negations")
    parser.add_argument("--no-register-gate", action="store_true",
                        help="cull on movement alone")


def _export(ws: Workspace, args, batch: int) -> dict:
    return jobs.export_job(
        ws, args.arc, overgen=args.overgen, model=args.model,
        guidance=args.guidance, attempts=args.attempts, seed=args.seed,
        batch=batch, positive_only=args.positive_only,
        register_gate=not args.no_register_gate)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="music_book_gen",
                                     description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("prompts", help="print what would be asked, no GPU")
    p.add_argument("workspace")
    p.add_argument("--arc", type=int, nargs="*", default=None)
    _job_options(p)

    p = sub.add_parser("export", help="write a job for any GPU")
    p.add_argument("workspace")
    p.add_argument("--arc", type=int, nargs="*", default=None)
    p.add_argument("--out", required=True)
    p.add_argument("--batch", type=int, default=2,
                   help="beds per decode loop on the far side; 2 fits 16 GB")
    _job_options(p)

    p = sub.add_parser("generate", help="export, run on this GPU, import")
    p.add_argument("workspace")
    p.add_argument("--arc", type=int, nargs="+", required=True)
    p.add_argument("--batch", type=int, default=1,
                   help="1 on an 8 GB card (batch 2 spills to system RAM)")
    _job_options(p)

    p = sub.add_parser("import", help="verify, cull and install a pool")
    p.add_argument("workspace")
    p.add_argument("--job", required=True)
    p.add_argument("--results", required=True, nargs="+")
    p.add_argument("--force", action="store_true")
    p.add_argument("--no-distances", action="store_true")

    p = sub.add_parser("measure", help="write a set's distance table")
    p.add_argument("set_dir")

    p = sub.add_parser("kaggle", help="push|status|pull on Kaggle's GPUs")
    p.add_argument("rest", nargs=argparse.REMAINDER)

    args = parser.parse_args(argv)

    if args.command == "kaggle":
        kaggle.main(args.rest)
        return
    if args.command == "measure":
        measure.write_distances(Path(args.set_dir))
        return

    ws = Workspace(args.workspace)
    if args.command == "prompts":
        job = _export(ws, args, batch=1)
        for spec in job["sets"]:
            print(f"== {spec['dir']}: {spec['theme']['genre_seed']} / "
                  f"{spec['theme']['overall_theme']}")
            for cue in spec["cues"]:
                if cue["variant"] == 0:
                    takes = sum(1 for c in spec["cues"]
                                if c["cue"] == cue["cue"])
                    print(f"  [{cue['cue']}] {takes} take(s), keep "
                          f"{cue['keep']}, seeds from {cue['seed_base']}, "
                          f"{cue['key']}\n    {cue['prompt']}\n")
        return
    if args.command == "export":
        job = _export(ws, args, batch=args.batch)
        Path(args.out).write_text(json.dumps(job, indent=2) + "\n",
                                  encoding="utf-8")
        takes = sum(len(s["cues"]) for s in job["sets"])
        print(f"{args.out}: {len(job['sets'])} set(s), {takes} take(s)")
        return
    if args.command == "import":
        job = json.loads(Path(args.job).read_text(encoding="utf-8"))
        jobs.import_results(job, [Path(r) for r in args.results], ws,
                            force=args.force,
                            distances=not args.no_distances)
        return

    # generate: the pool is kept under the workspace, so it can be culled
    # again if the cull ever changes, and resumed if the run is stopped.
    job = _export(ws, args, batch=args.batch)
    name = "arc-" + "-".join(f"{a:03d}" for a in args.arc)
    folder = ws.root / "jobs" / f"{name}-{time.strftime('%Y%m%d-%H%M%S')}"
    folder.mkdir(parents=True)
    (folder / "job.json").write_text(json.dumps(job, indent=2) + "\n",
                                     encoding="utf-8")
    print(f"{folder}: {sum(len(s['cues']) for s in job['sets'])} take(s)",
          flush=True)
    code = subprocess.call([sys.executable, "-u", str(PACKAGE / "runner.py"),
                            str(folder / "job.json"),
                            "--out", str(folder / "beds")])
    if code:
        raise SystemExit(f"runner exited {code}; the takes that settled are "
                         f"in {folder / 'beds'} and a rerun of runner.py on "
                         "that job resumes from them")
    jobs.import_results(job, [folder / "beds"], ws)


if __name__ == "__main__":
    main()
