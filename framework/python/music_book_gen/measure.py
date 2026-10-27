"""Does the palette's structure survive into the audio?

Two questions the prompts assume the answer to, and neither had been measured.
Both read finished beds off disk; neither needs a GPU or the model.

  --bands   Do the intensity bands form a gradient? The band clause asks for
            movement -- band 0 "almost nothing moving, one held texture", band 3
            "most present and insistent". §9.11 measured brightness and found it
            flat, but brightness is not what was asked for. This measures
            movement directly, and checks the BPM number inside the band against
            what came out.

  --takes   Do a cue's takes differ? They are the same prompt at different
            seeds, and §8.6 spends up to ten beds on one cue on the assumption
            that they do. Compares how far apart two takes of one cue are
            against two bands of one mood and two different moods -- if takes
            are as spread as the palette, the seed is doing the work.

  --steps   Does a band step clear the take rotation? Per mood, each adjacent
            band pair's distance (averaged over takes) against the distance
            between takes of one band. A step under 1.0x is smaller than the
            change the score already makes by rotating takes, so the reader
            cannot hear it *as* a band step. Also prints each band's median
            centroid over every take, which is where §9.23 found the
            structure the monotone test in --bands could not see.

Usage:
    python tool/bench_palette.py --bands <dir>
    python tool/bench_palette.py --takes <dir>
    python tool/bench_palette.py --steps <dir>

where <dir> holds the beds -- generated/<book>/ or generated/<book>/arc-000/.
Results in SUMMARY.md §9.16 and §9.17.
"""

import argparse
import json
import itertools
import pathlib
import wave

import numpy as np

FFT = 2048
HOP = 512

# The chroma band, matching the key measurement in bench_melody.py.
CHROMA_LOW = 55.0
CHROMA_HIGH = 2000.0


def read_wav(path: pathlib.Path):
    with wave.open(str(path), "rb") as w:
        rate, count, width, channels = (w.getframerate(), w.getnframes(),
                                        w.getsampwidth(), w.getnchannels())
        raw = w.readframes(count)
    if width != 2:
        raise ValueError(f"{path.name}: {width * 8}-bit, expected 16")
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        x = x.reshape(-1, channels).mean(axis=1)
    return x, rate


def measure(path: pathlib.Path):
    """Movement, level and tonal content of one bed."""
    x, rate = read_wav(path)
    if len(x) < FFT * 3:
        return None
    count = 1 + (len(x) - FFT) // HOP
    idx = np.arange(FFT)[None, :] + HOP * np.arange(count)[:, None]
    framed = x[idx] * np.hanning(FFT).astype(np.float32)[None, :]
    mag = np.abs(np.fft.rfft(framed, axis=1))
    freqs = np.fft.rfftfreq(FFT, 1.0 / rate)
    energy = mag.sum(axis=1) + 1e-9

    centroid = float(np.average((mag * freqs[None, :]).sum(axis=1) / energy))

    # Positive spectral flux, normalised by frame energy so that a loud bed is
    # not counted as a busy one -- the question is proportional change.
    flux = np.clip(np.diff(mag, axis=0), 0, None).sum(axis=1) / energy[1:]

    rms_frames = np.sqrt((framed ** 2).mean(axis=1)) + 1e-9
    rms = float(np.sqrt((x ** 2).mean()))
    rms_cv = float(rms_frames.std() / rms_frames.mean())

    # An onset is a flux frame standing clearly above the local norm.
    threshold = flux.mean() + flux.std()
    peaks = ((flux > threshold) & (flux > np.roll(flux, 1))
             & (flux > np.roll(flux, -1)))
    onsets = float(peaks.sum() / (len(x) / rate))

    band = (freqs >= CHROMA_LOW) & (freqs <= CHROMA_HIGH)
    semis = np.round(12 * np.log2(freqs[band] / CHROMA_LOW)).astype(int) % 12
    spectrum = mag[:, band].mean(axis=0)
    chroma = np.array([spectrum[semis == s].sum() for s in range(12)])
    chroma = chroma / (np.linalg.norm(chroma) + 1e-9)

    return {
        "rms": rms,
        "centroid": centroid,
        "flux": float(flux.mean() * 1000),
        "rms_cv": rms_cv,
        "onsets": onsets,
        "chroma": chroma,
    }


def beds_under(root: pathlib.Path) -> dict:
    """Every finished bed, by stem. Raw takes are diagnostic and skipped."""
    out = {}
    for path in sorted(root.glob("*.wav")):
        if path.name.endswith(".raw.wav"):
            continue
        got = measure(path)
        if got:
            out[path.stem] = got
    return out


def cue_of(stem: str) -> str:
    return stem.rsplit("-v", 1)[0] if "-v" in stem else stem


def mood_of(stem: str) -> str:
    cue = cue_of(stem)
    mood, _, band = cue.rpartition("-")
    return mood if band.isdigit() and mood else cue


def band_of(stem: str):
    _, _, band = cue_of(stem).rpartition("-")
    return int(band) if band.isdigit() else None


