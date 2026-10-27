"""What MusicGen is asked for, and how takes are seeded and planned.

Extracted verbatim from phase1/tool/generate_beds.py -- the constants, the
prompt builder and the slot planner, with the measured reasoning that sits
above each one. A parity test (tests/test_parity.py) pins these to the
originals for as long as phase1 is in the repository, so a change made in one
place and not the other fails rather than drifting.

MOOD_PARAMS is vendored from phase0/mapper.py for the same reason the Dart
side ports it: phase0 is read-only reference, and a framework cannot import a
directory of experiments. Pinned to it by the same test.
"""

from __future__ import annotations

import hashlib
import math

# Each mood owns a tempo range, an energy floor and an instrumentation
# texture. Vendored from phase0/mapper.py; see the module docstring.
MOOD_PARAMS = {
    "tense":       {"music_mood": "suspense",   "bpm": (84, 132), "energy": 0.70, "texture": "pulsing low strings, percussive attacks"},
    "calm":        {"music_mood": "ambient",    "bpm": (56, 78),  "energy": 0.20, "texture": "sustained pads, wide reverb"},
    "melancholic": {"music_mood": "melancholy", "bpm": (52, 74),  "energy": 0.30, "texture": "solo lead over minor harmony"},
    "triumphant":  {"music_mood": "epic",       "bpm": (88, 130), "energy": 0.85, "texture": "brass and full ensemble"},
    "romantic":    {"music_mood": "romantic",   "bpm": (64, 92),  "energy": 0.45, "texture": "warm strings, close piano"},
    "ominous":     {"music_mood": "dark",       "bpm": (58, 86),  "energy": 0.50, "texture": "low drones, sparse percussion"},
    "whimsical":   {"music_mood": "playful",    "bpm": (96, 138), "energy": 0.50, "texture": "pizzicato strings, light woodwind"},
    "neutral":     {"music_mood": "background", "bpm": (68, 92),  "energy": 0.30, "texture": "neutral bed, low profile"},
}


# MusicGen emits 50 tokens per second of audio and was trained on 30-second
# spans, so this is its useful ceiling. loopify needs 24s of loop plus a 2s
# crossfade tail, and the rest is slack for it to choose a steady region from.
SECONDS = 30


TOKENS_PER_SECOND = 50


# The intensity bands, in the same order and at the same edges as
# lib/palette.dart. Two of them, from SUMMARY 9.24-9.29: there were four, and
# the prompt can reach exactly two registers (dark by default, bright on a
# height phrase), so four names were three crossfades in four that changed
# nothing. The edge, 0.65, is measured in 9.30 for how often it makes the
# score move.
BAND_NAMES = ["still", "peak"]


# A tonal centre per arc, and a mode per mood.
#
# Until now the prompt named a genre, a texture and a tempo, and never a key --
# so the 32 beds of one palette were generated in unrelated tonal centres and
# then crossfaded into each other over 2.5 seconds. Sustained pads a tritone
# apart is the most likely audible fault in the whole system, and it costs one
# clause of prompt text to remove.
#
# One tonic for the whole arc, so any two of its beds share a centre; the mode
# carries the mood. Parallel major and minor on the same tonic cross-fade
# cleanly, which a change of tonic would not. Arcs get different tonics, and
# that is safe because crossing an arc boundary swaps the library outright
# rather than crossfading (see MusicEngine.useLibrary).
#
# Naturals only. Sharps and flats survive the round trip through a text encoder
# less reliably, and six centres is already more spread than 27 arcs need.
KEY_TONICS = ["C", "D", "E", "F", "G", "A"]


# Kept here rather than in phase0/mapper.py, which is read-only reference.
MOOD_MODE = {
    "tense": "minor",
    "ominous": "minor",
    "melancholic": "minor",
    # Dorian: minor third but a raised sixth, so it reads as unresolved rather
    # than sad -- which is what a bed nobody is supposed to notice wants.
    "neutral": "Dorian",
    "calm": "major",
    "romantic": "major",
    "triumphant": "major",
    # Lydian: major with a raised fourth, the brightest of the usual modes.
    "whimsical": "Lydian",
}


