"""Generate the eight mood loops in phase1/assets/music/.

    phase0/.venv/Scripts/python.exe phase1/tool/make_loops.py

Run from the repository root. Standard library only.

Why generated rather than downloaded
------------------------------------
The plan for this phase was a library of CC0/CC-BY loops from OpenGameArt.
Those are reachable and a licensed set is committed alongside this one (see
assets/music/licensed/). But three properties decide whether a crossfading
score is pleasant or awful, and with found music none of them could be
verified on this machine -- there is no ffmpeg and no numpy here, so an
MP3 cannot be decoded, trimmed, re-levelled or even measured:

  * seamless looping -- a click at every wrap ruins the effect;
  * matched loudness -- a bed 6 dB louder than its neighbour turns every
    crossfade into a lurch, which reads as "the music is broken";
  * a coherent voice -- eight tracks by eight composers crossfade into a
    mixtape, not a score.

Synthesis gets all three by construction. Every partial and every LFO is an
exact integer multiple of 1/LOOP_SECONDS, so the loop point is mathematically
continuous rather than merely close; every bed is normalised to the same RMS;
and they all come out of the same three lines of synthesis code, so they share
a timbre and a reverb-less, low-register character.

That character is also a deliberate choice for reading. Music under prose has
to survive being ignored: melody competes with the reader's inner voice, so
these are slow harmonic beds with no tune, no percussion and little above
1.5 kHz. They are meant to be noticed only when they change.

The manifest this writes has the same shape as the licensed one, so swapping
libraries is a one-line change in lib/music_library.dart, not a code change.
"""

import json
import math
import struct
import wave
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "phase1" / "assets" / "music"

SAMPLE_RATE = 22050  # nothing here lives above ~1.5 kHz; 11 kHz of bandwidth
LOOP_SECONDS = 24.0  # is plenty, and it keeps the committed assets small
FRAMES = int(SAMPLE_RATE * LOOP_SECONDS)
TARGET_RMS = 0.14  # about -17 dBFS; the engine scales down from here

# Built-in speakers roll off hard below about 200 Hz. A bed whose energy all
# sits underneath that is inaudible on a laptop however good its meters look,
# which is exactly what happened to the first version of this file. Every bed
# must put at least this fraction of its energy above the floor.
SPEAKER_FLOOR_HZ = 200
MIN_ENERGY_ABOVE_FLOOR = 0.15
PEAK_CEILING = 0.89  # about -1 dBFS

# A sine table beats math.sin per sample by a wide margin in pure Python. At
# 64k entries the error sits near -90 dBFS, which is inaudible under a pad.
TABLE_BITS = 16
TABLE_SIZE = 1 << TABLE_BITS
SINE = array("d", (math.sin(2 * math.pi * i / TABLE_SIZE) for i in range(TABLE_SIZE)))


def cycles_for(freq):
    """Whole number of cycles nearest to `freq` over one loop.

    This is the whole trick behind a seamless loop: if every component completes
    an integer number of cycles, the waveform at the end of the buffer continues
    exactly into its own beginning.

    Everything below indexes the sine table as `i * cycles * TABLE_SIZE //
    FRAMES` rather than accumulating a rounded phase increment. Accumulating
    would drift -- the rounded step does not divide the table exactly -- and
    leave a small step at the loop point, which is audible as a tick once a
    minute. Computing the index from `i` costs a multiply and a divide per
    sample and is exact: at i == FRAMES the index is a whole number of table
    wraps, by construction.
    """
    return max(1, round(freq * LOOP_SECONDS))


