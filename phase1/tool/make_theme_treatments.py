"""EXPERIMENT -- Phase 5, Task 0. Delete this once the question is answered.

    phase0/.venv/Scripts/python.exe phase1/tool/make_theme_treatments.py

Run from the repository root. Standard library only, like make_loops.py.

The question
------------
Phase 4 measured that the score holds one cue for 20-56 consecutive paragraphs.
Mood is not a fine enough signal to move the music, so more mood-keyed loops
would change nothing. The proposed fix is a second axis: one melodic idea,
several treatments of it, chosen by something that *does* move paragraph to
paragraph.

This file renders four treatments of ONE motif so a human can answer the only
question that matters before any of it is built for real: does moving between
them feel alive, or does it feel arbitrary?

It is deliberately not a generator. The motif below was written by hand, so
that a bad verdict indicts the *idea* rather than some model's melody-writing.

What is borrowed from make_loops.py, and why
--------------------------------------------
The exact-index phase rule and the 200 Hz audibility guard, both non-negotiable:

  * Every component indexes the sine table as `i * cycles * TABLE_SIZE //
    FRAMES`, computed from the absolute sample position. Accumulating a rounded
    phase increment drifts and ticks once per loop.
  * A bed whose energy all sits below ~200 Hz is inaudible on a laptop speaker
    however good its meters look. That mistake cost Phase 3 an entire round of
    passing tests over silent audio.

What is new here is notes. A sustained pad is exactly periodic by construction;
a melody is not, because notes start and stop. Two properties make it seamless
anyway:

  * every note's envelope reaches exactly zero at both of its ends, so an onset
    can never be a step however the underlying sine happens to be phased;
  * notes are allowed to ring past their slot, and the overflow wraps to the
    top of the buffer. That wrap is exact rather than approximate: a partial
    completes a whole number of cycles per loop, so sample i and sample
    i + FRAMES sit at the same phase, and `(i * step // FRAMES) & mask` returns
    the same table index for both. The last note therefore rings into the first
    one across the loop point, which is also what makes it musical.

Pitch survives the loop grid. Frequencies quantise to 1/LOOP_SECONDS = 1/24 Hz,
which at 293 Hz is under a twentieth of a cent -- inaudible, and far below the
error of any instrument this is pretending to be.
"""

import json
import math
import wave
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "phase1" / "assets" / "music" / "experiment"

# Identical to make_loops.py so the two libraries are level- and format-matched
# and can be compared without the difference being one of mastering.
SAMPLE_RATE = 22050
LOOP_SECONDS = 24.0
FRAMES = int(SAMPLE_RATE * LOOP_SECONDS)
TARGET_RMS = 0.14
SPEAKER_FLOOR_HZ = 200
MIN_ENERGY_ABOVE_FLOOR = 0.15
PEAK_CEILING = 0.89

TABLE_BITS = 16
TABLE_SIZE = 1 << TABLE_BITS
MASK = TABLE_SIZE - 1
SINE = array("d", (math.sin(2 * math.pi * i / TABLE_SIZE) for i in range(TABLE_SIZE)))

# 16 beats over 24 seconds is 40 BPM: slow enough that the tune reads as a
# presence rather than a song. make_loops.py deliberately wrote beds with no
# melody at all, on the grounds that a tune competes with the reader's inner
# voice. That worry is real and this experiment is partly a test of it, so the
# melody is kept slow, quiet and low in the mix rather than made a feature.
BEATS = 16
BEAT_FRAMES = FRAMES // BEATS  # 24 s / 16 = 1.5 s exactly
RING_FRAMES = int(0.7 * BEAT_FRAMES)  # how far a note may sound past its slot

# The motif: (scale degree, beats). Degree 0 is the tonic, 4 the fifth,
# -1 the note below the tonic. Written in degrees rather than semitones so
# that changing mode is a change of one table, which is the whole point --
# "the same melody, but darker" has to be a transformation, not a new tune.
#
# Shape: rises 1-5-6, falls home 5-4-3-4-2-1, then steps below the tonic and
# drops to the fifth beneath it, which leads back into the repeat.
MOTIF = [
    (0, 2), (4, 1), (5, 1), (4, 2), (3, 1), (2, 1),
    (3, 1), (1, 2), (0, 1), (-1, 1), (0, 2), (-3, 1),
]
assert sum(beats for _, beats in MOTIF) == BEATS

