# Undertone framework

Adaptive background music for books, as a set of packages any reading app can
build on: everything between the text and the speakers **except the reader**.

It is the engine of the Undertone reader app (`phase1/`), extracted so it can
be (a) offered to other book software as an add-in, and (b) the basis of an
iOS reader (`ios/`). The reader app itself is untouched and still runs its own
copy — see *Relationship to phase1*.

```
            text                     plan                    audio
 ┌──────────────────────┐  ┌────────────────────┐  ┌─────────────────────┐
 │ dart/ music_book_core│  │ python/            │  │ flutter/            │
 │                      │  │ music_book_gen     │  │ music_book_player   │
 │ ingest (ePub, text)  │  │                    │  │                     │
 │ book theme           │  │ prompts per cue    │  │ crossfades, takes,  │
 │ arc scan + cut       │  │ MusicGen + guard   │  │ lead-in, warm-up    │
 │ arc themes, grouping │  │ cull + register    │  │ on flutter_soloud   │
 │ mood tags            │──▶ measurement        │──▶ (Windows, iOS,      │
 │ bed plan             │  │ local / Kaggle /   │  │  Android, macOS)    │
 │                      │  │ Modal              │  │                     │
 │ runtime: BookScore,  │◀─┼────────────────────┼──│ driven by the       │
 │ ScoreFollower        │  │                    │  │ runtime's decisions │
 └──────────────────────┘  └────────────────────┘  └─────────────────────┘
                 all three read and write one **book workspace**
```

The contract between them is a directory of plain JSON and WAV files —
**[FORMAT.md](FORMAT.md)**. A host can read any of it without our code, and do
any stage itself.

## Preparing a book

```sh
# 1. text -> workspace, then the model stages (needs Ollama, qwen2.5:7b)
cd framework/dart
dart run music_book ingest  book.epub  ~/books/pride
dart run music_book prepare ~/books/pride --arc 0      # theme, scan, cut,
                                                       # arc themes, tag, plan
dart run music_book status  ~/books/pride

# 2. plan -> beds (needs a GPU somewhere)
cd framework/python
python -m music_book_gen prompts  ~/books/pride --arc 0          # read first
python -m music_book_gen generate ~/books/pride --arc 0 --overgen 3   # this GPU
#   or elsewhere:
python -m music_book_gen export   ~/books/pride --arc 0 --overgen 3 --out job.json
python -m music_book_gen kaggle push --job job.json --slug pride-arc0
python -m music_book_gen kaggle pull --slug pride-arc0 --out dl
python -m music_book_gen import   ~/books/pride --job job.json \
    --results dl/beds-gpu0 dl/beds-gpu1
```

Every stage is resumable: run it again and it asks only for what is missing.
Import verifies every returned file, culls the pool at home (movement, behind
the register gate), installs the survivors and measures the set's distances.

## Playing it

```dart
final score = await BookScore.load(workspaceDir);   // or generated/<book>/
final follower = ScoreFollower(theme: bookTheme);
// on every reader movement:
final set = await score.setFor(chapter);
final d = follower.observe(set: set!, chapter: tagsOf(chapter),
    next: tagsOf(chapter + 1), paragraph: paragraph, now: DateTime.now());
// d.cue, d.energy, d.changed (crossfade now), d.lead (prepare), d.leadNote
```

`music_book_player` does the audio side of that on flutter_soloud. A host on
another audio stack plays the same decisions its own way: they are four fields.

## Integrating with book software

Three shapes, from most to least of ours:

| | host provides | framework provides |
| --- | --- | --- |
| **Embedded** (Flutter/Dart app) | the reader, the reading position | everything: `music_book_core` + `music_book_player`, workspaces prepared by the CLIs |
| **Service** (any app) | the reader, an audio player, a text upload | a server runs both CLIs; the app downloads a workspace (tags, `palette.json`, `arc-NNN/`) and implements the runtime's rules — `ScoreFollower`, `CueSelector` and `resolveCue`, about 300 lines to port |
| **Bring your own** | its own classifier or GPUs | whichever stages it does not: write `tags/` and let us plan and generate, or take the job and return the pool |

What never leaves the host's machine in any shape: the book. Jobs carry prompts,
keys and seeds only, and a test fails if a sentence of the book appears in one.

## Status

| part | tested | how |
| --- | --- | --- |
| `music_book_core` | **167 tests** | 140 ported from phase1 unchanged in logic; pipeline and workspace against a scripted model; runtime; a cross-language contract test that runs the real Python export on a workspace the Dart pipeline wrote |
| `music_book_gen` | **4 suites** | 3,072 prompts byte-identical to phase1's generator; the cull (14 cases); the offload round trip (8); export from a hand-written workspace, including the no-book-text sentinel |
| `music_book_player` | **decisions only** | exercised by `ios/`'s tests as a real `ScorePlayer` with no audio device: a position and a workspace's own tags become the right cue, and closing a book leaves no timer behind. **The sound itself has not been played** — that needs a device |
| **against a real model** | **not yet** | every model stage is tested with a scripted backend; the real Ollama and MusicGen paths are phase1's, unchanged, but have not been run *through the framework* |

## Things a buyer will ask about

- **The music model's licence.** The generator uses Meta's MusicGen, whose
  weights are released **CC-BY-NC 4.0 — non-commercial**. Selling generated
  beds, or generation as a paid feature, is not covered by that licence. Before
  any paid offering, the generator needs a commercially licensed model or a
  licence from the rights holder. The model is isolated to `runner.py`'s
  `load_model` (and one `generate` call), so the swap is small in code; what it
  does to how the beds *sound* would need the whole tuning loop again.
- **The tagging model.** qwen2.5:7b (Apache-2.0) through Ollama by default;
  `TaggingBackend` is one method, so a hosted model or an on-device one drops
  in without touching the prompts.
- **Cost per book.** Measured on one book (SUMMARY §9.37, §9.38): arc 0's
  96 takes took one 96-minute session on Kaggle's free T4 x2, and the book is
  ~2,500 takes at the current palette shape — about 42 h of session time if
  every arc goes like arc 0, or ~110 h on a laptop GPU. One arc measured, so
  an extrapolation.

## Relationship to phase1

The code here was **copied** out of `phase1/` — the reader app — not moved.
The app still runs its own copy, so the two will drift until the app is moved
onto the framework (a decision still to take). Drift is guarded where it would
be silent: `tests/test_parity.py` pins every prompt to phase1's generator, and
the Dart side's ported tests pin the arithmetic. The history and the evidence
for every rule — why two bands, why the register gate, why sounding and not
tagged — is kept in the project's lab notebook, which is not part of this
repository; the code cites it by section ("SUMMARY §9.36").