# Each partial: (ratio above the root, amplitude, stereo detune in loop-grid
# steps, LFO rate in loop-grid steps, LFO depth 0-1).
#
# A detune of n/LOOP_SECONDS Hz makes the two channels beat against each other
# with a period of LOOP_SECONDS/n -- slow stereo movement that is still exactly
# periodic over the loop, so it costs nothing at the seam.
# Registers and upper partials are chosen so the beds survive a laptop speaker.
# The first version of this table did not, and it was silent in practice: roots
# ran 55-147 Hz with partials no higher than 4x, which left 'tense', 'ominous'
# and 'neutral' with *zero* energy above 200 Hz and every bed with zero above
# 500 Hz. Built-in speakers roll off hard below ~200 Hz, so the app dutifully
# played a cue nobody could hear. "Sits under the prose" has to stay above the
# playback hardware.
#
# So every bed now carries partials out to 4-6x its root, and check_spectrum()
# keeps it that way. The low fundamentals are still there for headphones and
# anything with a woofer; the upper partials are what make it audible without.
BEDS = {
    # mood: (root Hz, [partials], description)
    "calm": (
        164.8,
        [(1.0, 1.00, 1, 1, 0.25), (1.5, 0.60, 2, 2, 0.30), (2.0, 0.42, 1, 3, 0.30),
         (3.0, 0.26, 3, 2, 0.35), (4.0, 0.16, 2, 4, 0.40), (6.0, 0.09, 3, 3, 0.45)],
        "open fifth pad, slow shimmer",
    ),
    "neutral": (
        146.8,
        [(1.0, 1.00, 1, 1, 0.15), (1.5, 0.50, 2, 2, 0.20), (2.0, 0.32, 1, 3, 0.22),
         (3.0, 0.18, 2, 2, 0.25), (4.0, 0.10, 3, 4, 0.28)],
        "root and fifth, low profile",
    ),
    "melancholic": (
        146.8,
        [(1.0, 1.00, 1, 1, 0.20), (1.2, 0.62, 2, 2, 0.30), (1.5, 0.46, 1, 3, 0.25),
         (2.0, 0.34, 2, 2, 0.32), (3.0, 0.20, 3, 5, 0.40), (4.8, 0.11, 2, 4, 0.45)],
        "minor third over a sustained root",
    ),
    "romantic": (
        164.8,
        [(1.0, 1.00, 1, 1, 0.20), (1.25, 0.64, 2, 2, 0.25), (1.5, 0.50, 1, 3, 0.22),
         (2.0, 0.34, 2, 2, 0.28), (2.25, 0.24, 3, 4, 0.32), (4.0, 0.13, 2, 5, 0.38)],
        "major triad with an added ninth, warm",
    ),
    "triumphant": (
        164.8,
        [(1.0, 1.00, 1, 1, 0.12), (1.25, 0.72, 2, 2, 0.15), (1.5, 0.68, 1, 2, 0.15),
         (2.0, 0.50, 2, 3, 0.18), (3.0, 0.34, 3, 3, 0.20), (4.0, 0.22, 2, 4, 0.24),
         (6.0, 0.12, 3, 5, 0.28)],
        "full major stack, bright and wide",
    ),
    "whimsical": (
        220.0,
        [(1.0, 0.90, 1, 2, 0.35), (1.125, 0.48, 2, 3, 0.40), (1.25, 0.58, 1, 4, 0.35),
         (1.5, 0.52, 3, 3, 0.30), (1.6875, 0.36, 2, 5, 0.45), (2.0, 0.30, 1, 6, 0.50),
         (3.0, 0.16, 2, 4, 0.50)],
        "major pentatonic, higher register, light",
    ),
    # These two are the darkest beds and the hardest to keep audible, because
    # most of their weight is in the fundamental and the octave. Both sit an
    # octave above where the ear would want them; below that, the octave
    # partial itself falls under 200 Hz and takes the bed with it.
    # Was a tritone stack -- ratios of sqrt(2) -- and that was too specific a
    # thing to say. The tritone is *the* horror interval, so every paragraph
    # tagged 'ominous' came out sounding like a horror film. But one label
    # covers far more than that: across the cached tags it holds "Alice's fall
    # into the well", "Scrooge's cold, calculating tone", "describes historical
    # disasters and sieges" and "Phantoms and chains". Only the last is horror.
    # The others are dread, social menace, and weight -- an intense stretch
    # where something bad *could* happen, which is most of what 'ominous' means
    # in a score.
    #
    # So this is deliberately less specific: low mass from the root and fifth,
    # a minor third for colour, and one unresolved voice a semitone above the
    # upper fifth (352 against 330) that beats rather than bites. Unsettled, not
    # evil. Making the horror books actually sound like horror is a job for the
    # genre seed, which the app already computes and currently throws away --
    # see "What the loops honestly cannot do" in the README.
    "ominous": (
        110.0,
        [(1.0, 1.00, 1, 1, 0.20), (1.5, 0.52, 2, 2, 0.24), (2.0, 0.46, 1, 2, 0.25),
         (2.4, 0.30, 2, 3, 0.30), (3.0, 0.20, 3, 3, 0.32), (3.2, 0.13, 2, 5, 0.42),
         (6.0, 0.08, 3, 4, 0.45)],
        "low minor drone with one unresolved voice above it",
    ),
    "tense": (
        146.8,
        [(1.0, 1.00, 1, 1, 0.18), (1.0595, 0.64, 2, 1, 0.22), (1.5, 0.44, 1, 3, 0.28),
         (2.0, 0.34, 2, 4, 0.30), (2.119, 0.24, 3, 5, 0.35), (3.0, 0.18, 2, 3, 0.32),
         (4.0, 0.11, 3, 6, 0.40)],
        "minor-second cluster with a slow pulse",
    ),
}

# Only 'tense' gets an outright pulse. It is the one mood where a heartbeat
# under the prose is doing work rather than being a distraction.
TREMOLO = {"tense": (4.5, 0.32)}  # rate Hz, depth