MODES = {
    "dorian": (0, 2, 3, 5, 7, 9, 10),     # minor with a raised 6th: the least dark
    "aeolian": (0, 2, 3, 5, 7, 8, 10),    # natural minor
    "phrygian": (0, 1, 3, 5, 7, 8, 10),   # flat 2nd: the darkest of the three
}

# Every note is three partials. Enough to have a timbre, few enough to render
# in pure Python inside a few minutes.
NOTE_PARTIALS = ((1.0, 1.00), (2.0, 0.30), (3.0, 0.12))

D3, D4 = 146.83, 293.66

# The ladder. Four treatments of the one motif, from barely-there to pressing.
# Each is a band of the classifier's intensity, which is the axis measured to
# actually move inside a held cue: over the Carol's 56-paragraph stretch it
# swings 0.20 to 0.90 while the mood label never changes.
#
#   voices: (degree offset within the mode, octave shift, amplitude)
#   pad:    (ratio above pad_root, amplitude, detune cycles, LFO cycles, depth)
TREATMENTS = {
    "treatment-a": dict(
        band="intensity below 0.35",
        mode="dorian",
        motif_notes=6,     # the opening gesture only, not the whole tune
        stretch=2.0,       # at half speed, so the fragment still fills the loop
        root=D4,
        voices=[(0, 0, 0.34)],
        pad_root=D3,
        pad=[(1.0, 0.55, 1, 1, 0.28), (1.5, 0.34, 2, 2, 0.30),
             (2.0, 0.20, 1, 3, 0.32), (3.0, 0.10, 3, 2, 0.35),
             (4.0, 0.06, 2, 4, 0.40)],
        tremolo=None,
        description="theme fragment, half speed, open fifth under it (Dorian)",
    ),
    "treatment-b": dict(
        band="intensity 0.35 to 0.55",
        mode="aeolian",
        motif_notes=None,  # the whole motif
        stretch=1.0,
        root=D4,
        voices=[(0, 0, 0.42)],
        pad_root=D3,
        pad=[(1.0, 0.60, 1, 1, 0.20), (1.5, 0.38, 2, 2, 0.24),
             (2.0, 0.24, 1, 3, 0.26), (3.0, 0.13, 2, 2, 0.30),
             (4.0, 0.07, 3, 4, 0.34)],
        tremolo=None,
        description="the theme plain, one voice, root and fifth (Aeolian)",
    ),
    "treatment-c": dict(
        band="intensity 0.55 to 0.75",
        mode="aeolian",
        motif_notes=None,
        stretch=1.0,
        root=D4,
        # The tune, a scale third beneath it, and an octave doubling. Same
        # notes, more weight.
        voices=[(0, 0, 0.40), (-2, 0, 0.22), (0, -1, 0.20)],
        pad_root=D3,
        pad=[(1.0, 0.62, 1, 1, 0.20), (1.2, 0.30, 2, 3, 0.28),
             (1.5, 0.40, 1, 2, 0.24), (2.0, 0.26, 2, 2, 0.28),
             (3.0, 0.15, 3, 5, 0.34), (4.8, 0.08, 2, 4, 0.40)],
        tremolo=(3.0, 0.12),
        description="theme in thirds over a minor pad, faint pulse (Aeolian)",
    ),
    "treatment-d": dict(
        band="intensity 0.75 and above",
        mode="phrygian",
        motif_notes=None,
        stretch=1.0,
        root=D4,
        # Dropped an octave and doubled: the same tune, heavier and lower.
        voices=[(0, -1, 0.46), (0, 0, 0.30)],
        pad_root=D3,
        # The minor-second cluster and 4.5 Hz pulse that make the existing
        # 'tense' bed what it is, so the top of this ladder lands somewhere the
        # rest of the app already sounds like.
        pad=[(1.0, 0.62, 1, 1, 0.18), (1.0595, 0.40, 2, 1, 0.22),
             (1.5, 0.30, 1, 3, 0.28), (2.0, 0.24, 2, 4, 0.30),
             (3.0, 0.14, 2, 3, 0.32), (4.0, 0.08, 3, 6, 0.38)],
        tremolo=(4.5, 0.28),
        description="theme an octave down and doubled, cluster pad, pulse "
                    "(Phrygian)",
    ),
}


def cycles_for(freq):
    """Whole number of cycles nearest to `freq` over one loop. See make_loops."""
    return max(1, round(freq * LOOP_SECONDS))


def semitone(degree, mode):
    """Scale degree to semitones, wrapping octaves for degrees outside 0-6."""
    octave, index = divmod(degree, 7)
    return 12 * octave + mode[index]


