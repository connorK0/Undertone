# Undertone — Adaptive Background Music for Reading

> Open a book and the music follows the story. A local language model tags the mood of every paragraph, and generated music beds **crossfade underneath the prose**: quiet when the chapter is quiet, building when the story turns.

A solo project by Connor Krolls: a Python prototype, a Windows reader, the engine as reusable packages, and an iOS reader built on them.

---

## What It Does

Undertone gives any book its own score:

1. **Import** an ePub or plain-text book into the library
2. **Scan** the book for where its storylines change, cut it into arcs, and give each arc a musical theme (genre, instrumentation, key)
3. **Tag** every paragraph with one of eight moods (tense, calm, melancholic, triumphant, romantic, ominous, whimsical, neutral) and an intensity, using qwen2.5:7b through Ollama
4. **Generate** each arc's beds with MusicGen, on a local GPU or on Kaggle's free T4s. Every take is looped seamlessly, level-matched, and culled by measurement
5. **Read**, and the score follows your position: it crossfades between beds, rotates takes, fades in at the start of a session, and starts preparing for a big change before it arrives

The cue selector is the core idea. The music follows the dominant mood of a four-paragraph window, not the paragraph under your eye. A new mood has to appear on two separate paragraphs before it is believed, and a cue holds for at least 15 seconds, so page-flipping can't cause a burst of crossfades. Within a mood, intensity drives a low-pass filter, so a long tense stretch still moves from paragraph to paragraph.

Every bed is written to sit under the words: no melody, drums or vocals to compete with them.

---

## Tech Stack

| Layer | Technology | Why |
|---|---|---|
| Apps | **Flutter** + **Dart** | One codebase for the Windows reader and the iOS reader |
| Mood tagging | **qwen2.5:7b** via **Ollama** | Runs locally, so the book never leaves the machine |
| Music generation | **MusicGen** (Meta) via **Transformers** + **PyTorch** | Instrumental beds prompted from each arc's theme |
| Audio analysis | **NumPy** + **soundfile** | FFT measurements behind every guard: audibility, register, screech |
| Playback | **flutter_soloud** | Low-latency mixing, crossfades, and a real-time low-pass filter |
| Storage | **SQLite** | Library, reading position, and the tag cache |
| Cloud GPU | **Kaggle** (T4 ×2) | Free GPU time for generation, with every result re-checked at home |

---

## Architecture Highlights

### Planning from What Actually Plays
Before any music is generated, each arc's tags are replayed through the real cue selector to count what would actually sound, and the arc's bed budget is split in proportion. In the selector itself, moods a book visits only in short stretches get a heavier vote (`minorityWeight`), so the gentle moods aren't swallowed by the tense and neutral passages around them.

### Measured Guards on Generated Audio
MusicGen writes three takes of every bed (`--overgen 3`), and the cull keeps the best by measurement:
- **Audibility, from both ends.** A take is rejected if too little of its energy is above 200 Hz, where a laptop speaker can't play it, or if it is so bright it has no body.
- **Register.** A brightness line is placed between each mood's two intensity bands, and a take on the wrong side is ranked behind the rest. This keeps a change of band audible.
- **Screech.** A frame is harsh when more than 10% of its energy is above a cutoff. Takes with too many harsh frames above 4 kHz or 6 kHz are ranked behind clean ones.
- **Movement.** Of the takes that pass, the ones with the most measured movement win.

### The Book Never Leaves the Machine
Tagging runs on a local model. A generation job sent to the cloud carries only prompts, keys and seeds, and a test fails if a sentence of the book appears in an exported job.

### Cloud Offload That Survives the Cloud
A job is exported as JSON, pushed to Kaggle, and run on two T4s. The runner resumes after preemption and stops starting new work before the session limit. On the way back, every returned file is verified and re-measured before anything is installed.

### One Engine, Three Packages
The engine lives in `framework/` as packages any reading app can build on:
- `music_book_core` (Dart) covers ingest, arcs, tagging, planning and the runtime;
- `music_book_gen` (Python) covers prompts, MusicGen, the cull and the offload;
- `music_book_player` (Flutter) plays the score.

They share one on-disk contract of plain JSON and WAV files ([FORMAT.md](framework/FORMAT.md)), so a host can run any stage itself.

