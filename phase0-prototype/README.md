# Phase 0 — mood-tagging prototype

Answers one question and nothing else: **does an LLM mood tag, mapped to music
parameters, actually match the vibe of the text?**

No UI, no reader app, no audio playback. Read the printed table next to the
source prose and judge whether the tags feel right.

## Setup

```powershell
cd phase0-prototype
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

copy .env.example .env      # then paste your key into .env
```

Get an API key at <https://console.anthropic.com/settings/keys>.

## Run

```powershell
python main.py sample_books\chapter1.txt
```

Add `--reasons` to print the model's one-phrase justification under each row —
that is usually what tells you *why* a tag felt wrong.

The second run on the same file makes **zero API calls**; everything comes from
`mood_cache.json`. Pass `--no-cache` to force a re-classification.

| Flag | Default | What it does |
|---|---|---|
| `--chunk-size N` | 8 | Paragraphs per API call. Lower is more per-paragraph focus, higher is cheaper. |
| `--reasons` | off | Print the model's reason for each tag. |
| `--no-cache` | off | Ignore cached tags and re-call the model. |
| `--cache-file` | `mood_cache.json` | Where tags are stored. |

## What it does

1. **Theme pass** — one call over the whole text → `overall_theme`,
   `instrumentation`, `genre_seed`, plus a `theme_id` derived from the theme
   string so it stays stable across runs.
2. **Mood pass** — paragraphs classified in chunks → `mood`, `intensity`,
   `reason` for each.
3. **Mapper** ([mapper.py](mapper.py)) — mood + intensity + theme → music-API-style
   parameters (genre, mood token, energy, bpm, instrumentation). Nothing calls a
   music service yet; the shape just matches what an adaptive API like Mubert
   takes, so Phase 3 is wiring rather than redesign.

Paragraphs are classified several per call rather than one each. It costs far
less, and it gives the model the surrounding scene — which is most of what mood
continuity depends on. A paragraph that is neutral alone often is not neutral
three paragraphs into a chase.

## Model: Claude Opus 5

Both passes run on `claude-opus-5`. Its request surface shapes
[classify.py](classify.py) in four places:

- **Thinking is on by default.** Omitting the `thinking` parameter runs adaptive
  thinking, which is what we want. `budget_tokens` is rejected with a 400.
  Depth is controlled with `output_config.effort`, set to `high` for the theme
  pass and `low` for the per-paragraph pass.
- **`temperature` / `top_p` are rejected.** Not set anywhere.
- **No assistant prefill.** JSON is pinned with structured outputs
  (`output_config.format`), so the schema guarantees the shape. This is why the
  prompts do not say "respond only with JSON" — that instruction is a leftover
  from the prefill era and is redundant here.
- **Requests can be declined.** Safety classifiers can decline a request, and
  dark prose is a plausible false positive for a mood-tagging app. A decline
  arrives as a *successful* HTTP 200 with `stop_reason == "refusal"`, so
  `.content` is never read before that is checked. Requests opt into a
  server-side fallback (`fallbacks="default"`), which reruns a declined request
  on another model inside the same call. A chunk that is still declined prints
  as `(declined)` rather than killing the run.

### Cost

Opus 5 is $5 / $25 per million input / output tokens. Thinking tokens are billed
at the output rate, which is why the paragraph pass runs at `low` effort.

Estimated from token counts rather than measured: the sample chapter (892 words,
15 paragraphs, 3 calls) runs around **$0.10**. A 100k-word novel at
`--chunk-size 8` lands in the **$5–10** range — most of it thinking tokens on the
paragraph pass.

That is fine for Phase 0, where you are validating one chapter at a time. It
becomes a real number at Phase 3, when opening a book triggers the whole
pipeline. Levers, cheapest first:

- `PARAGRAPH_EFFORT` in [classify.py](classify.py) is already `low`.
- Raise `--chunk-size` — fewer calls, less thinking overhead per paragraph.
- Split the tiers. The theme pass is one genuine judgement call per book; the
  paragraph pass is high-volume routine classification. Running the paragraph
  pass on `claude-sonnet-5` (~$2.50 a novel) or `claude-haiku-4-5` (~$1.30) and
  keeping Opus 5 for the theme call is the obvious shape. Both accept everything
  this code sends, with one caveat: Haiku rejects `output_config.effort`, so
  that key must be dropped there.
- The Batch API halves the price and suits this workload exactly — offline, no
  latency requirement. Worth doing in Phase 2. Note it rejects the `fallbacks`
  parameter, so refusals would need handling client-side.

Model choice is a single `MODEL` constant in [classify.py](classify.py). It is
folded into the cache key, so switching models re-classifies rather than serving
you tags the new model never produced.

## Using your own text

Any UTF-8 `.txt` with blank lines between paragraphs works. For a real
Project Gutenberg chapter:

```powershell
curl https://www.gutenberg.org/files/1342/1342-0.txt -o sample_books\pride.txt
python main.py sample_books\pride.txt
```

Trim the Gutenberg licence header and footer first, or the first few paragraphs
will be tagged as boilerplate.

`sample_books/chapter1.txt` is original prose written for this prototype and
placed in the public domain. It carries a deliberate mood arc — calm morning
routine, then an ominous discovery, a tense peak, a melancholic aftermath, and a
resolve at the end — so there is something to check the tags against.

## Deliberately not here

No UI, no reader app, no Flutter or MAUI, no audio playback, no fine-tuning, no
auth, no error-handling polish. Those are Phases 1 through 5. This is a
throwaway validation script and reads like one.
