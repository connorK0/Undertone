"""Generate a book's own set of mood beds with a local music model.

    phase1/.venv/Scripts/python.exe phase1/tool/generate_beds.py --list
    phase1/.venv/Scripts/python.exe phase1/tool/generate_beds.py --book dracula_ch1 --dry-run
    phase1/.venv/Scripts/python.exe phase1/tool/generate_beds.py --book dracula_ch1 --moods ominous

Why this exists
---------------
Every book currently plays the same eight files. *Dracula* and *Alice in
Wonderland* are byte-identical on disk, which is as literal as "it all sounds
the same" gets. The theme pass already works out that one is "Horror" and the
other "Children's Fantasy", and computes an instrumentation line for each --
and nothing consumes any of it, because a fixed loop library cannot re-voice
itself per book.

So the prompt for each bed is not invented here. It is assembled from what
phase0/mapper.py already emits for that book: its genre seed, its
instrumentation, and the mood's own tempo range and texture. That module is
imported rather than copied, because the Dart port of it is pinned to it by a
parity test and a second transcription would be a third thing to keep in step.

What comes out of the model is not a bed. It is a clip that starts and ends
wherever it likes, at whatever loudness it likes, with no guarantee that any of
its energy is where a laptop speaker can reproduce it. tool/loopify.py is what
turns it into one, and it applies exactly the checks the synthesised beds are
held to.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sqlite3
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "phase0"))

from mapper import MOOD_PARAMS  # noqa: E402  read-only import of phase0

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loopify  # noqa: E402
import bench_palette  # noqa: E402  the movement measure SUMMARY 9.29 sorted by

# Themes the app has already worked out, so a run uses a real book's real
# description rather than something written to flatter the model.
#
# The app's own cache comes first: books are imported there, and `dart run
# tool/theme.dart <bookId>` is what fills it in for one that has not been
# opened yet. The tool database is the fallback, and is what the bundled
# sample chapters were generated from.
APP_SUPPORT = (Path.home() / "AppData" / "Roaming" / "com.example"
               / "reader_shell")
THEME_DBS = [
    APP_SUPPORT / "mood_cache.db",
    (ROOT / "phase1" / ".dart_tool" / "sqflite_common_ffi" / "databases"
     / "build" / "cue_timeline.db"),
]

# Stereo out of the box, and small enough to share an 8 GB card with Ollama.
# The medium model is better and needs the GPU to itself; see --model.
DEFAULT_MODEL = "facebook/musicgen-stereo-small"

# MusicGen emits 50 tokens per second of audio and was trained on 30-second
# spans, so this is its useful ceiling. loopify needs 24s of loop plus a 2s
# crossfade tail, and the rest is slack for it to choose a steady region from.
SECONDS = 30
TOKENS_PER_SECOND = 50

# The intensity bands, in the same order and at the same edges as
# lib/palette.dart. Two of them, from SUMMARY 9.24-9.29: there were four, and
# the prompt can reach exactly two registers (dark by default, bright on a
# height phrase), so four names were three crossfades in four that changed
# nothing. The edge was 0.65, measured in 9.30 for how often it makes the
# score move; it is 0.75 since 9.43, where the reworded classifier's tags put
# a third of the book over 0.65.
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


def book_id_of(key: str) -> tuple[str, bool]:
    """The book id inside a theme key, and whether the key was a current one.

    Theme keys carry a hash of the sample they were computed from --
    "<bookId>-<10 hex>" -- so that a theme cannot outlive the text it
    describes. Splitting on the first dash is wrong: the bundled books are
    called things like "sample-alice_ch1", and that turns every one of them
    into a book called "sample". Only a trailing hash is stripped.

    Keys with no hash predate that rule. The app can no longer look them up,
    so they are stale by construction -- kept only as a fallback for a book
    that has nothing newer.
    """
    head, _, tail = key.rpartition("-")
    if head and len(tail) == 10 and all(c in "0123456789abcdef" for c in tail):
        return head, True
    return key, False


def themes() -> dict[str, dict]:
    """Every book theme cached anywhere, keyed by book id."""
    found: dict[str, dict] = {}
    for path in THEME_DBS:
        if not path.exists():
            continue
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = db.execute(
                "select book_key, overall_theme, instrumentation, genre_seed, "
                "theme_id from themes"
            ).fetchall()
        except sqlite3.DatabaseError:
            continue
        finally:
            db.close()
        for key, overall, instrumentation, genre, theme_id in rows:
            book, current = book_id_of(key)
            # A current key always beats a stale one, whichever order they came
            # back in; otherwise the first database seen wins, and the app's
            # own cache is looked at first.
            if book in found and not (current and not found[book]["current"]):
                continue
            found[book] = {
                "book_key": key,
                "current": current,
                "overall_theme": overall,
                "instrumentation": instrumentation,
                "genre_seed": genre,
                "theme_id": theme_id,
            }
    return found


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


def load_model(model_name: str, guidance: float = 3.0):
    """Load the model once. Returns (generate_one, sample_rate).

    Loading costs about 50 seconds cold and 8 warm, so it must happen once per
    run rather than once per bed -- a book needs at least eight generations and
    usually more, because of the retry loop below.

    [guidance] is classifier-free guidance, and it is a quality knob that
    happens to also be a speed knob. Measured on this 4060 at 30 s clips
    (tool/bench_batch.py):

        guidance 3.0, batch 1   131.5 s/clip   6.03 GiB
        guidance 1.0, batch 1   111.0 s/clip   5.51 GiB
        guidance 1.0, batch 2    58.1 s/clip   6.95 GiB

    Note how little the first two differ. CFG runs a conditional and an
    unconditional pass, so it "doubles the work" -- and buys only 1.18x when
    removed, because the decode loop is bandwidth-bound and the second sequence
    rides along on the same weight reads. What dropping it really buys is
    *memory*, which is what lets the batch grow.

    Which is why the default stays at 3.0. The speed is in the batch, and
    guidance is the setting that decides whether the model listens to the
    prompt at all -- on a project whose recurring failure is the model handing
    back an inaudible sub-bass drone when it is not steered hard enough.
    """
    import torch
    from transformers import AutoProcessor, MusicgenForConditionalGeneration

    device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cpu":
        print("!  no CUDA device; this will be extremely slow", file=sys.stderr)
    print(f"loading {model_name} on {device}...")
    started = time.time()
    processor = AutoProcessor.from_pretrained(model_name)
    model = MusicgenForConditionalGeneration.from_pretrained(
        model_name,
        dtype=torch.float16 if device == "cuda" else torch.float32,
    ).to(device)
    print(f"loaded in {time.time() - started:.1f}s")

    def generate_many(prompts: list[str], seed: int):
        """Several beds in one decode loop.

        Worth doing because the loop is bandwidth-bound: each of the 1,500
        steps reads 1.5B parameters out of VRAM to do very little arithmetic,
        so extra sequences ride along on the same reads. Measured at 30 s,
        guidance 3.0: 131.5 s/clip at batch 1, 75.0 s/clip at batch 2.

        The catch is VRAM, and on an 8 GB card it is a hard one -- batch 2 at
        guidance 3.0 peaks at 9.8 GiB and only survives because Windows spills
        into system RAM; batch 4 dies outright.

        One consequence to be honest about: **the same seed gives different
        audio at a different batch size**, because the sequences share a
        generator. A batched run is a different sample, not a faster route to
        the same one. The audibility guard still holds, so quality is still
        enforced -- but a bed cannot be reproduced without knowing the batch
        it was made in, which is why the manifest records it.
        """
        torch.manual_seed(seed)
        inputs = processor(text=prompts, padding=True,
                           return_tensors="pt").to(device)
        with torch.no_grad():
            audio = model.generate(
                **inputs,
                do_sample=True,
                guidance_scale=guidance,
                max_new_tokens=SECONDS * TOKENS_PER_SECOND,
            )
        # (batch, channels, samples) -> (samples, channels) each, which is what
        # soundfile and loopify both want.
        return [audio[i].to(torch.float32).cpu().numpy().T
                for i in range(audio.shape[0])]

    return generate_many, model.config.audio_encoder.sampling_rate


def load_arcs(book: str) -> list[dict]:
    """Where the storyline turns, as tool/theme.dart --arcs wrote it.

    Read rather than re-derived. chooseArcs lives in Dart because the app has
    to agree with it exactly, and a second implementation here would be the
    parity bug that Library.themeSample already taught us to avoid.
    """
    path = APP_SUPPORT / "generated" / book / "arcs.json"
    if not path.exists():
        return []
    return json.loads(path.read_text(encoding="utf-8")).get("arcs", [])


def arcs_on_disk(root: Path) -> int:
    """How many arcs of this book have beds, counting from 0.

    palette.json says how far the app may look, and it is rewritten by every
    run -- including a run that generates one arc. Counting the directories
    rather than the arcs in *this* run is what stops `--arc 3` from declaring
    the book to have one arc and clamping the reader back to arc 0.
    """
    highest = -1
    for child in root.glob("arc-*"):
        if (child / "manifest.json").exists():
            try:
                highest = max(highest, int(child.name.split("-")[1]))
            except (IndexError, ValueError):
                continue
    return highest + 1


def cues_for(moods: list[str], palette: str) -> list[tuple[str, int | None]]:
    """Every (mood, band) this palette asks for, in a stable order."""
    if palette == "moods":
        return [(mood, None) for mood in moods]
    return [(mood, band) for mood in moods for band in range(len(BAND_NAMES))]


def cue_name(mood: str, band: int | None) -> str:
    """The key the app will look this bed up by. Matches lib/palette.dart."""
    return mood if band is None else f"{mood}-{band}"


def load_allocation(book: str) -> dict:
    """What tool/allocate.dart measured for this book, or {} if it never ran."""
    path = APP_SUPPORT / "generated" / book / "allocation.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


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


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate per-book mood beds.")
    parser.add_argument("--book", help="book id, e.g. dracula_ch1")
    parser.add_argument("--moods", nargs="*", default=sorted(MOOD_PARAMS),
                        help="which moods to generate (default: all eight)")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--seed", type=int, default=0,
                        help="same seed and prompt gives the same bed")
    parser.add_argument("--out", type=Path,
                        help="output directory (default build/generated/<book>)")
    parser.add_argument("--install", metavar="BOOK_ID",
                        help="write straight into the app's support directory "
                             "as this book id, so the running app can play it. "
                             "The app's ids are not the tool's: a seeded "
                             "chapter is 'sample-dracula_ch1', not "
                             "'dracula_ch1'.")
    parser.add_argument("--list", action="store_true",
                        help="show the books with a cached theme, and stop")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the prompts without loading the model")
    parser.add_argument("--register-hint", action="store_true",
                        help="add a 'middle register, no sub-bass' line. Off "
                             "by default: measured, and it made things worse")
    parser.add_argument("--positive-only", action="store_true",
                        help="phrase the constraint without negations, since "
                             "MusicGen has no negative prompting")
    parser.add_argument("--mood-constraint", action="store_true",
                        help="let a mood override the final sentence, so that "
                             "whimsical may pluck and romantic may move. Off "
                             "by default: measured, and it was no better than "
                             "the contradiction it fixes (SUMMARY 9.33)")
    parser.add_argument("--mood-first", action="store_true",
                        help="put the mood ahead of the book's theme for "
                             "EVERY mood. MOOD_FIRST already does it for the "
                             "moods it was measured to help, so this is for "
                             "trials (SUMMARY 9.34)")
    parser.add_argument("--book-first", action="store_true",
                        help="keep the book's theme first for every mood, "
                             "ignoring MOOD_FIRST. This is what arc-000's "
                             "beds on disk were made with (SUMMARY 9.34)")
    parser.add_argument("--overgen", type=int, default=2, metavar="N",
                        help="generate N takes for every one the plan asks "
                             "for, and keep the stillest (band 0) or busiest "
                             "(band 1) by measured movement. 2 is what "
                             "SUMMARY 9.29 measured: the middle of the "
                             "movement distribution is the part nobody can "
                             "hear a difference in. 1 disables it. It is "
                             "also the register gate's headroom: a band "
                             "with too few takes on its side of the line "
                             "keeps the nearest ones outside it")
    parser.add_argument("--no-register-gate", action="store_true",
                        help="cull on movement alone, without first ranking "
                             "each take behind the others when its "
                             "brightness is on the wrong side of the line "
                             "between its mood's bands. This is what "
                             "arc-000's beds on disk were culled with "
                             "(SUMMARY 9.35, 9.36)")
    parser.add_argument("--uniform", action="store_true",
                        help="ignore allocation.json and make one bed per cue, "
                             "which is what every set generated before "
                             "tool/allocate.dart existed is")
    parser.add_argument("--palette", choices=["moods", "full"], default="moods",
                        help="'moods' is one bed per mood (8). 'full' is one "
                             "per mood and intensity band (32) -- four times "
                             "the GPU time, and the axis measured to move "
                             "within a held mood")
    parser.add_argument("--per-arc", action="store_true",
                        help="a separate set per story arc, each from that "
                             "arc's own theme, with boundaries where the "
                             "storyline turns. Needs the arcs themed first: "
                             "dart run tool/theme.dart <id> --arcs")
    parser.add_argument("--arc", type=int, default=None, metavar="N",
                        help="generate only arc N. This is the just-in-time "
                             "workflow: read arc N while arc N+1 generates")
    parser.add_argument("--next", action="store_true",
                        help="generate the lowest-numbered themed arc that has "
                             "no beds yet, and stop. Run it again after each "
                             "arc; it is the whole just-in-time loop")
    parser.add_argument("--arcs", type=int, default=0, metavar="N",
                        help="stop after N arcs, for a run that has to fit in "
                             "the time available")
    parser.add_argument("--batch", type=int, default=1, metavar="N",
                        help="generate N beds per call. 2 is about 1.75x the "
                             "throughput of 1 on an 8 GB card, and 4 runs out "
                             "of memory there. Defaults to 1 because a batched "
                             "run is a different sample from a sequential one "
                             "at the same seed, not a faster route to the same "
                             "audio")
    parser.add_argument("--no-key", action="store_true",
                        help="leave the key out of the prompt, to measure "
                             "what naming one costs or buys")
    parser.add_argument("--guidance", type=float, default=3.0,
                        help="classifier-free guidance. 3.0 is the default and "
                             "the measured one; 1.0 is faster and much lighter "
                             "on VRAM, but weakens how much the prompt steers "
                             "the model, which is this project's known failure "
                             "mode. Change it with the audibility guard "
                             "watching")
    parser.add_argument("--attempts", type=int, default=4,
                        help="re-seed this many times before giving up on the "
                             "audibility guard (default 4)")
    args = parser.parse_args()

    known = themes()
    if args.list:
        if not known:
            print("no cached themes; run "
                  "`dart run tool/theme.dart <bookId>` first")
            return
        for book, theme in sorted(known.items()):
            print(f"{book:32s} {theme['genre_seed']:22s} "
                  f"{theme['overall_theme']}")
            print(f"{'':32s} {theme['instrumentation'][:90]}")
            if not theme["current"]:
                print(f"{'':32s} !  no current theme; run "
                      f"`dart run tool/theme.dart {book}`")
        return

    if not args.book:
        parser.error("--book is required (see --list)")
    if args.book not in known:
        parser.error(f"no cached theme for {args.book!r}; see --list")

    palette = args.palette
    cues = cues_for(list(args.moods), palette)
    # Measured beds per cue, if this book has been sampled. --uniform is the way
    # back to one bed per cue, which is what every set on disk today is.
    allocation = {} if args.uniform else load_allocation(args.book)

    # Which sets to make. A whole-book run is one set; an arc run is one per
    # story arc, each from that arc's own theme.
    boundaries = load_arcs(args.book)
    # --next belongs here too. Leaving it out sent a --next run down the
    # whole-book path and started generating eight beds nobody asked for --
    # which on a single 8 GB card also means fighting whatever else is
    # generating. Caught by running it.
    if args.per_arc or args.arc is not None or getattr(args, 'next'):
        if not boundaries:
            parser.error(
                f"no arc boundaries for {args.book}; run "
                f"`dart run tool/arcs.dart {args.book} --scan` then "
                f"`dart run tool/theme.dart {args.book} --arcs` first")
        # Only the arcs that represent a set. tool/theme.dart groups arcs
        # whose themes are near-identical and points the others at the first
        # of the group, so an arc with palette != index has nothing of its own
        # to generate -- it plays another arc's beds.
        themed = [a["index"] for a in boundaries
                  if a.get("palette", a["index"]) == a["index"]
                  and f"{args.book}#arc{a['index']}" in known]
        shared = len(boundaries) - len(
            {a.get("palette", a["index"]) for a in boundaries})
        if shared:
            print(f"{shared} arc(s) share another arc's beds, "
                  f"{len(themed)} set(s) to make")
        if getattr(args, "next"):
            root_now = ((APP_SUPPORT / "generated" / args.install).resolve()
                        if args.install
                        else (args.out or (ROOT / "phase1" / "build"
                                           / "generated" / args.book)).resolve())
            pending = [i for i in themed
                       if not (root_now / f"arc-{i:03d}"
                               / "manifest.json").exists()]
            if not pending:
                print(f"every themed arc of {args.book} already has beds "
                      f"({len(themed)} arc(s)). Scan and theme further ahead: "
                      f"dart run tool/arcs.dart {args.book} --scan")
                return
            args.arc = pending[0]
        if args.arc is not None:
            if args.arc not in themed:
                parser.error(
                    f"arc {args.arc} has no theme; "
                    f"themed arcs are {themed or 'none'}")
            arcs = [args.arc]
        else:
            arcs = themed[:args.arcs] if args.arcs else themed
        if not arcs:
            parser.error(
                f"no arc themes for {args.book}; run "
                f"`dart run tool/theme.dart {args.book} --arcs` first")
    else:
        arcs = [None]

    if args.install:
        root = (APP_SUPPORT / "generated" / args.install).resolve()
    else:
        root = (args.out or (ROOT / "phase1" / "build" / "generated"
                             / args.book)).resolve()

    # About 3.4 minutes a bed measured on a 4060 at medium, counting the
    # re-seeds the audibility guard asks for. Printed up front because the four
    # options differ by an order of magnitude and the choice between them is
    # "how long have I got".
    per_set = {arc: slots_for(list(args.moods), palette,
                              allocation_for(allocation, arc),
                              overgen=args.overgen)
               for arc in arcs}
    total = sum(len(v) for v in per_set.values())
    kept = sum(1 for v in per_set.values()
               for s_ in v if s_["variant"] < s_["keep"])
    if allocation:
        shapes = {arc: len({s["cue"] for s in slots})
                  for arc, slots in per_set.items()}
        print(f"{args.book}: allocated palette, {kept} bed(s) kept of "
              f"{total} generated over {len(arcs)} set(s), "
              f"{min(shapes.values())}-{max(shapes.values())} cue(s) each")
    else:
        print(f"{args.book}: {palette} palette, "
              f"{len(cues)} cue(s) x {len(arcs)} set(s) = {kept} beds, "
              f"{total} generated")
    # Measured, not estimated: a 30 s stereo bed is 2.1 MB and the raw take
    # kept beside it is 3.8 MB, which is 46 MB for the eight-bed set on disk.
    # Both are counted -- quoting only the beds understated a per-arc run by
    # nearly 3x, and the size of a per-arc run is the whole reason anyone
    # reads this line.
    # 3.4 minutes a bed measured at batch 1; batch 2 measured at 75.0 s/clip
    # against 131.5, so it scales by the ratio rather than by the batch size.
    per_bed = 3.4 * (75.0 / 131.5 if args.batch >= 2 else 1.0)
    print(f"about {total * per_bed / 60:.1f} h at medium, "
          f"{total * 5.9 / 1024:.2f} GB on disk "
          f"({total * 2.1:.0f} MB of beds, {total * 3.8:.0f} MB of raw takes, "
          f"which are diagnostic and can be deleted)\n")

    spans = {a["index"]: a for a in boundaries}
    for arc in arcs:
        theme = known[args.book if arc is None else f"{args.book}#arc{arc}"]
        if arc is None:
            where = "whole book"
        else:
            span = spans.get(arc)
            where = (f"arc {arc}" if span is None else
                     f"arc {arc} (ch {span['start'] + 1}-{span['end'] + 1}"
                     f", {span['end'] - span['start'] + 1} ch)")
        print(f"  {where}: {theme['genre_seed']} / {theme['overall_theme']}")
        if arc is not None and spans.get(arc, {}).get("title"):
            print(f"    {spans[arc]['title']}")
    print()

    if args.dry_run:
        first_key = (args.book if arcs[0] is None
                     else f"{args.book}#arc{arcs[0]}")
        first = known[first_key]
        # Same line as the generation loop below, and it has to be here too:
        # tonic_for() falls back to the theme *text* without it, which is a
        # different tonic from the one a real run uses.
        first["key_seed"] = first_key
        for slot in per_set[arcs[0]]:
            takes = sum(1 for s in per_set[arcs[0]] if s["cue"] == slot["cue"])
            if slot["variant"]:
                print(f"  [{slot['stem']}]  take {slot['variant'] + 1} of "
                      f"{takes} generated, {slot['keep']} kept, same prompt, "
                      f"seed "
                      f"{seed_base(args.seed, slot['band'], slot['variant'],
                                   args.attempts)}")
                continue
            print(f"  [{slot['stem']}]"
                  + (f"  1 of {takes} takes" if takes > 1 else ""))
            print("  " + prompt_for(
                slot["mood"], first,
                register_hint=args.register_hint,
                positive_only=args.positive_only,
                band=slot["band"],
                with_key=not args.no_key,
                mood_constraint=args.mood_constraint,
                mood_first=args.mood_first,
                book_first=args.book_first,
            ) + "\n")
        return

    # A run's log has to say which order it used, or a set on disk cannot be
    # told apart from one made before 9.34 -- and the same for the register
    # gate and 9.35.
    if args.mood_first:
        order = "mood first for every mood"
    elif args.book_first:
        order = "book first for every mood"
    else:
        order = "mood first for " + ", ".join(sorted(MOOD_FIRST))
    print(f"seed {args.seed}, up to {args.attempts} attempt(s) per bed, "
          f"register hint {'on' if args.register_hint else 'off'}, "
          f"{'positive-only' if args.positive_only else 'negated'} phrasing, "
          f"{order}, overgen {args.overgen}, register gate "
          f"{'off' if args.no_register_gate else 'on'}\n")

    generate_many, rate = load_model(args.model, args.guidance)

    unusable = []
    for arc in arcs:
        key = args.book if arc is None else f"{args.book}#arc{arc}"
        theme = known[key]
        # Which set this is, so its tonal centre is its own rather than shared
        # with every other arc whose theme came back worded the same way.
        theme["key_seed"] = key
        out = root if arc is None else root / f"arc-{arc:03d}"
        out.mkdir(parents=True, exist_ok=True)
        if arc is not None:
            print(f"\n== arc {arc}: {theme['genre_seed']} / "
                  f"{theme['overall_theme']}", flush=True)

        # Generate, measure, reject, re-seed. This -- not prompt wording --
        # is what makes the output reliable: the register hint was measured
        # and made things worse, while re-seeding turned a failing Dracula bed
        # into a passing one. The guard is cheap and the model is stochastic,
        # so rejection sampling is the honest mechanism.
        #
        # Run in waves rather than cue by cue: every cue tries seed 0, then
        # whatever still fails tries seed 1, and so on. Per cue that is exactly
        # the old order -- seeds in sequence, stopping at the first pass -- but
        # it groups the work so several beds can go through one decode loop,
        # which is where the speed is (see load_model).
        wanted = {}
        for slot in per_set[arc]:
            wanted[slot["stem"]] = dict(slot, prompt=prompt_for(
                slot["mood"], theme,
                register_hint=args.register_hint,
                positive_only=args.positive_only,
                band=slot["band"],
                with_key=not args.no_key,
                mood_constraint=args.mood_constraint,
                mood_first=args.mood_first,
                book_first=args.book_first,
            ))

        best = {}
        pending = list(wanted)
        for attempt in range(args.attempts):
            if not pending:
                break
            # Takes of one cue share a prompt, so they must not share a seed --
            # that is how you generate the same file twice and congratulate
            # yourself on the variety. Each take owns a disjoint run of seeds,
            # `attempts` long, so re-seeding a rejected bed can never collide
            # with another take of the same cue either.
            #
            # Bands are grouped with them, and for the same reason. Since the
            # band stopped describing itself in the prompt, two bands of one
            # mood differ only by a BPM number that was measured inert -- so
            # sharing a seed across them would have produced four copies of
            # one bed, and turned the 65% of cue changes that are band steps
            # into 65% of changes that change nothing.
            groups = sorted({(wanted[c]["variant"], wanted[c]["band"] or 0)
                             for c in pending})
            for variant, band in groups:
                group = [c for c in pending
                         if wanted[c]["variant"] == variant
                         and (wanted[c]["band"] or 0) == band]
                seed = seed_base(args.seed, band, variant,
                                 args.attempts) + attempt
                for at in range(0, len(group), max(1, args.batch)):
                    chunk = group[at:at + max(1, args.batch)]
                    started = time.time()
                    clips = generate_many(
                        [wanted[c]["prompt"] for c in chunk], seed)
                    each = (time.time() - started) / len(chunk)
                    for cue, clip in zip(chunk, clips):
                        loop, report = loopify.process(clip, rate)
                        report["seed"] = seed
                        report["attempt"] = attempt + 1
                        report["batch"] = len(chunk)
                        why = ("" if report["usable"]
                               else "   rejected: too quiet to hear"
                               if not report["audible"]
                               else "   rejected: no body, all top end")
                        # flush: a run takes ten minutes or many hours, and
                        # redirected stdout is block-buffered, so without this
                        # the progress of a long run is invisible until it ends.
                        print(f"  {cue:16s} seed {seed}  "
                              f"{each:5.1f}s  seam "
                              f"{report['seam_ratio']:.3f}  "
                              f"{100 * report['energy_above_200hz']:5.1f}% "
                              f"above 200 Hz"
                              f"  centroid {report['centroid_hz']:6.0f} Hz{why}",
                              flush=True)
                        # Keep the nearest miss, so a cue that never passes
                        # still gets the least-bad take rather than whichever
                        # came last.
                        rank = guard_rank(report)
                        if cue not in best or rank < best[cue][0]:
                            best[cue] = (rank, clip, loop, report)
                        # Write it now rather than after the last wave. Cue by
                        # cue, the old loop had each bed on disk as soon as it
                        # passed, and grouping the work must not quietly turn a
                        # run that can be interrupted into one that has to
                        # finish to leave anything behind.
                        if report["usable"]:
                            write_bed(out, cue, clip, loop, rate)
            pending = [c for c in pending if not best[c][3]["usable"]]

        # Keep the takes whose *movement* suits the band, and drop the rest.
        #
        # 9.29: movement is heard as intensity, and the prompt cannot
        # ask for it -- no measure of movement ever climbed with the band
        # (9.16) -- but the seed produces it for free, with a 2.7x spread in
        # onsets across one cue's takes. Sorting the pre-D set's 24 tense
        # beds and keeping the 6 stillest against the 6 busiest gave the
        # contrast the reader had just called "definitely more intense";
        # keeping 12 against 12 did not. The middle is the part nobody can
        # hear, so it is the part that goes.
        #
        # 9.35: and brightness first. A take whose register belongs to the
        # other band ranks behind the rest however it moves, because the
        # prompt asks for a register and cannot enforce it take by take.
        wanted = cull_by_movement(out, wanted, best,
                                  register_gate=not args.no_register_gate)

        entries = []
        for stem, slot in wanted.items():
            mood, band, prompt = slot["mood"], slot["band"], slot["prompt"]
            cue = stem
            _, clip, loop, report = best[stem]
            # Cues that never passed have not been written yet, and the
            # least-bad take is still better than a missing file.
            if not report["usable"]:
                write_bed(out, cue, clip, loop, rate)
            entries.append({
                "cue": slot["cue"],
                "variant": slot["variant"],
                "mood": mood,
                "band": band,
                "band_name": None if band is None else BAND_NAMES[band],
                "file": f"{stem}.wav",
                "description": prompt,
                "model": args.model,
                "guidance": args.guidance,
                "key": f"{tonic_for(theme)} {MOOD_MODE.get(mood, 'minor')}",
                "source": "generated by phase1/tool/generate_beds.py",
                "license": "see the model card for " + args.model,
                "attribution": None,
                **report,
            })
            if not report["usable"]:
                unusable.append(f"{where_of(arc)}/{cue}")

        # The guard against the failure this whole change exists to fix: two
        # takes of one cue that are the same bytes are not two beds. Cheap, and
        # the one check that would have caught tool/bench_melody.py's first
        # result before it was believed.
        for cue in {s["cue"] for s in per_set[arc]}:
            takes = [s["stem"] for s in per_set[arc] if s["cue"] == cue]
            if len(takes) < 2:
                continue
            digests = {}
            for stem in takes:
                path = out / f"{stem}.wav"
                if path.exists():
                    digests.setdefault(
                        hashlib.sha256(path.read_bytes()).hexdigest(),
                        []).append(stem)
            same = [names for names in digests.values() if len(names) > 1]
            if same:
                print(f"  !  {cue}: identical takes "
                      + "; ".join(", ".join(n) for n in same), flush=True)

        # Merge rather than replace. Re-running one cue -- which is the whole
        # workflow when a single bed fails the audibility guard four times --
        # would otherwise write a manifest containing only that cue, and the
        # other seven beds would still be on disk with nothing pointing at
        # them. Found the moment it was needed.
        loops = merge_loops(out / "manifest.json", entries)
        manifest = {
            "library": f"generated for {args.book}"
                       + ("" if arc is None else f" arc {arc}"),
            "note": "Per-book beds. Prompts are built from the book's own "
                    "theme pass; see tool/generate_beds.py.",
            "book": args.book,
            "palette": palette,
            "arc": arc,
            "theme": theme,
            "loops": loops,
        }
        (out / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        shown = out.relative_to(ROOT) if out.is_relative_to(ROOT) else out
        print(f"  wrote {shown}", flush=True)

    # How the app finds its way around this book's beds. Written for both
    # shapes, so discovery is one file rather than two conventions; a set made
    # before this existed has none, and is read as one whole-book arc.
    (root / "palette.json").write_text(
        json.dumps({
            "book": args.book,
            "palette": palette,
            "arc_size": 0,
            # What the app may reach for, which is what exists rather than what
            # was planned -- generating one arc must not shrink the book.
            "arcs": max(arcs_on_disk(root), 1) if arcs != [None] else 1,
            "cues": len(cues),
            "boundaries": boundaries,
        }, indent=2) + "\n",
        encoding="utf-8")

    print()
    print(f"wrote {root}")
    if unusable:
        raise SystemExit(
            f"{len(unusable)} bed(s) never passed in {args.attempts} "
            f"attempts: {', '.join(unusable)}. The least-bad take was kept "
            "for each. Raise --attempts, or try --positive-only.")


def register_limits(wanted: dict, centroid: dict) -> dict:
    """Each banded cue's brightness limits, {(mood, band): [floor, ceiling]}.

    One line between each pair of adjacent bands of a mood, at the geometric
    mean of the two bands' median centroids: halfway between where the
    prompt put each band's typical take, on the log scale pitch is heard on.
    A band's ceiling is its line to the band above and its floor its line to
    the band below; the outermost bands have None on the open side.

    One line rather than "band 0 below band 1's darkest, and vice versa",
    because before the cull neither band's darkest or brightest *kept* take
    exists yet, and the pool's extremes are single outliers. Taken from the
    pool, the "vice versa" half sets band 1's floor at band 0's brightest
    take -- on arc 0's live set, tense-0-v4 at 1,632 Hz, which would reject 6
    of 13 peak takes. A line between the medians cannot be set by one take.

    [centroid] is bench_palette's, per take -- not loopify's centroid_hz,
    which is a different number (SUMMARY 9.34). Only usable takes count: an
    inaudible take's register is not one the reader hears.
    """
    by_band: dict[tuple[str, int], list[float]] = {}
    for stem, slot in wanted.items():
        if slot["band"] is not None and stem in centroid:
            by_band.setdefault((slot["mood"], slot["band"]), []).append(
                centroid[stem])
    limits = {key: [None, None] for key in by_band}
    for mood in sorted({mood for mood, _ in by_band}):
        bands = sorted(band for m, band in by_band if m == mood)
        for low, high in zip(bands, bands[1:]):
            line = math.sqrt(statistics.median(by_band[mood, low])
                             * statistics.median(by_band[mood, high]))
            limits[mood, low][1] = line
            limits[mood, high][0] = line
    return limits


# The screech guard (SUMMARY 9.44): a take screeches if more of its frames
# than this, in %, have over a tenth of their energy above the cutoff (Hz).
# Set by listening tests on real beds. Every take heard as a screech is over
# a line: the lowest above 4 kHz, at 13.2 %, has a short and very prominent
# screech, and is caught above 6 kHz too, at 12.0 %. Two takes heard as
# acceptable are also over: one with a very high instrument note (15.5 %) and
# one trial take (16.1 %). A 4 kHz line that kept them would sit just under a
# screech (20.8 %), so the line errs towards losing them.
SCREECH_LINES = {4000: 10.0, 6000: 5.0}


def screech_over(harsh: dict) -> float:
    """How far over the screech lines a take is: its worst ratio of harsh
    share to line. 1.0 or more screeches."""
    return max(harsh[hz] / line for hz, line in SCREECH_LINES.items())


def cull_by_movement(out, wanted: dict, best: dict,
                     register_gate: bool = True) -> dict:
    """Keep each cue's `keep` takes by measured movement; delete the rest.

    Returns the surviving slots, renumbered so that variant 0 has the cue's
    own name and the rest are -v1, -v2 ... in the order they ranked. Files
    are renamed to match and `best` is re-keyed in place, so everything
    downstream -- the manifest, the identical-takes check -- sees a set that
    was generated at the plan's own counts.

    Band 0 keeps the stillest, band 1 the busiest, an unbanded cue the
    stillest (it is the whole mood, and a bed under prose errs still).
    Ranked by flux rank plus onset rank rather than a z-score, because a
    pool of two has no standard deviation worth the name. Unusable takes
    rank last whatever they measure: they are inaudible.

    Before any of that, the register gate (SUMMARY 9.35). Movement is one
    lever and brightness the other, and the cull used to see only the
    first: tense-0-v7, bright and middling-still, passed on its movement and
    made 12 of its 13 crossings to tense-1 inaudible. So a take on the wrong
    side of its band's line (see register_limits) ranks behind every take on
    the right side, however it moves. It is demoted, not dropped: if too few
    takes are inside the line to fill the band, the nearest ones outside it
    fill the gap and a warning says so -- more headroom is --overgen's job,
    and a run hours in must not die for want of it. A gated take still ranks
    ahead of an unusable one, since a bed in the wrong register is at least
    audible.

    Then the screech guard (SCREECH_LINES): a take that screeches ranks
    behind every take that does not, gated or not, since a screech is the one
    fault that is never acceptable under prose. Demoted, not dropped, for the
    same reason as the gate, and least harsh first; a warning says so if one
    is kept. It still ranks ahead of an unusable take, which failed loopify's
    own guards -- inaudible, or shrill over the whole bed.

    Nothing is re-keyed in place. Renumbering is a permutation, not a
    sequence of moves: `tense-0-v13` becomes `tense-0-v3` while the real
    `tense-0-v3` becomes `tense-0-v6`, so any dict updated as it is walked
    loses an entry it still needs -- which is exactly what happened, three
    hours into a run, after the cull had already printed its results. Both
    the slots and the reports are collected into fresh dicts and swapped in
    at the end, and the files go through a .tmp pass for the same reason.
    """
    # Every usable take is measured before any cue is culled, because the
    # register gate needs both bands of a mood to place the line between them.
    measured = {st: bench_palette.measure(out / f"{st}.wav")
                for st in wanted if best[st][3]["usable"]}
    centroid = {st: m["centroid"] for st, m in measured.items() if m}
    limits = register_limits(wanted, centroid) if register_gate else {}
    harsh = {st: bench_palette.harsh_frames(out / f"{st}.wav",
                                            tuple(SCREECH_LINES))
             for st in measured}
    screeches = {st for st in harsh if screech_over(harsh[st]) >= 1.0}

    survivors = {}
    carried = {}
    for cue in sorted({slot["cue"] for slot in wanted.values()}):
        stems = [st for st, slot in wanted.items() if slot["cue"] == cue]
        keep = wanted[stems[0]]["keep"]
        mood = wanted[stems[0]]["mood"]
        band = wanted[stems[0]]["band"]
        usable = [st for st in stems if st in measured]
        unusable = sorted((st for st in stems if st not in usable),
                          key=lambda st: best[st][0])
        movement = {st: (measured[st]["flux"], measured[st]["onsets"])
                    if measured[st] else (0.0, 0.0) for st in usable}
        floor, ceiling = limits.get((mood, band), (None, None))

        def outside(st):
            """How far past the line a take is, as a log ratio; 0 if inside.
            A take bench_palette could not measure is not judged."""
            c = centroid.get(st)
            if c is None:
                return 0.0
            if ceiling is not None and c > ceiling:
                return math.log(c / ceiling)
            if floor is not None and c < floor:
                return math.log(floor / c)
            return 0.0

        clean = [st for st in usable if st not in screeches]
        screeching = sorted((st for st in usable if st in screeches),
                            key=lambda st: screech_over(harsh[st]))
        inside = [st for st in clean if outside(st) == 0.0]
        gated = sorted((st for st in clean if st not in inside), key=outside)
        by_flux = sorted(inside, key=lambda st: movement[st][0])
        by_onset = sorted(inside, key=lambda st: movement[st][1])
        ranked = sorted(inside,
                        key=lambda st: by_flux.index(st) + by_onset.index(st))
        if band == 1:
            ranked.reverse()
        chosen = (ranked + gated + screeching + unusable)[:keep]
        for st in chosen:
            if st in movement:
                best[st][3]["movement"] = {
                    "flux": round(movement[st][0], 1),
                    "onsets": round(movement[st][1], 2),
                }
            if (floor, ceiling) != (None, None) and st in centroid:
                best[st][3]["register"] = {
                    "bench_centroid": round(centroid[st]),
                    "floor": None if floor is None else round(floor),
                    "ceiling": None if ceiling is None else round(ceiling),
                    "inside": st in inside,
                }
            if st in harsh:
                best[st][3]["screech"] = {
                    **{f"above_{hz // 1000}k": round(share, 1)
                       for hz, share in harsh[st].items()},
                    "clean": st not in screeches,
                }

        def shares(st):
            return "/".join(f"{harsh[st][hz]:.0f}" for hz in SCREECH_LINES)

        if screeching:
            above = " and ".join(f"{hz / 1000:g}" for hz in SCREECH_LINES)
            print(f"  {cue:16s} screech guard: {len(screeching)} of "
                  f"{len(usable)} usable takes harsh (% of frames above "
                  f"{above} kHz): " + ", ".join(
                      f"{st} {shares(st)}" for st in screeching), flush=True)
            kept = [st for st in chosen if st in screeches]
            if kept:
                print(f"  !  {cue}: only {len(clean)} clean takes for {keep} "
                      f"slots, so {len(kept)} kept that screech, least harsh "
                      f"first: " + ", ".join(
                          f"{st} {shares(st)}" for st in kept)
                      + ". Listen before installing; raise --overgen for "
                      "more headroom.", flush=True)
        if (floor, ceiling) != (None, None):
            line = (f"under {ceiling:.0f} Hz" if floor is None
                    else f"over {floor:.0f} Hz" if ceiling is None
                    else f"between {floor:.0f} and {ceiling:.0f} Hz")
            print(f"  {cue:16s} register gate: {len(inside)} of "
                  f"{len(clean)} clean takes {line} (bench centroid)"
                  + ("" if not gated else ", outside: " + ", ".join(
                      f"{st} {centroid[st]:.0f}" for st in gated)),
                  flush=True)
            short = [st for st in chosen if st in gated]
            if short:
                print(f"  !  {cue}: only {len(inside)} inside the line for "
                      f"{keep} slots, so {len(short)} kept from outside it, "
                      f"nearest first: " + ", ".join(
                          f"{st} {centroid[st]:.0f} Hz" for st in short)
                      + ". Raise --overgen for more headroom.", flush=True)
        if len(stems) > keep:
            print(f"  {cue:16s} kept {len(chosen)} of {len(stems)} by "
                  f"movement ({'busiest' if band == 1 else 'stillest'}): "
                  + ", ".join(f"{st} {movement[st][0]:.0f}/{movement[st][1]:.1f}"
                              for st in chosen if st in movement),
                  flush=True)
        for st in stems:
            if st not in chosen:
                for suffix in (".wav", ".raw.wav"):
                    (out / f"{st}{suffix}").unlink(missing_ok=True)
        # Renumber in two passes, since a survivor's new name may be a
        # dropped take's old one -- or another survivor's.
        names = {st: (cue if i == 0 else f"{cue}-v{i}")
                 for i, st in enumerate(chosen)}
        for st, new in names.items():
            if st != new:
                for suffix in (".wav", ".raw.wav"):
                    src = out / f"{st}{suffix}"
                    if src.exists():
                        src.rename(out / f"{st}.tmp{suffix}")
        for i, (st, new) in enumerate(names.items()):
            if st != new:
                for suffix in (".wav", ".raw.wav"):
                    tmp = out / f"{st}.tmp{suffix}"
                    if tmp.exists():
                        tmp.rename(out / f"{new}{suffix}")
            survivors[new] = dict(wanted[st], stem=new, variant=i)
            carried[new] = best[st]
    best.clear()
    best.update(carried)
    return survivors


def write_bed(out, cue: str, clip, loop, rate: int) -> None:
    """The processed bed, and the model's raw output beside it.

    The raw take is kept because it is the only way to hear what the
    processing did, and the only way to tell a bad generation from a bad
    loop-fix.
    """
    loopify.write_wav_at(out / f"{cue}.raw.wav", clip, rate)
    loopify.write_wav(out / f"{cue}.wav", loop)


def where_of(arc):
    return "book" if arc is None else f"arc{arc}"


def merge_loops(manifest_path, entries: list[dict]) -> list[dict]:
    """Freshly generated rows, laid over whatever the manifest already had.

    Keyed by cue *and take*, so a re-run of one bed replaces that row and
    leaves the rest -- including the other takes of the same cue, which is the
    whole point of there being several. Rows written before cues existed are
    keyed by mood, which is what the cue was then, and rows written before
    takes existed are take 0.
    """
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


if __name__ == "__main__":
    main()
