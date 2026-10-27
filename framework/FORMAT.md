# The book workspace

One directory per book. Every stage of preparing a book for music reads files
earlier stages wrote and writes one of its own, as plain JSON (UTF-8), so a
host can read any of it without either package — and can do any stage itself.
A host with its own classifier writes `tags/` and skips ours; a host with its
own GPU fleet runs the job and hands the pool back.

Format version **1**. `workspace.json` records it; a reader refuses a newer one.
JSON files are replaced atomically (written to `<name>.tmp`, then renamed).

| file | written by | read by |
| --- | --- | --- |
| `workspace.json` | ingest | everything |
| `chapters.json` | ingest | every model stage |
| `breaks.json` | scan | cut, arc themes |
| `arcs.json` | cut, arc themes | tag, plan, export, player |
| `themes.json` | book theme, arc themes | scan, tag, export |
| `tags/ch-NNNNN.json` | tag | plan, player |
| `allocation.json` | plan | export |
| `arc-NNN/manifest.json` + audio | import | player |
| `palette.json` | import | player |
| `jobs/…` | generate | import (the pool, kept for re-culling) |

The last three — `arcs.json`, `arc-NNN/`, `palette.json` — are the same files
in the same shapes as the reader app's `generated/<book>/`, so a workspace's
music plays in the app and the app's plays through the framework's player.

---

## `workspace.json`

```json
{
  "format": 1,
  "book": "3f2a9c1d0b8e7a65",
  "title": "Pride and Prejudice",
  "author": "Jane Austen",
  "source": "pride_and_prejudice.epub",
  "chapters": 61,
  "paragraphs": 2064,
  "created": "2026-09-24T21:04:11.201Z"
}
```

`book` is the first 16 hex digits of SHA-256 over the split text, so the same
edition ingested twice is the same book and a different edition is not.

## `chapters.json`

```json
[
  {"index": 0, "title": "Chapter 1", "paragraphs": ["It is a truth…", "…"]}
]
```

