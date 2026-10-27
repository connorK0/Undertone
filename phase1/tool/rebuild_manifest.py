"""Rebuild a set's manifest.json from the beds already on disk.

A generation run writes each bed as soon as it passes the audibility guard,
but the manifest only at the very end -- so a run that dies late leaves the
audio complete and the set unreadable, because the app finds its cues through
the manifest. That happened once for real: `cull_by_movement` raised a
KeyError after the cull had finished, three hours in, and thirty-two good
beds were sitting in a directory with nothing pointing at them.

This recovers them without the GPU. The raw take that every bed is written
beside is the model's own output, so `loopify.process` run over it
reproduces the loop and every guard number the lost manifest would have
held. Two caveats, both recorded in the rebuilt file under `rebuilt`:

  * Every number is measured from the **finished bed**, not recomputed by
    re-running the pipeline over the raw take. Both were tried. Re-running
    it reproduced 31 of 32 beds to within a few 16-bit steps -- but the
    thirty-second, `tense-0-v5`, came out a different 24 seconds of the same
    clip, because `pick_region` scores candidate windows for flatness and
    quantisation noise in the 16-bit raw broke a near-tie the other way. A
    report describing a loop the file does not contain is the failure
    SUMMARY 9.19 is about, so the measurement is taken from the file itself.
    --verify re-runs the pipeline anyway and says how many beds' region
    choice moved: a fact about `pick_region`, not a problem with the rebuild.
  * `seed`, `attempt` and `batch` are not recoverable from the audio. Pass
    --log with the run's stdout and they are read from it, including the
    renaming the movement cull did; without it they are recorded as null.

Usage:
    python tool/rebuild_manifest.py <dir> [--log run.log] [--verify] [--write]

<dir> is the set directory -- generated/<book>/arc-000/ or generated/<book>/.
Nothing is written without --write.
"""

import argparse
import json
import math
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import soundfile as sf

import bench_palette
import generate_beds
import loopify


def report_from_loop(loop, source_rate: int) -> dict:
    """loopify.process's report, measured from a bed that already exists.

    Same fields, same thresholds, same functions -- but read off the file
    rather than produced alongside it. Two differ from what `process` writes
    and both are improvements: `rms_dbfs` is the level the bed *has* where
    process records the level it aimed at, and `loop_seconds` is its real
    length.
    """
    seam, worst, ratio = loopify.seam_report(loop[:, 0])
    audible = loopify.energy_above(loop, loopify.SPEAKER_FLOOR_HZ,
                                   loopify.SAMPLE_RATE)
    centroid = loopify.centroid_hz(loop, loopify.SAMPLE_RATE)
    rms = float(np.sqrt(np.mean(loop ** 2)))
    peak = float(np.abs(loop).max())
    return {
        "centroid_hz": round(centroid, 1),
        "shrill": bool(centroid > loopify.MAX_CENTROID_HZ),
        "usable": bool(audible >= loopify.MIN_ENERGY_ABOVE_FLOOR
                       and centroid <= loopify.MAX_CENTROID_HZ),
        "source_rate": source_rate,
        "loop_seconds": round(len(loop) / loopify.SAMPLE_RATE, 3),
        "sample_rate": loopify.SAMPLE_RATE,
        "rms_dbfs": round(20 * math.log10(max(rms, 1e-9)), 2),
        "peak_dbfs": round(20 * math.log10(max(peak, 1e-9)), 2),
        "seam_step": round(seam, 8),
        "worst_internal_step": round(worst, 8),
        "seam_ratio": round(ratio, 4),
        "energy_above_200hz": round(audible, 4),
        "audible": bool(audible >= loopify.MIN_ENERGY_ABOVE_FLOOR),
    }


def cue_of(stem: str) -> tuple[str, int]:
    """`tense-0-v3` -> (`tense-0`, 3); `tense-0` -> (`tense-0`, 0)."""
    m = re.fullmatch(r"(.+)-v(\d+)", stem)
    return (m.group(1), int(m.group(2))) if m else (stem, 0)


