"""Send bed generation to a machine with a bigger GPU, and bring it back.

Why this is worth doing, specifically: 8 GB is the binding constraint on the
only optimisation that works. Measured on the 4060 laptop, batch 2 at guidance
3.0 peaks at 9.83 GiB and survives only by spilling into system RAM; batch 4
dies. On a 16 GB card batch 4 fits, and free tiers offer 16 GB (Kaggle gives
30 GPU-hours a week). The point is not that this machine lacks a GPU -- it is
that it lacks the *memory* the speed depends on.

Why it is clean to do: the generator's whole input is a list of short text
prompts, and its whole output is WAV files. **No book text leaves the machine.**
A prompt is a genre, a mood, an instrument list and a tempo.

    python tool/offload.py export --book <id> --arc 3 --overgen 3 --out job.json
    modal run tool/offload_modal.py --job job.json      # Modal; see that file
    #   ... or upload job.json, offload_run.py and loopify.py anywhere, run it,
    #   and download what it wrote ...
    python tool/offload.py import --job job.json --results ./downloaded/beds

The far side generates the whole over-generated pool and applies the
audibility guard; the movement cull and the register gate run here, on import,
through generate_beds.cull_by_movement -- one cull, not a copy of it.

The rejection sampling stays with the GPU rather than coming home for a
verdict. A bed that fails the audibility guard has to be generated again with a
new seed, and doing that across a network would mean shipping rejects back and
forth; offload_run.py carries loopify.py for exactly this reason.

What comes back is **not trusted**. `import` re-reads every WAV and recomputes
the audibility measures rather than believing the manifest that arrives with
them -- a truncated download is otherwise a bed that silently plays nothing.
"""

import argparse
import json
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_beds as gb  # noqa: E402
import loopify  # noqa: E402


def build_sets(args, known: dict, boundaries: list[dict]) -> list[dict]:
    """Every bed set this job should produce, with its prompts already built.

    Prompts are resolved here rather than on the far side so the remote runner
    needs none of this repo: no theme cache, no mood parameters, no phase0
    import. It needs a job file, loopify.py, and a GPU.
    """
    # The measured plan, if this book has been sampled. Resolved here for the
    # same reason the prompts are: the remote runner should not need to know
    # what an allocation is, only which beds to make.
    allocation = {} if args.uniform else gb.load_allocation(args.book)

    if args.per_arc or args.arc is not None:
        if not boundaries:
            raise SystemExit(
                f"no arc boundaries for {args.book}; run "
                f"`dart run tool/arcs.dart {args.book} --scan` then "
                f"`dart run tool/theme.dart {args.book} --arcs` first")
        # Only arcs that represent a set: an arc grouped onto an earlier one
        # plays those beds and has nothing of its own to make.
        wanted = [a for a in boundaries
                  if a.get("palette", a["index"]) == a["index"]]
        if args.arc is not None:
            wanted = [a for a in wanted if a["index"] == args.arc]
            if not wanted:
                raise SystemExit(
                    f"arc {args.arc} does not represent a set; it plays "
                    f"another arc's beds, or does not exist")
        chosen = [(a, f"{args.book}#arc{a['index']}") for a in wanted]
    else:
        chosen = [(None, args.book)]

    sets = []
    for arc, key in chosen:
        theme = known.get(key)
        if theme is None:
            print(f"  skipping {key}: no cached theme", file=sys.stderr)
            continue
        # Same stamp the local generator uses, so a job exported for a remote
        # GPU asks for the same keys the local run would have.
        theme["key_seed"] = key
        sets.append({
            "dir": "book" if arc is None else f"arc-{arc['index']:03d}",
            "arc": None if arc is None else arc["index"],
            "start": None if arc is None else arc["start"],
            "end": None if arc is None else arc["end"],
            # No arc title: titles are written from the book's own text (a
            # summary of what happens in the arc), and nothing the far
            # side does needs one. What leaves the machine is prompts.
            "theme": {
                "genre_seed": theme["genre_seed"],
                "overall_theme": theme["overall_theme"],
                "instrumentation": theme["instrumentation"],
            },
            # Every take of the over-generated pool, not just the ones that
            # will be kept: the far side generates and guards, and the
            # movement cull and register gate run at home on import, through
            # the same cull_by_movement a local run uses. `keep` is how many
            # of a cue's takes survive it. `seed_base` is resolved here so the
            # runner cannot drift from the local seed scheme again.
            "cues": [
                {
                    "stem": slot["stem"],
                    "cue": slot["cue"],
                    "variant": slot["variant"],
                    "keep": slot["keep"],
                    "mood": slot["mood"],
                    "band": slot["band"],
                    "band_name": (None if slot["band"] is None
                                  else gb.BAND_NAMES[slot["band"]]),
                    "seed_base": gb.seed_base(args.seed, slot["band"],
                                              slot["variant"], args.attempts),
                    "key": (f"{gb.tonic_for(theme)} "
                            f"{gb.MOOD_MODE.get(slot['mood'], 'minor')}"),
                    "prompt": gb.prompt_for(
                        slot["mood"], theme,
                        register_hint=args.register_hint,
                        positive_only=args.positive_only,
                        band=slot["band"],
                    ),
                }
                for slot in gb.slots_for(
                    sorted(gb.MOOD_PARAMS), args.palette,
                    gb.allocation_for(
                        allocation, None if arc is None else arc["index"]),
                    overgen=args.overgen)
            ],
        })
    if not sets:
        raise SystemExit("nothing to export")
    return sets