def tonic_for(theme: dict) -> str:
    """This set's tonal centre.

    Deterministic, so re-running one cue lands in the same key as the beds it
    sits beside, and so two arcs that share a palette share a key by
    construction rather than by coincidence.

    Seeded from the set's identity when there is one, and from the theme text
    otherwise. Seeding from the text alone was measured and was not good
    enough: this book's arc themes repeat, so 17 of 34 arcs came out in D and
    long runs of the book shared a tonic. A key change is one of the strongest
    signals that a new section has begun, and it was being spent on nothing.
    """
    seed = theme.get("key_seed") or \
        f"{theme['genre_seed']}|{theme['overall_theme']}"
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()
    return KEY_TONICS[int(digest[:8], 16) % len(KEY_TONICS)]


# The band no longer describes itself in the prompt, and the reason is
# measured (SUMMARY §9.16, §9.20, §9.21).
#
# It used to carry one of four phrases about density and motion -- "at its
# stillest, almost nothing moving" through "at its most present and
# insistent". Three things were then found:
#
#   no ordering   no measure of movement climbs with the band, and the BPM
#                 number inside it has no relationship to what comes out
#                 (r = -0.066 against onset density over 32 beds)
#   not audible   played back to back, tense-0 through tense-3 have no
#                 noticeable gradient of intensity
#   actively bad  band 3's phrase drives the model into near-inaudible
#                 sub-bass: 63% of its takes fail the audibility guard, and
#                 it is 51% of the generation attempts for 37% of the beds
#
# The bands themselves stay, because they earn their keep somewhere else
# entirely: 65% of all cue changes are a band step within one mood, and
# without them a 77%-tense arc holds one cue for a quarter-hour at a time.
# They supply somewhere for the score to go. They were never describing
# intensity, so they have stopped claiming to.
#
# What makes four bands of a mood differ is now the seed -- see
# BAND_SEED_STRIDE. Takes of one cue measure as far apart as two different
# moods do, so that is a sounder basis for the difference than a phrase that
# was measured not to work.

# Bands of one mood share a prompt now, so they must not share a seed, for
# exactly the reason takes must not. Larger than any variant run
# (variant * attempts) can reach, so the two never collide.
BAND_SEED_STRIDE = 1000


def seed_base(seed: int, band, variant: int, attempts: int) -> int:
    """The first seed a take tries; its nth re-seed tries seed_base + n.

    Each take owns a disjoint run of `attempts` seeds, and each band its own
    stride (see BAND_SEED_STRIDE). One function because three places need it
    -- the run, --dry-run's printout and offload.py's job -- and the offload
    runner had drifted to a formula without the band in it.
    """
    return seed + (band or 0) * BAND_SEED_STRIDE + variant * attempts


def guard_rank(report: dict) -> tuple:
    """How good a take is by the audibility guard alone, lower is better: any
    usable take beats any unusable one, then nearest to 600 Hz -- the middle of
    where the beds that read as reasonable landed. It is what picks the
    least-bad take of a cue that never passes."""
    return (not report["usable"],
            abs(math.log((report["centroid_hz"] or 1) / 600)))


# What a band says about itself: nothing for "still", a height for "peak".
#
# This is the one prompt lever ever measured to move timbre. The record is
# SUMMARY 9.16-9.29 and the short form is:
#
#   adjectives about density and motion   no measurable ordering (9.16); the
#                                          one pair that separated did so by
#                                          reading "underneath" as register
#   BPM number                             inert (9.16)
#   instrument names                       inert -- "high violins and flutes"
#                                          gave 236 Hz where the phrase below
#                                          gave 1,382 Hz at the same seed (9.27)
#   a phrase about height                  the model answers it: +1,100 Hz in
#                                          centroid, passes the audibility
#                                          guard first time where band 3 used
#                                          to fail three in five (9.26)
#   middle wordings, four of them          indistinguishable from the default
#
# So two bands, and the peak one carries the phrase that worked, verbatim.
# It is heard as *louder* -- the same RMS, +4.8 dB A-weighted -- not as more
# intense (9.29). Intensity is movement, and movement is the seed's, not the
# prompt's: see --overgen.
BAND_REGISTER = [
    "",
    "voiced high and airy, violins and flutes near the top of their range",
]