### Tested Across Languages
Parity tests pin the generator's 3,072 prompts byte for byte across implementations, and the Dart mood mapper against its Python original at every hundredth of intensity. A contract test runs the real Python export on a workspace the Dart pipeline wrote. The suites:
- the Windows reader: 286 Flutter tests, plus integration tests;
- the framework: 167 Dart tests and four Python suites;
- the iOS reader: widget tests.

---

## Project Structure

```
phase0/                       # Python prototype: does an LLM's mood tag match the text?
phase1/                       # The Windows reader (Flutter)
  lib/
    mood_trigger.dart         # One trigger per page turn or settled scroll
    mood_pipeline.dart        # Ollama passes, prefetch window, SQLite cache
    arc_scanner.dart          # Finds where the storylines change
    allocation.dart           # Splits each arc's bed budget by what actually sounds
    cue_selector.dart         # Decides what should be playing
    music_engine.dart         # Crossfades, takes, lead-ins, intensity → low-pass
    epub.dart                 # ePub import
  tool/
    generate_beds.py          # MusicGen prompts, takes, guards and the cull
    loopify.py                # Seamless loops and level matching
    offload*.py               # Export a job, run it on Kaggle, verify and import
framework/
  dart/                       # music_book_core + the music_book CLI
  python/                     # music_book_gen
  flutter/music_book_player/  # Plays the score on flutter_soloud
  FORMAT.md                   # The book workspace all three share
ios/                          # The iOS reader; books arrive as packs
```

---

## Getting Started

**Prerequisites:** Flutter 3.35+, Python 3.11+, [Ollama](https://ollama.com) with `qwen2.5:7b`, and a CUDA GPU or a Kaggle account for generation. The Windows reader needs Windows Developer Mode to build.

```bash
git clone https://github.com/connorK0/Undertone.git
cd Undertone
ollama pull qwen2.5:7b
```

Run the Windows reader:

```powershell
cd phase1
flutter run -d windows
```

Prepare a book and generate its music with the framework:

```bash
cd framework/dart
dart run music_book ingest  book.epub ~/books/mybook
dart run music_book prepare ~/books/mybook --arc 0

cd ../python
pip install -e ".[generate]"
python -m music_book_gen generate ~/books/mybook --arc 0 --overgen 3
```

Each folder's README has the full commands, including the Kaggle offload: [phase1](phase1/README.md), [framework](framework/README.md), [ios](ios/README.md). The iOS reader needs a Mac with Xcode to build, and it hasn't been built for a device yet.

---

## Engineering Challenges

**Mood barely moves.** Over the first stave of *A Christmas Carol*, the cue sits on `tense` for 56 of 127 paragraphs. That isn't a tuning error: no window setting shortens those stretches without also firing on one-paragraph blips. What does move is intensity, which swings from 0.30 to 1.00 across that stretch, but as volume alone that's only 3.1 dB. So intensity also drives a low-pass filter from 320 Hz to 5 kHz: a large change you can hear, at nearly constant loudness.

**A generated clip is not a bed.** MusicGen starts and ends wherever it likes, at whatever loudness it likes. `loopify.py` closes the loop with an equal-power fold of the tail and normalises every take to the same level. The audibility guard had to be two-sided. On the very first generation, *Dracula*'s `ominous` bed came back with 0.3% of its energy above 200 Hz, which is inaudible. With only a floor in place, the next seed passed at a 2,940 Hz centroid: a horror drone with no weight at all.

**Screech you only hear by listening.** Some takes carried a high whine that no existing guard caught. Measuring the spectra of takes judged by ear put the lines at 4 kHz and 6 kHz. At those lines, a high instrument note passes and a screech doesn't. Screeching takes are ranked behind clean ones rather than dropped, so an arc never ends up with no bed at all.

**LLM labels aren't stable.** Tagging the same paragraphs three times, with only the theme string changed, agrees on about 70% of moods. Wider smoothing doesn't help, because the model disagrees about whole passages, not single paragraphs. So tags are cached per book, which makes a book sound the same every time it's opened.

**Two languages, one behaviour.** The Dart mood mapper is a port of the Python original, and they matched only after two rounding traps were handled. Python rounds half-to-even on the exact binary value, so both `x * 100` and `.round()` give the wrong answer. Parity tests now pin both the mapper and every generated prompt across the two languages.

---

## License

Copyright (c) 2026 Connor Krolls. All rights reserved. The source is published so it can be read. No licence is granted to use, copy, modify or distribute it, beyond what GitHub's terms of service allow.

Third-party material and the models' licences are listed in [CREDITS.md](CREDITS.md).