def report_bands(root: pathlib.Path) -> None:
    beds = {k: v for k, v in beds_under(root).items() if band_of(k) is not None
            and "-v" not in k}
    if not beds:
        print(f"no banded beds under {root}")
        return

    keys = ["rms", "centroid", "flux", "rms_cv", "onsets"]
    rows = {(mood_of(k), band_of(k)): v for k, v in beds.items()}
    moods = sorted({m for m, _ in rows})

    print(f"{len(rows)} banded beds under {root.name}\n")
    header = f"{'cue':<16}" + "".join(f"{k:>11}" for k in keys)
    print(header)
    print("-" * len(header))
    for mood in moods:
        for band in range(4):
            row = rows.get((mood, band))
            if row:
                cells = "".join(f"{row[k]:>11.3f}" for k in keys)
                print(f"{f'{mood}-{band}':<16}{cells}")
        print()

    print("does it climb with the band?\n")
    print(f"{'measure':<12}{'monotone':>12}{'band0->band3':>16}")
    print("-" * 40)
    for k in keys:
        monotone = eligible = 0
        ratios = []
        for mood in moods:
            series = [rows[(mood, b)][k] for b in range(4) if (mood, b) in rows]
            if len(series) < 2:
                continue
            eligible += 1
            if all(b > a for a, b in zip(series, series[1:])):
                monotone += 1
            if (mood, 0) in rows and (mood, 3) in rows:
                low = rows[(mood, 0)][k]
                if low > 1e-9:
                    ratios.append(rows[(mood, 3)][k] / low)
        mean = f"{np.mean(ratios):.2f}x" if ratios else "-"
        print(f"{k:<12}{f'{monotone}/{eligible}':>12}{mean:>16}")


def report_takes(root: pathlib.Path) -> None:
    beds = beds_under(root)
    if len(beds) < 2:
        print(f"not enough beds under {root}")
        return

    names = list(beds)
    timbre = np.array([[beds[n][k] for k in ("rms", "centroid", "flux", "onsets")]
                       for n in names])
    timbre = (timbre - timbre.mean(axis=0)) / (timbre.std(axis=0) + 1e-9)
    chroma = np.array([beds[n]["chroma"] for n in names])
    index = {n: i for i, n in enumerate(names)}

    buckets = {
        "same cue, diff take": [],
        "same mood, diff band": [],
        "different mood": [],
    }
    for a, b in itertools.combinations(names, 2):
        pair = (float(np.linalg.norm(timbre[index[a]] - timbre[index[b]])),
                1.0 - float(chroma[index[a]] @ chroma[index[b]]))
        if cue_of(a) == cue_of(b):
            buckets["same cue, diff take"].append(pair)
        elif mood_of(a) == mood_of(b):
            buckets["same mood, diff band"].append(pair)
        else:
            buckets["different mood"].append(pair)

    print(f"{len(names)} beds under {root.name}\n")
    print(f"{'comparison':<22}{'pairs':>7}{'timbre':>10}{'chroma':>10}")
    print("-" * 49)
    for label, pairs in buckets.items():
        if not pairs:
            continue
        arr = np.array(pairs)
        print(f"{label:<22}{len(arr):>7}{arr[:, 0].mean():>10.2f}"
              f"{arr[:, 1].mean():>10.3f}")

    takes = buckets["same cue, diff take"]
    across = buckets["different mood"]
    if takes and across:
        t, x = np.array(takes), np.array(across)
        print(f"\n{'take vs diff-mood':<22}{'':>7}"
              f"{t[:, 0].mean() / x[:, 0].mean():>9.2f}x"
              f"{t[:, 1].mean() / x[:, 1].mean():>9.2f}x")
        print("\nNear 1.00 in timbre means a cue's takes are as varied as the")
        print("palette itself, so the seed is buying real variety.")


def report_steps(root: pathlib.Path) -> None:
    beds = beds_under(root)
    if len(beds) < 2:
        print(f"not enough beds under {root}")
        return

    names = list(beds)
    timbre = np.array([[beds[n][k] for k in ("rms", "centroid", "flux", "onsets")]
                       for n in names])
    timbre = (timbre - timbre.mean(axis=0)) / (timbre.std(axis=0) + 1e-9)
    index = {n: i for i, n in enumerate(names)}

    def dist(a: str, b: str) -> float:
        return float(np.linalg.norm(timbre[index[a]] - timbre[index[b]]))

    cues = sorted({cue_of(n) for n in names})
    members = {cue: [n for n in names if cue_of(n) == cue] for cue in cues}
    moods = sorted({mood_of(n) for n in names if band_of(n) is not None})

    print(f"{len(names)} beds under {root.name}\n")
    for mood in moods:
        bands = sorted(b for b in range(4) if f"{mood}-{b}" in members)
        # A take step needs two takes of one band; a mood generated one bed
        # per band has nothing to measure a step against.
        takes = [dist(x, y)
                 for b in bands
                 for x, y in itertools.combinations(members[f"{mood}-{b}"], 2)]
        if not takes:
            continue
        take_step = float(np.mean(takes))
        print(f"{mood}: take step {take_step:.2f} over {len(takes)} pairs")
        print(f"  {'band':<10}{'n':>3}{'centroid':>10}   {'step to next':>14}")
        for b in bands:
            here = members[f"{mood}-{b}"]
            centroid = np.median([beds[n]["centroid"] for n in here])
            line = f"  {f'{mood}-{b}':<10}{len(here):>3}{centroid:>10.0f}"
            if b + 1 in bands:
                nxt = members[f"{mood}-{b + 1}"]
                step = float(np.mean([dist(x, y) for x in here for y in nxt]))
                line += f"   {step:>8.2f} = {step / take_step:.2f}x take"
            print(line)
        print()
    print("A step under 1.00x is smaller than the change the rotation makes")
    print("on its own, so the band is not carrying anything the seed is not.")


