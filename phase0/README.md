# Phase 0 — mood-tagging prototype

Answers one question and nothing else: **does an LLM mood tag, mapped to music
parameters, actually match the vibe of the text?**

No UI, no reader app, no audio. Read the printed table next to the source prose
and judge whether the tags feel right. Three models can do the tagging — the
quality baseline, a cheap hosted tier, and a free local one — and their output
is the same shape so you can read them side by side.

## Setup

```powershell
cd phase0
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
copy .env.example .env
```

Then set up whichever backend you want to use:

| `--model` | What runs | Setup |
|---|---|---|
| `opus` (default) | `claude-opus-5`, Anthropic API | Put an `ANTHROPIC_API_KEY` in `.env` ([get one here](https://console.anthropic.com/settings/keys)) |
| `haiku` | `claude-haiku-4-5`, Anthropic API | Same key. Roughly a fifth of the price of Opus. |
| `local` | An Ollama model on this machine | Install [Ollama](https://ollama.com/download), then `ollama pull qwen2.5:7b`. No key, no network. |

The local backend defaults to `qwen2.5:7b` (about 4.7GB, fits fully in 8GB of
VRAM). To try a different model, pull it and set `OLLAMA_MODEL` in `.env` —
`qwen2.5:14b` and `phi4` are the sharper, slower options; they spill a little
past 8GB into system RAM, which is fine for an offline script.

## Run

```powershell
python main.py sample_books\chapter1.txt                     # opus
python main.py sample_books\chapter1.txt --model haiku
python main.py sample_books\chapter1.txt --model local --reasons
```

`--reasons` prints the model's one-phrase justification under each row — usually
what tells you *why* a tag felt wrong.

Tags are cached per book **and per model** in `mood_cache.json`. A second run
with the same file and the same `--model` makes zero model calls. Switching
`--model` re-classifies; it never serves you another model's tags.

| Flag | Default | What it does |
|---|---|---|
| `--model {opus,haiku,local}` | `opus` | Which model classifies |
| `--chunk-size N` | 6 | Paragraphs per classification call. Lower it if a small local model muddles indices; raise it to cut cost on Opus. |
| `--reasons` | off | Print the reason under each row |
| `--no-cache` | off | Ignore cached tags and re-call the model |
| `--cache-file PATH` | `mood_cache.json` | Where tags are stored |

## What it does

1. **Theme pass** — one call over the whole text → `overall_theme`,
   `instrumentation`, `genre_seed`, plus a `theme_id` derived from the theme
   string so it stays stable across runs.
2. **Mood pass** — paragraphs classified several per call → `mood`,
   `intensity`, `reason` for each. Several per call costs far less than one
   each and gives the model the surrounding scene, which is most of what mood
   continuity depends on. A paragraph that reads neutral alone often is not
   neutral three paragraphs into a chase.
3. **Mapper** ([mapper.py](mapper.py)) — mood + intensity + theme → music-API-style
   parameters: genre, mood token, energy, bpm, instrumentation. Nothing calls a
   music service; the shape just matches what an adaptive API like Mubert takes.

The mood taxonomy is `tense, calm, melancholic, triumphant, romantic, ominous,
whimsical, neutral` with intensity 0.0–1.0. It lives in one place
([classify.py](classify.py), `MOODS`) and is enforced by the JSON schema every
backend is given, so all three return the same vocabulary. If a model wanders
off it anyway, the table shows the stray mood rather than hiding it.

## How the backends differ

Same prompts, same schema, three request shapes ([classify.py](classify.py)):

- **opus** — `thinking` is omitted, which on Opus 5 runs adaptive thinking.
  Depth is controlled by `output_config.effort`: `high` for the one theme call,
  `low` for the many paragraph calls. The request opts into a server-side
  fallback (`fallbacks="default"`) because Opus 5's safety classifiers can
  decline dark prose; a declined request is retried on another model inside the
  same call, and a chunk that is still declined prints as `(untagged)` rather
  than killing the run.
- **haiku** — no thinking, no `effort` (Haiku 4.5 rejects it), no fallback
  parameter. Plain model + schema + prompt. The refusal check stays as a cheap
  safety net.
- **local** — Ollama's schema-constrained output (`format=<schema>`), the same
  idea as `output_config.format`. Temperature 0 for repeatable tags, and
  `num_ctx` raised to 16k because Ollama silently truncates prompts to a small
  default window and a chapter is 8–10k tokens. No key, no network, no cloud
  concepts leaking in.

All three return JSON guaranteed by the schema, so none of the prompts say
"respond only with JSON" — that instruction is a leftover from the prefill era
and does nothing here.

## Cost

| Model | Price (in / out per MTok) | Sample chapter | 100k-word novel |
|---|---|---|---|
| `opus` | $5 / $25 | ~$0.10 | $5–10 |
| `haiku` | $1 / $5 | ~$0.02 | $1–2 |
| `local` | free | free | free, slower |

Estimated from token counts, not measured. Opus figures are mostly thinking
tokens on the paragraph pass, which is why it runs at `low` effort.

## Sample texts

- `sample_books/chapter1.txt` — original prose written for this prototype and
  placed in the public domain. It carries a deliberate mood arc: calm routine,
  an ominous discovery, a tense peak, a melancholic aftermath, resolve at the
  end. Fourteen paragraphs; a quick, cheap run with a known answer.
- `sample_books/dracula_ch1.txt` — chapter one of Bram Stoker's *Dracula*
  (public domain, from Project Gutenberg, license header and footer trimmed).
  Thirty-six paragraphs of real Victorian prose: travelogue calm sliding into
  superstition and dread. The better test of whether the tagging actually
  works.

Any UTF-8 `.txt` with blank lines between paragraphs works. Blocks shorter
than 60 characters (chapter headings, scene breaks, letter sign-offs) carry no
mood of their own and are folded into the paragraph that follows them rather
than tagged separately. For another Gutenberg text, download it and trim the
boilerplate at the top and bottom first, or those paragraphs will be tagged too.

## Deliberately not here

No UI, no reader app, no Flutter or MAUI, no audio playback, no fine-tuning, no
auth, no cross-model scoring harness. This is a throwaway validation script and
reads like one.