# UNTESTED, off by default. --mood-constraint.
#
# The last sentence of every prompt says the same thing to every mood:
# "Sustained and quiet, no drums, no vocals, no melody, no build-up". For
# tense and ominous that is what is wanted. For two moods it is a
# contradiction, and SUMMARY 9.32 measured what the model does with it.
#
#   whimsical   asks for "pizzicato strings, light woodwind" -- pizzicato is
#               nothing but attacks -- and then forbids melody and asks for
#               sustain. What came out is bright (1,838 Hz) and static
#               (3.04 onsets/s, below the set's own mean): the brightness
#               arrived and the plucking did not.
#   romantic    asks for "warm strings, close piano" and then forbids melody.
#               A close piano with no melody is a pad, and what came out
#               measures 0.99 from calm-0 where the mean distance between two
#               cues of this set is 2.79. It did not come out wrong; it came
#               out absent.
#
# Heard on two different palettes, neither sounds romantic or whimsical.
#
# So the constraint becomes the mood's own. What every mood still gets told
# is the part that actually protects a bed under prose -- no drums, no
# vocals, no build-up, quiet -- and what changes is whether *movement* and
# *melodic motion* are forbidden, which is what these two moods are made of.
# Moods not listed here keep the general sentence, because for them it is
# right and it is measured (9.4).
MOOD_CONSTRAINT = {
    "whimsical":
        "Quiet and unhurried, a few light plucked notes with space around "
        "them, no drums, no vocals, no build-up -- background score that "
        "sits underneath someone reading.",
    "romantic":
        "Slow, warm and quiet, simple held harmony that moves gently, no "
        "drums, no vocals, no build-up -- background score that sits "
        "underneath someone reading.",
}


# MEASURED, and on by default for the moods listed. SUMMARY 9.33 and 9.34.
#
# Putting the mood ahead of the book's theme helps a mood whose own
# instrumentation names a register a small speaker can reproduce, and wrecks
# one whose does not. Romantic asks for "warm strings, close piano" and stands
# up on its own: reordered, both seeds beat all eight beds the old order made,
# 4.71 and 5.42 onsets/s against a best of 4.25. Tense asks for "pulsing low
# strings, percussive attacks", every word of it low, and the book's
# "Orchestral with a focus on brass and percussion" was the only thing in the
# prompt holding it up above 200 Hz. Demote that and tense falls through the
# floor: tense-1 failed the audibility guard on 8 of 8 attempts against 6 of
# 32 for the old order (Fisher p = 0.00004), and on the two seeds both runs
# share the energy above 200 Hz went 96.4% -> 2.1% and 91.6% -> 7.1%.
#
# So this is per mood and not a switch. A mood belongs here when its own
# instrumentation clause would survive being the whole prompt.
#
# Whimsical is absent on purpose: reordered it measured inside the range the
# old order already produces, so there is no evidence either way (9.33).
MOOD_FIRST = {"romantic"}