def envelope(lfo_cycles, depth):
    """One loop of a slow amplitude sweep, exactly periodic."""
    mask = TABLE_SIZE - 1
    step = lfo_cycles * TABLE_SIZE
    floor = 1.0 - depth
    return array("d", (
        floor + depth * (0.5 + 0.5 * SINE[(i * step // FRAMES) & mask])
        for i in range(FRAMES)
    ))


def render(mood):
    root, partials, _ = BEDS[mood]
    left = array("d", bytes(8 * FRAMES))
    right = array("d", bytes(8 * FRAMES))
    mask = TABLE_SIZE - 1

    for ratio, amp, detune_cycles, lfo_cycles, lfo_depth in partials:
        base_cycles = cycles_for(root * ratio)
        # Both channels share one envelope; only the frequency differs. A
        # detune of n cycles per loop beats with a period of LOOP_SECONDS/n --
        # slow stereo movement that is still exactly periodic over the loop.
        lfo = envelope(lfo_cycles, lfo_depth)
        for channel, cycles in (
            (left, base_cycles),
            (right, base_cycles + detune_cycles),
        ):
            step = cycles * TABLE_SIZE
            for i in range(FRAMES):
                channel[i] += amp * lfo[i] * SINE[(i * step // FRAMES) & mask]

    if mood in TREMOLO:
        rate, depth = TREMOLO[mood]
        pulse = envelope(cycles_for(rate), depth)
        for i in range(FRAMES):
            left[i] *= pulse[i]
            right[i] *= pulse[i]

    return left, right


def audible_fraction(mood):
    """Share of a bed's energy above SPEAKER_FLOOR_HZ.

    Computed from the partial table rather than the rendered audio: these are
    pure tones at known frequencies, so the answer is exact and needs no FFT --
    which matters, because there is no numpy here to do one with.
    """
    root, partials, _ = BEDS[mood]
    total = sum(amp * amp for _, amp, *_ in partials)
    above = sum(amp * amp for ratio, amp, *_ in partials
                if root * ratio > SPEAKER_FLOOR_HZ)
    return above / total


def rms(channel):
    return math.sqrt(sum(v * v for v in channel) / len(channel))


def seam_report(channel):
    """How big the jump at the loop point is, against the biggest jump inside.

    Ratio near or below 1.0 means the wrap is indistinguishable from any other
    sample-to-sample step -- i.e. genuinely seamless, not just faded.
    """
    seam = abs(channel[0] - channel[-1])
    worst = 0.0
    for i in range(0, len(channel) - 1, 7):  # every 7th step is plenty
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

    # Check before spending three minutes rendering something inaudible.
    too_low = {mood: audible_fraction(mood) for mood in BEDS
               if audible_fraction(mood) < MIN_ENERGY_ABOVE_FLOOR}
    if too_low:
        raise SystemExit(
            "these beds have too little energy above "
            f"{SPEAKER_FLOOR_HZ} Hz to be heard on a laptop speaker:\n"
            + "\n".join(f"  {mood}: {100 * share:.1f}% "
                        f"(need {100 * MIN_ENERGY_ABOVE_FLOOR:.0f}%)"
                        for mood, share in sorted(too_low.items()))
            + "\nraise the root or add upper partials."
        )

    rendered = {}

    for mood in BEDS:
        left, right = render(mood)
        # Normalise every bed to the same RMS. This is what keeps a crossfade
        # from sounding like a volume change: the engine is then the only thing
        # deciding loudness.
        level = max(rms(left), rms(right))
        gain = TARGET_RMS / level
        peak = max(max(abs(v) for v in left), max(abs(v) for v in right)) * gain
        rendered[mood] = (left, right, gain, peak)
        print(f"{mood:12s} rms->{TARGET_RMS:.3f}  peak {peak:.3f}")

    # If any bed would clip, pull the whole set down by the same amount so they
    # stay level-matched relative to each other.
    worst_peak = max(peak for _, _, _, peak in rendered.values())
    headroom = min(1.0, PEAK_CEILING / worst_peak)
    if headroom < 1.0:
        print(f"scaling all beds by {headroom:.3f} to keep peaks under "
              f"{PEAK_CEILING}")

    entries = []
    for mood, (left, right, gain, peak) in rendered.items():
        scale = gain * headroom
        path = OUT_DIR / f"{mood}.wav"
        write_wav(path, left, right, scale)
        seam, worst, ratio = seam_report(left)
        root, partials, description = BEDS[mood]
        entries.append({
            "mood": mood,
            "file": f"{mood}.wav",
            "description": description,
            "root_hz": root,
            "partials": len(partials),
            "loop_seconds": LOOP_SECONDS,
            "sample_rate": SAMPLE_RATE,
            "rms_dbfs": round(20 * math.log10(TARGET_RMS * headroom), 2),
            "peak_dbfs": round(20 * math.log10(peak * headroom), 2),
            "seam_step": round(seam, 8),
            "worst_internal_step": round(worst, 8),
            "seam_ratio": round(ratio, 4),
            "energy_above_200hz": round(audible_fraction(mood), 4),
            "source": "generated by phase1/tool/make_loops.py",
            "license": "All rights reserved (no third-party material)",
            "attribution": None,
        })
        print(f"wrote {path.relative_to(ROOT)}  "
              f"seam {seam:.2e} vs worst step {worst:.2e} (ratio {ratio:.3f})")

    manifest = {
        "library": "generated",
        "note": "Synthesised reading beds. See tool/make_loops.py for why, and "
                "assets/music/licensed/manifest.json for the CC0/CC-BY set.",
        "loops": sorted(entries, key=lambda e: e["mood"]),
    }
    (OUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {(OUT_DIR / 'manifest.json').relative_to(ROOT)}")


if __name__ == "__main__":
    main()