def write_distances(root: pathlib.Path) -> None:
    """Record how far apart every pair of cues sounds, into the manifest.

    The engine needs this to know which changes are stark enough to lead into
    (SUMMARY §8.9), and it cannot measure audio while someone is reading. So
    it is measured once here and looked up there.

    Both numbers are divided by the set's own mean, so a threshold is "1.3
    times the average change in this palette" rather than an absolute that
    would mean something different in every set:

      timbre  how big the change sounds -- what decides a lead-in is wanted
      chroma  how far apart the two tonal centres are -- what decides whether
              the two beds may overlap, or only the parameters may sweep
    """
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    beds = beds_under(root)
    if len(beds) < 2:
        print(f"not enough beds under {root}")
        return

    names = list(beds)
    timbre = np.array([[beds[n][k] for k in ("rms", "centroid", "flux", "onsets")]
                       for n in names])
    timbre = (timbre - timbre.mean(axis=0)) / (timbre.std(axis=0) + 1e-9)
    chroma = np.array([beds[n]["chroma"] for n in names])
    index = {n: i for i, n in enumerate(names)}

    cues = sorted({cue_of(n) for n in names})
    members = {cue: [n for n in names if cue_of(n) == cue] for cue in cues}

    def between(a: str, b: str) -> tuple[float, float]:
        # Averaged over takes: the rotation decides which take is playing, so
        # a pair of cues has to have one distance rather than one per pairing.
        pairs = [(x, y) for x in members[a] for y in members[b]]
        t = float(np.mean([np.linalg.norm(timbre[index[x]] - timbre[index[y]])
                           for x, y in pairs]))
        c = float(np.mean([1.0 - chroma[index[x]] @ chroma[index[y]]
                           for x, y in pairs]))
        return t, c

    raw = {(a, b): between(a, b)
           for a, b in itertools.combinations(cues, 2)}
    mean_t = float(np.mean([t for t, _ in raw.values()])) or 1.0
    mean_c = float(np.mean([c for _, c in raw.values()])) or 1.0

    distances = {
        f"{a}|{b}": {"timbre": round(t / mean_t, 3),
                     "chroma": round(c / mean_c, 3)}
        for (a, b), (t, c) in raw.items()
    }
    manifest["distances"] = distances
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    ranked = sorted(raw.items(), key=lambda kv: -kv[1][0])
    print(f"{len(distances)} pairs over {len(cues)} cues written to "
          f"{manifest_path.name}")
    print(f"mean timbre {mean_t:.2f}, mean chroma {mean_c:.3f}\n")
    print(f"{'starkest changes':<32}{'timbre':>9}{'chroma':>9}")
    print("-" * 50)
    for (a, b), (t, c) in ranked[:5]:
        print(f"{f'{a} <-> {b}':<32}{t / mean_t:>8.2f}x{c / mean_c:>8.2f}x")
    print("  ...")
    for (a, b), (t, c) in ranked[-3:]:
        print(f"{f'{a} <-> {b}':<32}{t / mean_t:>8.2f}x{c / mean_c:>8.2f}x")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Does the palette's structure survive into the audio?")
    parser.add_argument("--bands", metavar="DIR",
                        help="do the intensity bands form a gradient?")
    parser.add_argument("--takes", metavar="DIR",
                        help="do a cue's takes differ from each other?")
    parser.add_argument("--steps", metavar="DIR",
                        help="does a band step clear the take rotation?")
    parser.add_argument("--write-distances", metavar="DIR",
                        help="measure every pair of cues and record it in the "
                             "set's manifest, for the engine to lead in with")
    args = parser.parse_args()

    if not (args.bands or args.takes or args.steps or args.write_distances):
        parser.error("give --bands, --takes, --steps or --write-distances DIR")
    if args.bands:
        report_bands(pathlib.Path(args.bands))
    if args.takes:
        if args.bands:
            print()
        report_takes(pathlib.Path(args.takes))
    if args.steps:
        if args.bands or args.takes:
            print()
        report_steps(pathlib.Path(args.steps))
    if args.write_distances:
        if args.bands or args.takes or args.steps:
            print()
        write_distances(pathlib.Path(args.write_distances))


if __name__ == "__main__":
    main()