def prompt_for(
    mood: str,
    theme: dict,
    register_hint: bool = False,
    positive_only: bool = False,
    band: int | None = None,
    with_key: bool = True,
    mood_constraint: bool = False,
    mood_first: bool = False,
    book_first: bool = False,
) -> str:
    """The text handed to the model for one mood of one book.

    Ordered widest-to-narrowest -- genre, then the book, then the instruments,
    then the mood, then the constraints -- because the model weights the front
    of the prompt most heavily and the genre is the thing that has to differ
    between books.

    That second half is wrong and 9.34 measured how. If the front carries the
    most weight then the front should hold what differs between the *cues of
    one book*, because a book's genre is in every one of its beds either way.
    But reordering is not free: the book's theme is also what keeps a
    low-register mood audible, so it helps some moods and wrecks others. See
    MOOD_FIRST, which names the ones it helps.

    The last sentence is doing as much work as the rest. Left alone, a music
    model writes *music*: a tune, a beat, an arrival. All three are wrong under
    prose. make_loops.py put it well -- music under reading has to survive
    being ignored, because melody competes with the reader's inner voice.
    """
    params = MOOD_PARAMS[mood]
    low, high = params["bpm"]
    # A banded bed sits where its band does inside the mood's own tempo range,
    # so the four are a run from the slowest reading of the mood to the
    # fastest rather than four takes of its middle.
    if band is None:
        bpm = (low + high) // 2
    else:
        bpm = round(low + (high - low) * band / (len(BAND_NAMES) - 1))

    # The register hint is OFF by default because it was measured and it made
    # things worse. Asked for Dracula's 'ominous' bed:
    #
    #   no hint,   seed 0    0.3% above 200 Hz   inaudible
    #   no hint,   seed 1   99.7%                fine
    #   with hint, seed 0    4.9%                inaudible
    #   with hint, seed 1    0.3%                inaudible
    #
    # Two things followed. Across those four the variance was dominated by the
    # seed rather than the wording -- though see below, where it was not. And
    # MusicGen has no negative prompting, so "no sub-bass" is a conditioning
    # signal *for* sub-bass, not against it, which is why the flag exists at
    # all and why [positive_only] was worth trying on the rest of the
    # negations too.
    register = (
        " Keep it in the middle register, where small speakers can reproduce "
        "it; no sub-bass."
        if register_hint else ""
    )
    # [positive_only] was the untested half of that idea. It is tested now.
    # The test book's 'ominous' bed, same model, same theme:
    #
    #   negated,       seed 0    9.7% above 200 Hz   centroid   99 Hz  rejected
    #   negated,       seed 1    0.7%                           94 Hz  rejected
    #   negated,       seed 2    0.3%                          108 Hz  rejected
    #   negated,       seed 3    6.6%                           84 Hz  rejected
    #   positive-only, seed 0   59.2%                          349 Hz  PASSED
    #
    # Read it carefully: one cue of one book is not proof that positive
    # phrasing is better everywhere, and the seed match does not make it a
    # paired trial -- conditioning steers every step, so the two runs diverge
    # immediately whatever the RNG does. What makes it more than luck is the
    # *shape* of the failures. Four seeds clustered inside 84-108 Hz is not
    # variance around a passing mean, it is one consistent failure mode; and
    # the seed that had already failed is the one that passed once the
    # negations went.
    #
    # The likely mechanism, offered as a reading rather than a result: "no
    # drums, no vocals, no melody, no build-up" names only what to take away,
    # and for a dark mood that leaves nothing to put in the midrange, so the
    # model writes a sub-bass drone that measures as silence. "A single held
    # texture" says what to put there instead.
    constraint = (
        "Sustained, quiet and static, a single held texture -- background "
        "score that sits underneath someone reading."
        if positive_only else
        "Sustained and quiet, no drums, no vocals, no melody, no build-up -- "
        "background score that sits underneath someone reading."
    )
    if mood_constraint and mood in MOOD_CONSTRAINT:
        constraint = MOOD_CONSTRAINT[mood]
    # 'calm' maps to the music mood 'ambient', and "ambient ambient underscore"
    # is the kind of thing a model happily takes literally.
    shape = params["music_mood"]
    if shape != "ambient":
        shape = f"{shape} ambient"
    # In the slot the old band adjectives had, and for the same reason: it
    # sits next to the instrumentation, which is what it is talking about.
    height = (f" {BAND_REGISTER[band]};"
              if band is not None and BAND_REGISTER[band] else "")
    texture = params["texture"]
    # [with_key] exists to be turned off, so that naming a key can be measured
    # rather than assumed to be free. Same reason --register-hint exists, and
    # that one was measured and made things worse.
    key = (f" in {tonic_for(theme)} {MOOD_MODE.get(mood, 'minor')}"
           if with_key else "")
    book = (f"{theme['genre_seed']}. {theme['overall_theme']}. "
            f"{theme['instrumentation']};{height} {texture}. ")
    mood_clause = f"Slow {shape} underscore{key}, around {bpm} BPM. "
    # The front of every prompt for this book is "action-drama. Drama and
    # Action. Orchestral with a focus on brass and percussion for action
    # scenes...", so a romantic bed was arriving as an action bed that happens
    # to have warm strings. This puts the mood first and the book second for
    # the moods where that was measured to help, and [mood_first] /
    # [book_first] force it either way for a trial.
    if mood_first or (mood in MOOD_FIRST and not book_first):
        # The texture belongs with the mood, not with the book, once the
        # order is reversed -- it is the mood's own instrumentation.
        book = (f"{theme['genre_seed']}. {theme['overall_theme']}. "
                f"{theme['instrumentation']}. ")
        mood_clause = (f"Slow {shape} underscore{key}, around {bpm} BPM;"
                       f"{height} {texture}. ")
        return f"{mood_clause}{book}{constraint}{register}"
    return f"{book}{mood_clause}{constraint}{register}"