def note_plan(spec):
    """Every note to be sounded: (start frame, length, frequency, amplitude).

    Lengths run past the note's slot by RING_FRAMES so notes overlap slightly
    and the last one rings across the loop point.
    """
    mode = MODES[spec["mode"]]
    motif = MOTIF if spec["motif_notes"] is None else MOTIF[: spec["motif_notes"]]
    stretch = spec["stretch"]

    plan = []
    for degree_offset, octave_shift, amp in spec["voices"]:
        position = 0
        for degree, beats in motif:
            length = int(beats * stretch * BEAT_FRAMES)
            steps = semitone(degree + degree_offset, mode) + 12 * octave_shift
            freq = spec["root"] * (2 ** (steps / 12))
            plan.append((position, length + RING_FRAMES, freq, amp))
            position += length
        assert position == FRAMES, f"{spec['mode']} motif does not fill the loop"
    return plan


def note_envelope(length):
    """A note shape that is exactly zero at both ends.

    That is the property doing the work: whatever phase the sine happens to be
    at when a note begins, multiplying by zero means the onset cannot be a step.
    """
    attack = max(1, int(0.08 * length))
    release = max(1, int(0.40 * length))
    out = array("d", bytes(8 * length))
    for i in range(length):
        rise = 0.5 - 0.5 * math.cos(math.pi * min(1.0, i / attack))
        fall = 0.5 - 0.5 * math.cos(math.pi * min(1.0, (length - 1 - i) / release))
        decay = 0.55 + 0.45 * math.exp(-3.0 * i / length)
        out[i] = rise * fall * decay
    return out