Split **once**, at ingest, by one rule (Dart `Book.fromText`, the reader app's
and phase0's): blank-line-separated blocks, internal whitespace collapsed,
blocks under 60 characters folded into the next. Paragraph `i` of chapter `c`
therefore means the same text to every stage and every host. Chapters with no
text are dropped and the rest renumbered, so an index is a position.

**This file is the book.** Nothing else in the workspace contains its text, and
nothing that leaves the machine is read from it (see *Jobs*).

## `breaks.json`

```json
{
  "backend": "ollama:qwen2.5:7b",
  "chapters": [
    {"index": 0, "score": 0.1, "situation": "Bennets discuss Netherfield", "hard": false}
  ]
}
```

How much each chapter starts a new storyline, 0–1. `hard` means the chapter
opens a division the author declared ("Volume Two"), which scores 1 whatever
the model said. Written contiguously from chapter 0; the scan front is the first
missing index.

## `arcs.json`

```json
{
  "book": "3f2a9c1d0b8e7a65",
  "min": 50, "max": 100, "threshold": 0.8,
  "scanned_through": 61,
  "sets": 2,
  "arcs": [
    {"index": 0, "start": 0, "end": 29, "title": "Netherfield", "palette": 0},
    {"index": 1, "start": 30, "end": 60, "title": "Rosings", "palette": 1}
  ]
}
```

`start`/`end` are inclusive chapter indices. `palette` is the arc whose beds
this arc plays: itself unless its theme was close enough to an earlier arc's to
share (`threshold`, Jaccard over the theme's words). `palette == index` marks a
set that has to be generated; `sets` counts them. `title` is the arc scan's
description and **is book-derived text** — it is never exported.

## `themes.json`

```json
{
  "book": {"overall_theme": "Regency Romance", "instrumentation": "string quartet, piano",
           "genre_seed": "chamber", "theme_id": "regency-romance-4be81c",
           "sample": "a1b2c3d4e5f60718", "backend": "ollama:qwen2.5:7b"},
  "arcs": {"0": {"…": "same shape"}, "1": {"…": "same shape"}}
}
```

The **book** theme is what arc scanning and paragraph tagging are scored
against. **Arc** themes vary the generation prompts between arcs. `sample` is a
digest of the text the theme was read from: re-cutting an arc changes its
sample and re-themes it; an unchanged arc keeps its theme.

## `tags/ch-NNNNN.json`

```json
{
  "chapter": 12,
  "digest": "9f8e7d6c5b4a3210",
  "paragraphs": 41,
  "backend": "ollama:qwen2.5:7b",
  "theme": "Regency Romance",
  "tags": {"0": {"mood": "calm", "intensity": 0.3, "reason": "quiet morning"}}
}
```

One file per chapter, keyed by paragraph index. `mood` is one of `tense calm
melancholic triumphant romantic ominous whimsical neutral`; `intensity` is 0–1.
Tags are valid only while `digest` matches the chapter's text; a missing index
is a paragraph the model never answered for. Tags from different `backend`s are
not comparable — a set is best planned from one model's tags.

## `allocation.json`

```json
{
  "book": "3f2a9c1d0b8e7a65",
  "budget": 32,
  "sets": [
    {"palette": 0, "arcs": [0], "chapters": [0, 29], "observations": 1204,
     "runs": 3, "changes": 118,
     "tagged":   {"calm-0": 410, "romantic-1": 37, "…": 0},
     "sounding": {"calm-0": 522, "romantic-1": 12, "…": 0},
     "allocation": {"calm-0": 14, "romantic-1": 4, "tense-0": 2, "…": 1}}
  ]
}
```

Beds per cue per set. A cue is `<mood>-<band>`, band `0` (still) or `1` (peak,
intensity ≥ 0.65). Weighted by what would **sound** — the tags replayed through
the real cue selector — with every mood that is **tagged** guaranteed a bed.
A count above 1 is that many takes of one prompt, rotated by the player.

## Jobs

What leaves the machine to generate a set. Prompts, keys and seeds — **no book
text**: not chapters, not arc titles, not situations. A test plants a sentence
in `chapters.json` and fails if it appears in a job.

```json
{
  "book": "3f2a9c1d0b8e7a65",
  "palette": "full",
  "settings": {"model": "facebook/musicgen-stereo-medium", "seconds": 30,
               "tokens_per_second": 50, "guidance": 3.0, "attempts": 4,
               "seed": 0, "batch": 2, "overgen": 3, "register_gate": true,
               "phrasing": "negated"},
  "sets": [{
    "dir": "arc-000", "arc": 0, "start": 0, "end": 29,
    "theme": {"genre_seed": "chamber", "overall_theme": "Regency Romance",
              "instrumentation": "string quartet, piano"},
    "cues": [{"stem": "calm-0-v5", "cue": "calm-0", "variant": 5, "keep": 14,
              "mood": "calm", "band": 0, "band_name": "still",
              "seed_base": 20, "key": "G major", "prompt": "chamber. Regency…"}]
  }]
}
```

The job is the whole **over-generated pool** (`overgen` takes per kept bed).
Take `n` tries `seed_base`, then `seed_base + 1` … up to `attempts`, re-seeding
only while the audibility guard rejects it. The runner writes every take,
usable or not, with `<stem>.report.json` beside each one that passed (so a
restarted run resumes), and a `manifest.json` per set.

## `arc-NNN/manifest.json`

```json
{
  "library": "generated for 3f2a9c1d0b8e7a65 arc 0",
  "book": "3f2a9c1d0b8e7a65", "palette": "full", "arc": 0,
  "theme": {"genre_seed": "chamber", "…": "…"},
  "loops": [
    {"cue": "calm-0", "variant": 0, "mood": "calm", "band": 0,
     "band_name": "still", "file": "calm-0.wav", "description": "<prompt>",
     "model": "facebook/musicgen-stereo-medium", "key": "G major",
     "seed": 20, "attempt": 1, "batch": 1, "usable": true,
     "energy_above_200hz": 0.894, "centroid_hz": 418.2,
     "movement": {"flux": 136.0, "onsets": 4.5},
     "register": {"bench_centroid": 612, "floor": null, "ceiling": 1009,
                  "inside": true}}
  ],
  "distances": {"calm-0|tense-1": {"timbre": 1.61, "chroma": 0.83}}
}
```

The survivors of the cull, renumbered so variant 0 of each cue is `<cue>.wav`
and the rest `<cue>-vN.wav`, each with `<stem>.raw.wav` (the model's unlooped
output) beside it. Beds are 24-second seamless stereo loops at 22,050 Hz,
16-bit WAV.

`distances` is measured from the audio: for each unordered pair of cues
(`a|b`, `a < b`), how far apart they sound relative to the set's average change
(1.0), in timbre and in tonal content. A player leads into a change when the
coming cue is ≥ 1.25 away, overlapping the two beds only when chroma ≤ 1.2. A
set without `distances` never leads in.

There are **two different centroids** in a row: `centroid_hz` is the
audibility guard's (power-weighted, one FFT over the bed) and
`register.bench_centroid` is the register gate's (magnitude-weighted per frame).
They differ by 1.5–5.3× and must never be compared.

## `palette.json`

```json
{
  "book": "3f2a9c1d0b8e7a65", "palette": "full", "arc_size": 0,
  "arcs": 2, "cues": 16,
  "boundaries": [{"index": 0, "start": 0, "end": 29, "title": "…", "palette": 0}]
}
```

How a player finds the set for a chapter: the arc containing it, then the arc
it plays (`palette`), clamped to `arcs` — the highest arc generated plus one —
so reading past what has been generated plays the last set rather than
silence. An arc directory with no `manifest.json` falls back to a whole-book
set at the root, if there is one. No `palette.json` at all means the root holds
one whole-book set.
