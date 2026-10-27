"""Turn an arbitrary audio clip into a bed the engine can actually use.

    phase1/.venv/Scripts/python.exe phase1/tool/loopify.py --self-test

A generated clip is not a bed. Three properties decide whether a crossfading
score is pleasant or awful, and a text-to-music model gives you none of them:

  * **seamless looping** -- a click at every wrap ruins the effect. Generated
    audio starts and ends wherever it likes.
  * **matched loudness** -- a bed 6 dB louder than its neighbour turns every
    crossfade into a lurch, which reads as "the music is broken".
  * **audibility** -- a bed whose energy all sits below ~200 Hz is inaudible on
    a laptop speaker however good its meters look. Phase 3 shipped a full set
    of passing audio tests over beds nobody could hear, because every check
    measured the signal rather than whether it could be reproduced.

tool/make_loops.py got all three by construction, because it synthesised every
partial on an exact loop grid. Nothing generated can be correct by
construction, so this measures and fixes instead. That is the whole reason the
project had no audio toolchain until now: with no numpy and no ffmpeg, an audio
file could not be decoded, trimmed, re-levelled or even measured, so found or
generated music could not be checked at all.

The output is byte-compatible with make_loops.py's: 22050 Hz, stereo, 16-bit,
normalised to the same RMS, so a generated bed and a synthesised one can sit in
the same library and crossfade into each other without a level jump.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]

# All identical to make_loops.py, so the two kinds of bed are interchangeable.
SAMPLE_RATE = 22050
LOOP_SECONDS = 24.0
TARGET_RMS = 0.14
SPEAKER_FLOOR_HZ = 200
MIN_ENERGY_ABOVE_FLOOR = 0.15
PEAK_CEILING = 0.89

# A bed can fail in two opposite directions and the floor only catches one.
#
# Measured: rejecting Dracula's first 'ominous' generation (0.3% above 200 Hz,
# inaudible) and re-seeding produced one with 99.7% above 200 Hz and a spectral
# centroid of 2940 Hz -- a horror drone with no weight at all. Trading "cannot
# be heard" for "has no body" is not progress, it is a different wrong answer.
#
# So brightness is checked from both ends. The ceiling is deliberately loose:
# every bed that reads as reasonable measured between 160 and 850 Hz, so 1800
# only catches the genuinely shrill.
MAX_CENTROID_HZ = 1800

# How much of the tail is folded back over the head to close the loop. Long
# enough to hide a discontinuity in sustained material, short enough that the
# fold is not a large fraction of what you hear.
CROSSFADE_SECONDS = 2.0

# Everything below this is rumble the speakers cannot reproduce anyway, and it
# eats headroom the audible part needs.
RUMBLE_HZ = 35


def load(path: Path) -> tuple[np.ndarray, int]:
    """Read any soundfile-supported audio as float64 stereo."""
    audio, rate = sf.read(str(path), dtype="float64", always_2d=True)
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    elif audio.shape[1] > 2:
        audio = audio[:, :2]
    return audio, rate


def resample(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    """Band-limited resample via the frequency domain.

    Exact for band-limited content and needs nothing beyond numpy. The edge
    artefacts an FFT resample can introduce do not matter here: what this is
    handed has already been cut from the middle of a longer clip, and what
    survives is trimmed again by the crossfade.
    """
    if source_rate == target_rate:
        return audio
    length = audio.shape[0]
    target_length = int(round(length * target_rate / source_rate))
    spectrum = np.fft.rfft(audio, axis=0)
    bins = target_length // 2 + 1
    if bins <= spectrum.shape[0]:
        spectrum = spectrum[:bins]
    else:
        spectrum = np.pad(spectrum, ((0, bins - spectrum.shape[0]), (0, 0)))
    return np.fft.irfft(spectrum, n=target_length, axis=0) * (target_length / length)


def high_pass(audio: np.ndarray, cutoff_hz: float, rate: int) -> np.ndarray:
    """Zero out everything below cutoff_hz. Linear phase, so no smearing."""
    spectrum = np.fft.rfft(audio, axis=0)
    freqs = np.fft.rfftfreq(audio.shape[0], 1 / rate)
    spectrum[freqs < cutoff_hz] = 0
    return np.fft.irfft(spectrum, n=audio.shape[0], axis=0)


def pick_region(audio: np.ndarray, need: int) -> np.ndarray:
    """Take `need` frames from the steadiest part of the clip.

    Generated audio tends to open with an attack and taper at the end, neither
    of which belongs in a loop. Rather than always taking the middle, this
    scores every candidate window by how *level* it is -- the spread of its
    short-term loudness -- and takes the flattest. A bed is supposed to sit
    still.
    """
    total = audio.shape[0]
    if total <= need:
        return np.pad(audio, ((0, need - total), (0, 0)), mode="wrap")

    mono = audio.mean(axis=1)
    hop = max(1, SAMPLE_RATE // 10)
    window = hop * 5
    levels = np.array([
        math.sqrt(float(np.mean(mono[i:i + window] ** 2)) + 1e-12)
        for i in range(0, total - window, hop)
    ])

    span = max(1, need // hop)
    best_start, best_score = 0, float("inf")
    for start in range(0, max(1, len(levels) - span)):
        chunk = levels[start:start + span]
        if len(chunk) < span:
            break
        # Penalise unevenness relative to loudness: a silent stretch is
        # perfectly level and completely useless.
        score = float(np.std(chunk)) / (float(np.mean(chunk)) + 1e-9)
        if score < best_score:
            best_start, best_score = start * hop, score
    return audio[best_start:best_start + need]


def close_the_loop(audio: np.ndarray, crossfade: int) -> np.ndarray:
    """Fold the tail back over the head so the wrap is continuous.

    Given `length + crossfade` frames, returns `length`. The tail is mixed into
    the head on an equal-power curve, so the last sample leads into the first
    the way any other sample leads into its neighbour.

    Equal power rather than linear: two decorrelated signals summed on a linear
    fade dip by 3 dB in the middle, which is audible as a hole once per loop.
    """
    length = audio.shape[0] - crossfade
    t = np.linspace(0, 1, crossfade, endpoint=False)[:, None]
    rising = np.sin(t * np.pi / 2)   # 0 -> 1, applied to the head
    falling = np.cos(t * np.pi / 2)  # 1 -> 0, applied to the folded tail
    loop = audio[:length].copy()
    loop[:crossfade] = (
        audio[:crossfade] * rising + audio[length:length + crossfade] * falling
    )
    return loop


def energy_above(audio: np.ndarray, floor_hz: float, rate: int) -> float:
    """Share of the signal's power above floor_hz, by FFT.

    make_loops.py computes this from its partial table, which is exact for pure
    tones and impossible for anything else. With numpy present it can finally
    be measured on real audio, which is what makes generated beds checkable.
    """
    spectrum = np.abs(np.fft.rfft(audio.mean(axis=1)))
    freqs = np.fft.rfftfreq(audio.shape[0], 1 / rate)
    power = spectrum ** 2
    total = float(power.sum())
    if total <= 0:
        return 0.0
    return float(power[freqs > floor_hz].sum()) / total


def centroid_hz(audio: np.ndarray, rate: int) -> float:
    """Power-weighted mean frequency: one number for how bright a bed is.

    Cheap, and it separates the two failure modes the floor alone cannot: a bed
    that is all rumble sits far below the range, one that is all hiss far above.
    """
    spectrum = np.abs(np.fft.rfft(audio.mean(axis=1)))
    freqs = np.fft.rfftfreq(audio.shape[0], 1 / rate)
    power = spectrum ** 2
    total = float(power.sum())
    return float((freqs * power).sum() / total) if total > 0 else 0.0


def seam_report(channel: np.ndarray) -> tuple[float, float, float]:
    """How big the jump at the loop point is, against the biggest jump inside.

    Ratio near or below 1.0 means the wrap is indistinguishable from any other
    sample-to-sample step -- genuinely seamless, not merely faded. The same
    measure make_loops.py uses, so the two kinds of bed compare directly.
    """
    seam = abs(float(channel[0] - channel[-1]))
    steps = np.abs(np.diff(channel))
    worst = float(steps.max()) if len(steps) else 0.0
    return seam, worst, (seam / worst if worst else 0.0)


def process(
    audio: np.ndarray, rate: int, *, loop_seconds: float = LOOP_SECONDS
) -> tuple[np.ndarray, dict]:
    """Clip in, seamless level-matched bed out, with the numbers that prove it.

    Takes samples rather than a path so a generated clip can go straight from
    the model into this without a round trip through disk.
    """
    frames = int(SAMPLE_RATE * loop_seconds)
    crossfade = int(SAMPLE_RATE * CROSSFADE_SECONDS)

    audio = resample(audio, rate, SAMPLE_RATE)
    audio = high_pass(audio, RUMBLE_HZ, SAMPLE_RATE)
    region = pick_region(audio, frames + crossfade)
    loop = close_the_loop(region, crossfade)

    level = max(
        math.sqrt(float(np.mean(loop[:, 0] ** 2))),
        math.sqrt(float(np.mean(loop[:, 1] ** 2))),
    )
    if level <= 0:
        raise ValueError(f"{path.name} is silent")
    loop *= TARGET_RMS / level

    peak = float(np.abs(loop).max())
    if peak > PEAK_CEILING:
        loop *= PEAK_CEILING / peak

    seam, worst, ratio = seam_report(loop[:, 0])
    audible = energy_above(loop, SPEAKER_FLOOR_HZ, SAMPLE_RATE)
    centroid = centroid_hz(loop, SAMPLE_RATE)
    return loop, {
        "centroid_hz": round(centroid, 1),
        "shrill": bool(centroid > MAX_CENTROID_HZ),
        # The single flag a caller should branch on: loud enough to hear, and
        # not so bright it has no body.
        "usable": bool(audible >= MIN_ENERGY_ABOVE_FLOOR
                       and centroid <= MAX_CENTROID_HZ),
        "source_rate": rate,
        "loop_seconds": loop_seconds,
        "sample_rate": SAMPLE_RATE,
        "rms_dbfs": round(20 * math.log10(TARGET_RMS), 2),
        "peak_dbfs": round(20 * math.log10(max(float(np.abs(loop).max()), 1e-9)), 2),
        "seam_step": round(seam, 8),
        "worst_internal_step": round(worst, 8),
        "seam_ratio": round(ratio, 4),
        "energy_above_200hz": round(audible, 4),
        "audible": bool(audible >= MIN_ENERGY_ABOVE_FLOOR),
    }


def loopify(path: Path, *, loop_seconds: float = LOOP_SECONDS) -> tuple[np.ndarray, dict]:
    """[process] for a clip already on disk."""
    audio, rate = load(path)
    return process(audio, rate, loop_seconds=loop_seconds)


def write_wav(path: Path, loop: np.ndarray) -> None:
    sf.write(str(path), np.clip(loop, -1.0, 1.0), SAMPLE_RATE, subtype="PCM_16")


def write_wav_at(path: Path, audio: np.ndarray, rate: int) -> None:
    """Write at the source's own rate. For keeping the model's raw output next
    to the processed bed, which is the only way to hear what the processing
    did."""
    if audio.ndim == 1:
        audio = audio[:, None]
    sf.write(str(path), np.clip(audio, -1.0, 1.0), rate, subtype="PCM_16")


def self_test() -> int:
    """Check the processing against material whose answer is already known.

    Two cases, because either alone would mislead:

      * an existing synthesised bed, which is already seamless -- processing it
        must not *break* anything;
      * a deliberately broken loop, cut at an arbitrary offset so its ends do
        not meet -- processing it must actually fix the seam.
    """
    beds = ROOT / "phase1" / "assets" / "music"
    scratch = Path(__file__).resolve().parent / ".loopify-selftest"
    scratch.mkdir(exist_ok=True)
    failures = 0

    for name in ("ominous", "calm", "whimsical"):
        source = beds / f"{name}.wav"
        if not source.exists():
            print(f"  !  {name}: no such bed, skipped")
            continue

        _, report = loopify(source)
        ok = report["audible"] and report["seam_ratio"] < 2
        failures += 0 if ok else 1
        print(f"  {'ok ' if ok else 'FAIL'} {name:12s} intact bed: seam ratio "
              f"{report['seam_ratio']:.3f}, "
              f"{100 * report['energy_above_200hz']:.1f}% above 200 Hz")

        # Now break it on purpose: a chunk from an arbitrary offset, whose
        # length is not a whole number of any partial's cycles, so its ends do
        # not meet. This is what a generated clip looks like.
        audio, rate = load(source)
        broken = audio[7777:7777 + int(rate * 12.37)]
        broken_path = scratch / f"{name}-broken.wav"
        write_wav(broken_path, broken)

        cut = float(np.abs(broken[0] - broken[-1]).max())
        steps = float(np.abs(np.diff(broken[:, 0])).max())
        raw_ratio = cut / steps if steps else 0.0
        _, fixed = loopify(broken_path, loop_seconds=8.0)
        closed = fixed["seam_ratio"]

        ok = closed < max(2.0, raw_ratio)
        failures += 0 if ok else 1
        print(f"  {'ok ' if ok else 'FAIL'} {name:12s} broken cut: ratio "
              f"{raw_ratio:.1f} -> {closed:.3f}")

    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description="Loopify an audio clip.")
    parser.add_argument("source", nargs="?", type=Path)
    parser.add_argument("-o", "--out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        print("loopify self-test")
        failures = self_test()
        print("all good" if not failures else f"{failures} failure(s)")
        raise SystemExit(1 if failures else 0)

    if not args.source:
        parser.error("give a source file, or --self-test")

    loop, report = loopify(args.source)
    out = args.out or args.source.with_suffix(".loop.wav")
    write_wav(out, loop)
    print(json.dumps(report, indent=2))
    print(f"wrote {out}")
    if not report["usable"]:
        raise SystemExit(
            f"only {100 * report['energy_above_200hz']:.1f}% of the energy is "
            f"above {SPEAKER_FLOOR_HZ} Hz; this will be inaudible on a laptop "
            "speaker"
        )


if __name__ == "__main__":
    main()