def do_export(args) -> None:
    known = gb.themes()
    boundaries = gb.load_arcs(args.book)
    sets = build_sets(args, known, boundaries)

    job = {
        "book": args.book,
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "palette": args.palette,
        "settings": {
            "model": args.model,
            "seconds": gb.SECONDS,
            "tokens_per_second": gb.TOKENS_PER_SECOND,
            "guidance": args.guidance,
            "attempts": args.attempts,
            "seed": args.seed,
            "batch": args.batch,
            # Applied at home by `import`, recorded here so a job says how
            # its set will be culled.
            "overgen": args.overgen,
            "register_gate": not args.no_register_gate,
            "phrasing": "positive-only" if args.positive_only else "negated",
        },
        # No `boundaries`: import reads arcs.json at home for palette.json,
        # and the boundaries carry every arc's title, which is book text.
        "sets": sets,
    }
    out = Path(args.out).resolve()
    out.write_text(json.dumps(job, indent=2) + "\n", encoding="utf-8")

    beds = sum(len(s["cues"]) for s in sets)
    kept = sum(1 for s in sets for c in s["cues"] if c["variant"] < c["keep"])
    print(f"{out}")
    print(f"{len(sets)} set(s), {beds} take(s) to generate, {kept} kept after "
          f"the cull at home, {args.palette} palette, overgen {args.overgen}, "
          f"register gate {'off' if args.no_register_gate else 'on'}, "
          f"{job['settings']['phrasing']} phrasing")
    for s in sets:
        where = "whole book" if s["arc"] is None else (
            f"arc {s['arc']} (ch {s['start'] + 1}-{s['end'] + 1})")
        print(f"  {s['dir']:10s} {where}: {s['theme']['genre_seed']} / "
              f"{s['theme']['overall_theme']}")
    print(f"\non Modal:  modal run tool/offload_modal.py --job {out}")
    print(f"anywhere:  upload {out.name}, tool/offload_run.py and "
          f"tool/loopify.py, then python offload_run.py {out.name} --out beds")


def verify(path: Path, claimed: dict) -> tuple[str | None, dict]:
    """Re-measure a returned bed instead of believing what came with it.

    A half-finished download is a valid WAV of the wrong length, and a bed that
    is quietly two seconds long loops into noise. Cheap to check, and there is
    no reason to take a remote machine's word for it.

    Returns (problem, measured). A problem means the file is not what the far
    side says it is, and that take is not installed. An *inaudible* bed is not
    a problem: the far side returns the whole over-generated pool, usable or
    not, and the cull decides. What it decides on is `measured` -- the guard's
    verdict recomputed from the file here, which replaces the far side's.
    """
    if not path.exists():
        return "missing", {}
    try:
        audio, rate = loopify.load(path)
    except Exception as error:  # noqa: BLE001 -- any unreadable file fails here
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