def parse_log(path: Path) -> dict[str, dict]:
    """seed / attempt / batch per *final* bed name, from a run's stdout.

    The log names beds by the stem they were generated under; the cull then
    renamed the survivors. Both are in there -- the attempt lines give the
    numbers, the cull lines give the renaming, in rank order -- so this
    walks the cull lines to build the map and then reads the numbers
    through it.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    attempts: dict[str, dict] = {}
    for line in text.splitlines():
        m = re.match(r"\s+(\S+)\s+seed (\d+)\s", line)
        if not m:
            continue
        stem, seed = m.group(1), int(m.group(2))
        # A stem tried several times: the last line is the take that was
        # kept, since the loop stops at the first pass and otherwise keeps
        # the nearest miss.
        rejected = "rejected" in line
        if stem not in attempts or not rejected:
            attempts[stem] = {"seed": seed,
                              "attempt": attempts.get(stem, {}).get(
                                  "attempt", 0) + 1}
        else:
            attempts[stem]["attempt"] = attempts[stem].get("attempt", 0) + 1
            attempts[stem]["seed"] = seed
    renames: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"\s+(\S+)\s+kept \d+ of \d+ by movement \([a-z]+\): (.+)",
                     line)
        if not m:
            continue
        cue, rest = m.group(1), m.group(2)
        order = [part.strip().split()[0] for part in rest.split(",")]
        for i, was in enumerate(order):
            renames[cue if i == 0 else f"{cue}-v{i}"] = was
    out = {}
    for final, was in renames.items():
        if was in attempts:
            out[final] = attempts[was]
    # Beds of a cue that was never culled keep their own name.
    for stem, row in attempts.items():
        out.setdefault(stem, row)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rebuild manifest.json from the beds on disk.")
    parser.add_argument("directory", type=Path)
    parser.add_argument("--log", type=Path,
                        help="the run's stdout, for seed / attempt / batch")
    parser.add_argument("--verify", action="store_true",
                        help="compare the recomputed loop against the bed on "
                             "disk and report the worst difference")
    parser.add_argument("--write", action="store_true",
                        help="write manifest.json; without this, print only")
    parser.add_argument("--book",
                        help="the book id, when the directory is not named "
                             "for it -- a run written to a scratch --out is "
                             "the ordinary case")
    parser.add_argument("--model", default="facebook/musicgen-stereo-medium")
    parser.add_argument("--guidance", type=float, default=3.0)
    args = parser.parse_args()

    out = args.directory
    beds = sorted(p for p in out.glob("*.wav")
                  if not p.name.endswith(".raw.wav"))
    if not beds:
        raise SystemExit(f"no beds under {out}")

    arc = None
    m = re.fullmatch(r"arc-(\d+)", out.name)
    if m:
        arc = int(m.group(1))
    # The book id is the directory above an arc directory, or this one --
    # unless the run went to a scratch --out, where it is neither.
    book = args.book or (out.parent if arc is not None else out).name

    known = generate_beds.themes()
    key = book if arc is None else f"{book}#arc{arc}"
    if key not in known:
        raise SystemExit(f"no cached theme for {key}; is {book} the book id?")
    theme = dict(known[key])
    theme["key_seed"] = key

    from_log = parse_log(args.log) if args.log else {}
    if args.log:
        print(f"{len(from_log)} bed(s) matched in {args.log.name}")

    entries, moved, worst = [], [], 0.0
    for bed in beds:
        loop, rate = loopify.load(bed)
        raw = out / f"{bed.stem}.raw.wav"
        source_rate = rate
        if raw.exists():
            source_rate = sf.info(str(raw)).samplerate
        report = report_from_loop(loop, source_rate)
        if args.verify and raw.exists():
            # Re-run the pipeline and see whether it lands on the same audio.
            again, _ = loopify.loopify(raw)
            n = min(len(again), len(loop))
            gap = float(np.abs(again[:n] - loop[:n]).max())
            worst = max(worst, gap)
            if gap > 1e-3:
                moved.append(bed.stem)
        cue, variant = cue_of(bed.stem)
        mood, band = generate_beds.split_cue(cue)
        movement = bench_palette.measure(bed)
        entries.append({
            "cue": cue,
            "variant": variant,
            "mood": mood,
            "band": band,
            "band_name": None if band is None else generate_beds.BAND_NAMES[band],
            "file": bed.name,
            "description": generate_beds.prompt_for(mood, theme, band=band),
            "model": args.model,
            "guidance": args.guidance,
            "key": f"{generate_beds.tonic_for(theme)} "
                   f"{generate_beds.MOOD_MODE.get(mood, 'minor')}",
            "source": "generated by phase1/tool/generate_beds.py",
            "license": f"see the model card for {args.model}",
            "attribution": None,
            **report,
            "movement": None if not movement else {
                "flux": round(movement["flux"], 1),
                "onsets": round(movement["onsets"], 2),
            },
            "seed": from_log.get(bed.stem, {}).get("seed"),
            "attempt": from_log.get(bed.stem, {}).get("attempt"),
            "batch": 1 if bed.stem in from_log else None,
        })
        flag = "" if report["usable"] else "   NOT usable"
        print(f"  {bed.stem:16s} centroid {report['centroid_hz']:6.0f} Hz  "
              f"{100 * report['energy_above_200hz']:5.1f}% above 200 Hz  "
              f"flux {entries[-1]['movement']['flux']:5.1f}  "
              f"seed {entries[-1]['seed']}{flag}")

    if args.verify:
        print(f"{chr(10)}re-running the pipeline over the raw takes reproduces "
              f"the beds to {worst:.1e} at worst "
              f"(one 16-bit step is 3.1e-05)")
        if moved:
            print(f"  {len(moved)} bed(s) would have come out as a different "
                  f"region of the same clip: {', '.join(moved)}")
            print("  pick_region scores windows for flatness and the 16-bit "
                  "raw breaks near-ties differently. The numbers above are "
                  "measured from the beds themselves, so this changes none "
                  "of them.")

    manifest = {
        "library": f"generated for {book}"
                   + ("" if arc is None else f" arc {arc}"),
        "note": "Per-book beds. Prompts are built from the book's own theme "
                "pass; see tool/generate_beds.py.",
        "book": book,
        "palette": "full",
        "arc": arc,
        "theme": theme,
        "rebuilt": {
            "by": "tool/rebuild_manifest.py",
            "why": "the run wrote every bed but died before the manifest",
            "guard_numbers_from": "the finished bed, measured off disk",
            "log": None if not args.log else args.log.name,
        },
        "loops": entries,
    }
    unusable = [e["file"] for e in entries if not e["usable"]]
    print(f"\n{len(entries)} bed(s), {len(unusable)} not usable"
          + (f": {', '.join(unusable)}" if unusable else ""))
    if not args.write:
        print("\nnothing written; pass --write")
        return
    (out / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out / 'manifest.json'}")
    print("run bench_palette.py --write-distances next, or the set will "
          "never lead into a change")


if __name__ == "__main__":
    main()