def cues_for(moods: list[str], palette: str) -> list[tuple[str, int | None]]:
    """Every (mood, band) this palette asks for, in a stable order."""
    if palette == "moods":
        return [(mood, None) for mood in moods]
    return [(mood, band) for mood in moods for band in range(len(BAND_NAMES))]


def cue_name(mood: str, band: int | None) -> str:
    """The key the app will look this bed up by. Matches lib/palette.dart."""
    return mood if band is None else f"{mood}-{band}"


def allocation_for(allocation: dict, arc) -> dict[str, int]:
    """One set's cue -> bed count: an arc's, or the whole book's."""
    if not allocation:
        return {}
    if arc is None:
        return dict(allocation.get("whole", {}).get("allocation", {}))
    for entry in allocation.get("sets", []):
        if entry.get("palette") == arc:
            return dict(entry.get("allocation", {}))
    return {}


def split_cue(cue: str) -> tuple[str, int | None]:
    """A cue key back into the mood and band it was built from."""
    mood, _, tail = cue.rpartition("-")
    if mood and tail.isdigit():
        return mood, int(tail)
    return cue, None


def slots_for(moods: list[str], palette: str, plan: dict[str, int],
              overgen: int = 1) -> list[dict]:
    """Every bed to make: its file stem, the cue it serves, and which take.

    With no plan this is the old cartesian product -- every mood at every band,
    one bed each -- so a book that has never been sampled generates exactly what
    it always did.

    With one, it is what the book was measured to need: cues in proportion to
    how much of the arc they cover, and the busiest of them as several takes of
    one prompt rather than one file the reader hears for twenty minutes. See
    lib/allocation.dart.

    Variant 0 keeps the cue's own name, so nothing on disk has to be renamed and
    a set generated before any of this reads as one variant of each cue.

    [overgen] makes that many times as many takes as the plan asks for, and
    `keep` on each slot is how many survive: the stillest for band 0, the
    busiest for band 1, ranked by measured movement once they exist (see
    --overgen). The surviving takes are renumbered on disk, so a finished set
    looks exactly like one that was generated at the plan's own counts.
    """
    overgen = max(1, overgen)
    if not plan:
        return [{"stem": (cue_name(mood, band) if v == 0
                          else f"{cue_name(mood, band)}-v{v}"),
                 "cue": cue_name(mood, band),
                 "mood": mood, "band": band, "variant": v, "keep": 1}
                for mood, band in cues_for(moods, palette)
                for v in range(overgen)]
    slots = []
    for cue in sorted(plan):
        mood, band = split_cue(cue)
        if mood not in moods:
            continue
        keep = max(0, plan[cue])
        for variant in range(keep * overgen):
            slots.append({
                "stem": cue if variant == 0 else f"{cue}-v{variant}",
                "cue": cue, "mood": mood, "band": band, "variant": variant,
                "keep": keep,
            })
    return slots