def do_import(args) -> None:
    """Verify the returned pool, cull it at home, install the survivors.

    The cull is generate_beds.cull_by_movement itself -- movement, and the
    register gate unless the job says otherwise -- run over a working copy,
    so a set made off-machine is chosen by exactly the code that chooses a
    local one, and the download is left whole to re-cull if that ever
    changes.
    """
    job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    # Several result directories are one pool: a job split across GPUs (two
    # on Kaggle), or a second job for the takes a first one ran out of time
    # for, comes home as one directory each.
    results = [Path(r).resolve() for r in args.results]
    book = job["book"]
    settings = job["settings"]
    root = (Path(args.out).resolve() if args.out
            else gb.APP_SUPPORT / "generated" / book)

    total, bad = 0, []
    staged = []
    for spec in job["sets"]:
        # Keyed by cue *and take*: several rows can share a cue, and a job
        # whose takes all collapsed onto one row is exactly the failure the
        # allocation exists to avoid. Each row remembers which directory it
        # came from, since that is where its audio is.
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
                  f"skipped", file=sys.stderr)
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
    if bad and not args.force:
        raise SystemExit(
            "refusing to install a set with failures; fix them, regenerate "
            "those cues, or pass --force to cull and install what did verify")

    gate = settings.get("register_gate", True)
    for spec, pool in staged:
        target = root if spec["dir"] == "book" else root / spec["dir"]
        if (target / "manifest.json").exists():
            print(f"  {target} already has a set; merging into it by cue and "
                  f"take", flush=True)
        entries = []
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            wanted, best = {}, {}
            for stem, (cue, row, source) in pool.items():
                for suffix in (".wav", ".raw.wav"):
                    origin = source / f"{stem}{suffix}"
                    if origin.exists():
                        shutil.copyfile(origin, work / f"{stem}{suffix}")
                # A job exported before the pool existed has no `keep`: every
                # take it asked for is kept, which is what it meant then.
                keep = cue.get("keep") or sum(
                    1 for c in spec["cues"] if c["cue"] == cue["cue"])
                wanted[stem] = {"stem": stem, "cue": cue["cue"],
                                "mood": cue["mood"], "band": cue["band"],
                                "variant": cue.get("variant", 0),
                                "keep": keep, "prompt": cue["prompt"]}
                # The row is the report: the cull writes `movement` and
                # `register` into it and carries it to the survivor's name.
                best[stem] = (gb.guard_rank(row), None, None, row)
            survivors = gb.cull_by_movement(work, wanted, best,
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
                          f"passed the guard; the least-bad was kept",
                          flush=True)
                entries.append(row)

        manifest = {
            "library": f"generated for {book}"
                       + ("" if spec["arc"] is None else f" arc {spec['arc']}"),
            "note": "Generated off-machine (tool/offload.py), culled and "
                    "installed at home.",
            "book": book,
            "palette": job.get("palette", "full"),
            "arc": spec["arc"],
            "theme": spec["theme"],
            "loops": gb.merge_loops(target / "manifest.json", entries),
        }
        (target / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"  installed {len(entries)} of {len(pool)} take(s) in {target}")

    # A job no longer carries them (they hold book text); one exported before
    # that still does.
    boundaries = job.get("boundaries") or gb.load_arcs(book)
    palette = job.get("palette", "full")
    (root / "palette.json").write_text(
        json.dumps({
            "book": book,
            "palette": palette,
            "arc_size": 0,
            "arcs": max(gb.arcs_on_disk(root), 1),
            # The cues this plan makes, as generate_beds counts them -- not
            # every cue the palette could have.
            "cues": len({c["cue"] for s in job["sets"] for c in s["cues"]}),
            "boundaries": boundaries,
        }, indent=2) + "\n",
        encoding="utf-8")
    print(f"  wrote {root / 'palette.json'}")
    print("then measure it, for the lead-in (SUMMARY 8.9):  python "
          "tool/bench_palette.py --write-distances <set dir>")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    export = sub.add_parser("export", help="write a job file for a remote GPU")
    export.add_argument("--book", required=True)
    export.add_argument("--out", default="job.json")
    export.add_argument("--palette", choices=["moods", "full"], default="full")
    export.add_argument("--per-arc", action="store_true")
    export.add_argument("--arc", type=int, default=None)
    export.add_argument("--model", default="facebook/musicgen-stereo-medium")
    export.add_argument("--guidance", type=float, default=3.0)
    export.add_argument("--attempts", type=int, default=4)
    export.add_argument("--seed", type=int, default=0)
    export.add_argument("--uniform", action="store_true",
                        help="ignore allocation.json and ask for one bed per "
                             "cue, the shape every set on disk today has")
    export.add_argument("--batch", type=int, default=2,
                        help="beds per decode loop. 2 is measured at 9.8 GiB "
                             "and 1.75x, which an 8 GB card cannot hold but a "
                             "16 GB one can. 3 is about 13.6 GiB extrapolated "
                             "and worth trying there; 4 is about 17.4 GiB at "
                             "guidance 3.0 and does NOT fit 16 GB. Override "
                             "on the far side with offload_run.py --batch")
    export.add_argument("--overgen", type=int, default=2, metavar="N",
                        help="generate N takes for every one the plan keeps; "
                             "the cull at import keeps the stillest or "
                             "busiest. Same meaning and default as "
                             "generate_beds.py --overgen")
    export.add_argument("--no-register-gate", action="store_true",
                        help="record that import should cull on movement "
                             "alone (generate_beds.py --no-register-gate)")
    export.add_argument("--register-hint", action="store_true")
    # Was store_true with default=True, so it could not be turned off -- and
    # every set generated locally since 9.31 uses negated phrasing. A job now
    # asks for the same prompt a local run would.
    export.add_argument("--positive-only", action="store_true",
                        help="phrase the constraint without negations, as "
                             "generate_beds.py --positive-only. Off by default, "
                             "as it is there")
    export.set_defaults(func=do_export)

    bring = sub.add_parser("import", help="verify and install returned beds")
    bring.add_argument("--job", required=True)
    bring.add_argument("--results", required=True, nargs="+",
                       help="the directory the remote run produced -- or "
                            "several, one per GPU or per job, which are "
                            "merged into one pool before the cull")
    bring.add_argument("--force", action="store_true",
                       help="cull and install the takes that verified even "
                            "though others did not")
    bring.add_argument("--out", default=None,
                       help="install under this directory instead of the "
                            "app's generated/<book>/ -- for a set that has to "
                            "be compared before it replaces a live one")
    bring.set_defaults(func=do_import)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