def envelope(lfo_cycles, depth):
    """One loop of a slow amplitude sweep, exactly periodic. From make_loops."""
    step = lfo_cycles * TABLE_SIZE
    floor = 1.0 - depth
    return array("d", (
        floor + depth * (0.5 + 0.5 * SINE[(i * step // FRAMES) & MASK])
        for i in range(FRAMES)
    ))


def render(name):
    spec = TREATMENTS[name]
    left = array("d", bytes(8 * FRAMES))
    right = array("d", bytes(8 * FRAMES))

    # --- the pad: exactly periodic, identical in kind to make_loops.py -------
    for ratio, amp, detune_cycles, lfo_cycles, lfo_depth in spec["pad"]:
        base = cycles_for(spec["pad_root"] * ratio)
        lfo = envelope(lfo_cycles, lfo_depth)
        for channel, cycles in ((left, base), (right, base + detune_cycles)):
            step = cycles * TABLE_SIZE
            for i in range(FRAMES):
                channel[i] += amp * lfo[i] * SINE[(i * step // FRAMES) & MASK]

    # --- the melody ---------------------------------------------------------
    # Written with `j` running past FRAMES and wrapped on store. The sine index
    # uses the unwrapped j, so a wrapped tail lands at exactly the phase it
    # would have had -- see the module docstring.
    for start, length, freq, amp in note_plan(spec):
        shape = note_envelope(length)
        for ratio, partial_amp in NOTE_PARTIALS:
            step = cycles_for(freq * ratio) * TABLE_SIZE
            level = amp * partial_amp
            # A little stereo spread, and it costs nothing at the seam because
            # both channels are still whole-cycle.
            for channel, offset in ((left, 0), (right, 1)):
                voice_step = step + offset * TABLE_SIZE
                for k in range(length):
                    j = start + k
                    channel[j % FRAMES] += (
                        level * shape[k] * SINE[(j * voice_step // FRAMES) & MASK]
                    )

    if spec["tremolo"]:
        rate, depth = spec["tremolo"]
        pulse = envelope(cycles_for(rate), depth)
        for i in range(FRAMES):
            left[i] *= pulse[i]
            right[i] *= pulse[i]

    return left, right


def audible_fraction(name):
    """Share of a treatment's energy above SPEAKER_FLOOR_HZ.

    Computed from the specification rather than by FFT, as in make_loops.py:
    every component is a pure tone at a known frequency, so the answer is exact
    and needs no numpy. Notes are weighted by how long they sound.
    """
    spec = TREATMENTS[name]
    total = above = 0.0

    for ratio, amp, *_ in spec["pad"]:
        energy = amp * amp
        total += energy
        if spec["pad_root"] * ratio > SPEAKER_FLOOR_HZ:
            above += energy

    for _, length, freq, amp in note_plan(spec):
        share = length / FRAMES
        for ratio, partial_amp in NOTE_PARTIALS:
            energy = (amp * partial_amp) ** 2 * share
            total += energy
            if freq * ratio > SPEAKER_FLOOR_HZ:
                above += energy

    return above / total


def rms(channel):
    return math.sqrt(sum(v * v for v in channel) / len(channel))


def seam_report(channel):
    """How big the jump at the loop point is, against the biggest jump inside."""
    seam = abs(channel[0] - channel[-1])
    worst = 0.0
    for i in range(0, len(channel) - 1, 7):
        step = abs(channel[i + 1] - channel[i])
        if step > worst:
            worst = step
    return seam, worst, (seam / worst if worst else 0.0)


def write_wav(path, left, right, scale):
    frames = array("h", bytes(2 * 2 * FRAMES))
    for i in range(FRAMES):
        frames[2 * i] = max(-32768, min(32767, int(left[i] * scale * 32767)))
        frames[2 * i + 1] = max(-32768, min(32767, int(right[i] * scale * 32767)))
    with wave.open(str(path), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(frames.tobytes())


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    too_low = {name: audible_fraction(name) for name in TREATMENTS
               if audible_fraction(name) < MIN_ENERGY_ABOVE_FLOOR}
    if too_low:
        raise SystemExit(
            f"too little energy above {SPEAKER_FLOOR_HZ} Hz to hear on a "
            "laptop speaker:\n"
            + "\n".join(f"  {name}: {100 * share:.1f}% "
                        f"(need {100 * MIN_ENERGY_ABOVE_FLOOR:.0f}%)"
                        for name, share in sorted(too_low.items()))
        )

    rendered = {}
    for name in TREATMENTS:
        left, right = render(name)
        level = max(rms(left), rms(right))
        gain = TARGET_RMS / level
        peak = max(max(abs(v) for v in left), max(abs(v) for v in right)) * gain
        rendered[name] = (left, right, gain, peak)
        print(f"{name:12s} rms->{TARGET_RMS:.3f}  peak {peak:.3f}  "
              f"above {SPEAKER_FLOOR_HZ} Hz {100 * audible_fraction(name):.0f}%")

    # Level-match the set, exactly as make_loops.py does: a treatment 6 dB
    # louder than its neighbour would make every change read as a volume jump,
    # which would answer the experiment's question wrongly.
    worst_peak = max(peak for _, _, _, peak in rendered.values())
    headroom = min(1.0, PEAK_CEILING / worst_peak)
    if headroom < 1.0:
        print(f"scaling all treatments by {headroom:.3f}")

    entries = []
    for name, (left, right, gain, peak) in rendered.items():
        scale = gain * headroom
        path = OUT_DIR / f"{name}.wav"
        write_wav(path, left, right, scale)
        seam, worst, ratio = seam_report(left)
        spec = TREATMENTS[name]
        # The manifest key is 'mood' because that is what LoopLibrary reads;
        # here the value is a treatment name. The engine treats the cue key as
        # opaque, which is exactly why this experiment needs no audio changes.
        entries.append({
            "mood": name,
            "file": f"{name}.wav",
            "description": spec["description"],
            "band": spec["band"],
            "mode": spec["mode"],
            "loop_seconds": LOOP_SECONDS,
            "sample_rate": SAMPLE_RATE,
            "rms_dbfs": round(20 * math.log10(TARGET_RMS * headroom), 2),
            "peak_dbfs": round(20 * math.log10(peak * headroom), 2),
            "seam_step": round(seam, 8),
            "worst_internal_step": round(worst, 8),
            "seam_ratio": round(ratio, 4),
            "energy_above_200hz": round(audible_fraction(name), 4),
            "source": "generated by phase1/tool/make_theme_treatments.py",
            "license": "All rights reserved (no third-party material)",
            "attribution": None,
        })
        print(f"wrote {path.relative_to(ROOT)}  seam {seam:.2e} vs worst step "
              f"{worst:.2e} (ratio {ratio:.3f})")

    manifest = {
        "library": "experiment",
        "note": "PHASE 5 TASK 0 SCAFFOLDING. Four treatments of one hand-written "
                "motif, to test whether moving between treatments of a theme "
                "reads as musical. Delete with tool/make_theme_treatments.py "
                "once the question is answered.",
        "motif": [{"degree": d, "beats": b} for d, b in MOTIF],
        "beats_per_loop": BEATS,
        "loops": sorted(entries, key=lambda e: e["mood"]),
    }
    (OUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {(OUT_DIR / 'manifest.json').relative_to(ROOT)}")


if __name__ == "__main__":
    main()
