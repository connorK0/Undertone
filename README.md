# Undertone

Adaptive background music for reading. As you read, a local language model
tags the mood and intensity of each paragraph. The reader then plays and
crossfades between generated music beds that follow the story: a quiet
chapter stays quiet, and a fight builds into something tense. Every bed is
written to sit underneath the prose, with no melody, drums or vocals to
compete with the words.

## How it works

```
book text ─► arc scan ─► arc themes ─► paragraph tags ─► bed plan ─► MusicGen ─► guards + cull ─► beds
             (LLM)       (LLM)         (LLM: mood,       (replay of               (audibility,
                                        intensity)        what sounds)             register, screech)

reading position ─► cue selector ─► crossfades, warm-up and lead-ins over the looping beds
```

1. **Arcs.** The book is scanned for where its storylines change, cut into
   arcs, and each arc is given a musical theme: genre, instrumentation, key.
2. **Tags.** Every paragraph gets one of eight moods (tense, calm,
   melancholic, triumphant, romantic, ominous, whimsical, neutral) and an
   intensity. Tagging runs on qwen2.5:7b through Ollama, and the results are
   cached locally.
3. **Plan.** The tags are replayed through the real cue selector to count what
   would actually play, and each arc's bed budget is split in proportion.
4. **Generation.** MusicGen writes several takes of each bed, on a local GPU or
   on Kaggle's free T4s. Each take is looped seamlessly and level-matched. Takes
   are then culled by measured movement, by brightness (a register line between
   intensity bands) and by a screech guard.
5. **Playback.** The reading position drives a smoothed cue selector. The
   engine crossfades between beds, rotates takes, comes up slowly at the start
   of a session, and starts preparing for a big change before it arrives.

## Engineering highlights

- **Measured, not assumed.** Each guard and threshold comes from spectral
  measurements checked against listening tests. That covers the audibility
  floor, the register line between bands and the screech lines.
- **The book never leaves the machine.** Generation jobs carry prompts, keys
  and seeds only. A test fails if a sentence of the book appears in an exported
  job.
- **Cloud offload that survives the cloud.** The GPU runner resumes after
  preemption and stops starting work before a session limit. Every returned
  file is verified and re-measured at home before anything is installed.
- **Guarantees across languages.** Parity tests pin the generator's 3,072
  prompts byte for byte across implementations. A contract test runs the real
  Python export on a workspace the Dart pipeline wrote.
- **Tests.** The Windows reader has 286 Flutter tests plus integration tests.
  The framework has 167 Dart tests and four Python suites, and the iOS reader
  has widget tests.

## Repository layout

| folder | what it is |
| --- | --- |
| [`phase0/`](phase0/) | Python prototype: does an LLM's mood tag, mapped to music parameters, match the text? `phase0-prototype/` is its first version. |
| [`phase1/`](phase1/) | The Windows reader (Flutter): library, ePub import, paged and scrolling reading, the mood pipeline and the adaptive score. `tool/` holds the Python music generator and the analysis tools. |
| [`framework/`](framework/) | The engine as reusable packages. `music_book_core` (Dart) covers ingest, arcs, tagging, planning and the runtime. `music_book_gen` (Python) covers prompts, MusicGen, the cull and cloud offload. `music_book_player` (Flutter) plays the score. |
| [`ios/`](ios/) | An iOS reader built on the framework. Books are prepared on a computer and carried over as packs. |

## Tech

Flutter and Dart (Windows, iOS) · Python (NumPy, soundfile, PyTorch and
Transformers for MusicGen) · SQLite · Ollama (qwen2.5:7b) · flutter_soloud ·
Kaggle

## Running it

Each folder's README has its own setup and commands:

- [`phase1/README.md`](phase1/README.md): the Windows reader;
- [`framework/README.md`](framework/README.md): preparing a book and
  generating its music;
- [`ios/README.md`](ios/README.md): the iOS reader.

You'll need Flutter 3.35+ and Python 3.11+. Tagging needs Ollama with
qwen2.5:7b, and generation needs a CUDA GPU or a Kaggle account.

## Status

The Windows reader works end to end, with generated scores for a 2,364-chapter
test book. The iOS reader passes its tests but hasn't yet been built for a
device.

## Rights

© 2026 Connor Krolls. All rights reserved. The source is published so it can be
read. No licence is granted to use, copy, modify or distribute it, beyond what
GitHub's terms of service allow.

Third-party material and the models' licences are listed in
[CREDITS.md](CREDITS.md).
