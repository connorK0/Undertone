# Reader shell + mood pipeline + adaptive score (phases 1–4)

A Windows reader that classifies the mood of what you're reading, as you read
it, using a local model, and plays a bed of music that follows it. Phase 1
built the shell and proved the trigger fires exactly once per navigation
action. Phase 2 replaced the stub behind that trigger with a real pipeline: two
Ollama passes, a prefetch window, and a SQLite cache. Phase 3 turned those tags
into sound — a mapper, eight looping beds, and crossfades. Phase 4 made it a
reader you can put your own books in: ePub import, a library, saved position,
and settings.

Built in **Flutter** (see *Why Flutter* below).

> **Read this before judging the music.** Classifying the same eighteen
> paragraphs of *Dracula* three times — same model, same prose, only a change
> to the theme string in the prompt — agrees on about **70%** of moods. Which
> paragraph gets which label is not stable. Widening the smoothing window does
> not improve that at any width from one to eight, because the disagreement is
> not per-paragraph noise — the model differs about whole passages, since it
> classifies them in batches with shared context. The cache pins a book once
> tagged, so a given book sounds the same every time you open it; clear it and
> you get a materially different score. That is the ceiling this local
> classifier puts on the idea, and no amount of audio work moves it.
>
> How much the theme string matters **depends on the book**, which took two
> experiments to see. On *Dracula* it moves individual labels but not the
> distribution — dark moods are 8–9 of 18 whatever theme you supply, because
> the text admits no other reading. On stave I of the *Carol* it moves the
> distribution a lot: 28 of 36 paragraphs come back dark under the derived
> "Grim and Haunted", **27 of 36 under no theme at all**, but only 18 of 36
> under "Warm Victorian Christmas". So the theme is close to inert on
> unambiguous prose and acts as a tiebreaker on ambiguous prose — and stave I
> is ambiguous, holding Fred's warmth and the charity collectors alongside the
> cold. The model's own unprompted reading is the dark one, and it is right:
> the Christmas everyone remembers is staves III–V.

## Requires Developer Mode

Phase 2 added plugins (`sqflite_common_ffi`, `path_provider`), and Flutter on
Windows needs symlink support to build a project with plugins:

```powershell
start ms-settings:developers    # turn on Developer Mode, then:
flutter run -d windows
```

Without it, `flutter build windows` and `flutter run` both stop with
"Building with plugins requires symlink support". The pipeline itself does not
care — `flutter test` and `flutter test test_live/` run on the Dart VM and work
either way.

## Run it

If the Flutter SDK is not on your `PATH`, either add its `bin` folder to
your user `PATH`, or prefix the commands below with that path.

```powershell
cd phase1
flutter run -d windows            # builds and launches, prints the hook log
```

Or run the already-built binary directly:

```powershell
.\build\windows\x64\runner\Debug\reader_shell.exe
```

Two sample chapters are bundled (menu-book icon, top right): the short
original mood-arc chapter and chapter 1 of *Dracula*. The **Pages / Scroll**
toggle switches reading mode. The banner along the bottom shows the last
trigger, so the hook's behaviour is visible without a console.

## The pipeline

[lib/mood_pipeline.dart](lib/mood_pipeline.dart) turns positions into tags.

- **Theme pass** — one call per book, before anything else, because the
  paragraph prompt quotes the theme. Cached, so it happens once ever.
- **Paragraph pass** — batches of 6, covering a window 8 paragraphs ahead of
  the reader. Calls run **one at a time**: two concurrent requests to a 7B
  model on one GPU make both slower, not the pair faster.
- **Re-prioritising** — the next batch is chosen when the previous finishes,
  from wherever the reader is *by then*. Skipping to chapter's end doesn't
  wait for stale work to drain.
- **No duplicate work** — an in-flight set means hammering page-turn during a
  call adds nothing.
- **Cache** — [lib/mood_cache.dart](lib/mood_cache.dart), SQLite, keyed by
  book (file stem + content hash) and model. Editing a chapter starts fresh
  rather than serving tags written against the old wording.
- **Ollama down** — one banner state, no retry storm. Reading is never gated
  on the pipeline; the next trigger tries again. Note the pipeline only
  discovers an outage when it actually needs to classify: if the window ahead
  is already tagged it has no reason to call, and stays quiet.
- **A hung endpoint costs one timeout.** Because calls are serial, a request
  that neither answers nor fails blocks every later batch until
  `ollamaTimeout` (45s) expires, with the banner stuck on "Classifying...".
  That bound is the whole defence, which is why it isn't set to something
  generous. Seen for real: a second connection attempt to a closed port is
  not always refused promptly the way the first one is.

[lib/ollama_client.dart](lib/ollama_client.dart) talks to
`http://localhost:11434/api/chat` directly, with the JSON schema in `format`.
Prompts and schemas are ported from `phase0/classify.py` unchanged.

## Books and the library

The app opens on a shelf. **Add ePub** imports a file, scores its opening
chapter there and then, and puts it on the shelf with its cover; tapping a book
opens it where you left off. Position is saved on every trigger rather than on
the way out, so closing the window keeps your place. Removing a book takes its
cached tags with it. The four bundled chapters are seeded on first run and are
ordinary one-chapter books afterwards.

[lib/epub.dart](lib/epub.dart) takes chapters from the book's **own navigation
document** rather than guessing, because navigation entries point at
`file#anchor` and one XHTML document usually holds many chapters — *Pride and
Prejudice* is 61 chapters across 16 files, so splitting per file would give
sixteen twenty-minute "chapters". Three things the real Gutenberg fixtures
caught, none of which a synthetic ePub would have:

- **navPoints nest, and the nested ones are not chapters.** *A Christmas Carol*
  lists its Leech illustrations as children of the staves they appear in, so
  following them cut every stave in half. Only direct children of `navMap` are
  chapters.
- **The last chapter has no entry after it**, so it ran to the end of the book
  and swallowed the Project Gutenberg licence — Alice's chapter XII came out
  with the whole legal text attached, ready to be classified as prose.
- **Anchors on container elements were dropped**, since only leaf blocks
  recorded their ids, and most books put chapter boundaries on a wrapping
  `section` or `div`. Alice masked this by having one file per chapter.

Front matter is told from prose by shape rather than by title: a contents page
averages 18 characters per block where a chapter runs 300–500.

[lib/library.dart](lib/library.dart) is a **separate database** from the mood
cache. The library is the reader's own data and losing it loses their books;
the cache is derived and costs only time to rebuild, so it can be cleared — for
a model change, say — without touching the library. A book's id is a hash of
its bytes, so importing the same file twice is the same book.

**Chapters of one book share a theme.** `Book` gained `themeKey` and
`themeText`: the theme is cached under the book id rather than the chapter key,
and the theme pass reads a book-wide sample rather than whichever chapter is
open. Without that a sixty-chapter novel would pay for sixty theme passes and
get sixty different themes — and since the theme is quoted in every paragraph
prompt, the book would drift in register as you read it.

## The music

A book is **prepared before it opens**. Choosing a chapter runs the theme pass
and the first batch of paragraphs behind a progress screen
([lib/preparation.dart](lib/preparation.dart)), and only then builds the
reader — so page one arrives with music already fading in rather than fifteen
seconds of silence. A cached book prepares instantly. If Ollama is down,
preparation gives up and opens the book anyway, silent: never a spinner trap.

The chain is `onMoodTrigger` → pipeline tag → mapper → cue selector → engine.

- **[lib/music_params.dart](lib/music_params.dart)** — a port of
  `phase0/mapper.py`: each mood owns a tempo range and an energy floor, and the
  paragraph's intensity slides across them. Pinned to the Python original over
  every mood at every hundredth of intensity by
  [test/mapper_parity_test.dart](test/mapper_parity_test.dart). Two rounding
  traps had to be handled to make that pass, both documented in the file —
  Python rounds half-to-even on the *exact* binary value, so `x * 100` and
  `.round()` are both wrong.
- **[lib/cue_selector.dart](lib/cue_selector.dart)** — decides what should be
  playing. Two rules: the cue is the dominant mood of a four-paragraph window
  (not the paragraph under your eye), and once chosen it holds for at least 15s
  and needs two separate paragraphs to argue it away. Pure logic, no audio, so
  it is tested headless.
- **[lib/music_engine.dart](lib/music_engine.dart)** — `flutter_soloud`. Starts
  every cue at silence and fades it up; on a change both beds sound at once,
  one rising as the other falls over 2.5s, and the outgoing one is stopped only
  after its fade finishes. Within a mood, intensity ramps both loudness *and*
  brightness over 1.5s, with no crossfade. If the audio device does not come
  up, everything becomes a no-op and the app reads on in silence.

### Why intensity drives a filter

Because mood barely moves, and the phase nearly shipped a score that was one
held chord. Over stave I of the Carol the cue changes 16 times in 127
paragraphs but sits on `tense` for **56 of them** — about 37 minutes of reading.
Dracula holds one cue for 27 paragraphs, Alice for 20.

That is not a tuning error. Sweeping the window weighting, width and
confirmation count against the real tag sequences, *no setting fixes it*:
everything that shortens those stretches also starts firing on isolated
one-paragraph moods (`confirmations: 1` gives 44–64 changes on the Carol but
33–61 spike hits). The books genuinely have a dominant register and the
classifier reports it faithfully.

What does move is intensity — within that 56-paragraph `tense` stretch it
swings 0.30 to 1.00. The mapper turns that entire range into **3.1 dB** of
volume, which is why it was inaudible as movement. So intensity now also drives
a low-pass cutoff, exponentially from 320 Hz to 5 kHz: measured, the same range
sweeps the filter **1265 → 3311 Hz** against 2.8 dB of gain. A large
perceptual change at nearly constant loudness is what a long stretch on one cue
needs.

`flutter test test_live/cue_timeline_test.dart` prints the whole cue timeline
for every bundled chapter, so this is checkable without reading for 40 minutes.

### The loops

Two libraries, switched by one line in
[lib/music_library.dart](lib/music_library.dart). Both are described by a
`manifest.json` that the app reads at runtime, so the swap is not a code change.

**`assets/music/` — generated (the default).** Eight beds written by
[tool/make_loops.py](tool/make_loops.py), standard library only. Every partial
and every LFO completes a whole number of cycles in the 24-second loop, so the
loop point is mathematically continuous: the measured step at the wrap is
*smaller* than the largest ordinary sample-to-sample step inside the loop
(ratios 0.78–0.93, recorded per file in the manifest). All eight are normalised
to the same RMS, so a crossfade is not also a volume change. Slow harmonic
pads, no melody and no percussion — music under prose has to survive being
ignored, and a tune competes with the reader's inner voice.

**They also have to survive a laptop speaker.** The first version of these beds
did not, and the result was an app that played correctly and made no sound:
roots ran 55–147 Hz with partials no higher than 4×, which left `tense`,
`ominous` and `neutral` with *zero* energy above 200 Hz, and every bed with zero
above 500 Hz. Built-in speakers roll off hard below ~200 Hz, so the cue that
plays for most of Dracula was inaudible by construction. Every bed now carries
partials out to 4–6× its root, and `make_loops.py` refuses to render a set where
any bed has less than 15% of its energy above 200 Hz — the current spread is
21–100%, recorded per file in the manifest. On headphones the low fundamentals
are still there; the upper partials are what make it work without them.

**`assets/music/licensed/` — CC0/CC-BY from OpenGameArt.** Fetched by
[tool/fetch_licensed_loops.py](tool/fetch_licensed_loops.py), which checks the
licence each page actually declares rather than trusting a search filter — it
refused *Her Violet Eyes* for being CC-BY-SA. Six CC0, two CC-BY 3.0, with
credit lines in the manifest. Real music, and it decodes and plays
(`integration_test/music_test.dart` proves it), but it is **not** the default:
this machine has no ffmpeg and no numpy, so none of it could be auditioned,
loop-checked or level-matched, and a set of eight tracks by six composers at
unknown levels is exactly what makes crossfades lurch.

### What the loops honestly cannot do

The mapper emits `bpm`, `genre_seed` and `instrumentation`. **A fixed loop
library honours none of them** — you cannot retempo a loop without
time-stretching it, and one library cannot re-voice itself per book. The
parameters are still carried, because they are the shape an adaptive music API
would take.

So the theme pass reaches your ears only *indirectly*, and it would be easy to
conclude from that it is dead weight worth cutting from the 15s cold start.
It is not: it is quoted in every paragraph prompt, and on a book whose mood is
genuinely arguable that changes which loop plays for whole stretches — see the
*Carol* numbers above. Its influence is real; it just arrives through the tags
rather than through `bpm`.

### One label, several kinds of ominous

`ominous` was rendered as a **tritone stack** — partial ratios of √2, described
in the source as "a low drone with a tritone shadow". The tritone is
*diabolus in musica*, the most horror-coded interval in Western music, so every
paragraph the classifier called ominous came out sounding like a horror film.

That is too specific a thing to say, and the cached tags show why. All of these
carry the same label:

| what the model actually said | |
| --- | --- |
| *Alice's fall into the well* | a child down a rabbit hole |
| *Scrooge's cold, calculating tone* | social menace |
| *describes historical disasters and sieges* | weight, not threat |
| *Count Dracula's letter with mysterious instructions* | anticipation |
| *hideous clanking in the night* | actually horror |
| *Phantoms and chains* | actually horror |

Only the last two want a tritone. Most of what "ominous" means in a score is an
intense stretch where something bad *could* happen — dread, not menace. So the
bed is now deliberately **less** specific: root and fifth for mass, a minor
third for colour, and one unresolved voice a semitone above the upper fifth
(352 Hz against 330 Hz) that beats rather than bites. Same register, same
audibility (22.3% above 200 Hz, unchanged), no tritone.

**The real fix is a second axis, and the app already computes it.** The theme
pass produces a `genre_seed` — "Horror" for *Dracula*, "Children's Fantasy" for
*Alice*, "Victorian Gothic" for the *Carol* — and nothing consumes it. Ominous
in a children's fantasy and ominous in *Dracula* should not be the same sound,
and the book already knows which it is. That is a per-*book* choice rather than
a per-paragraph one, so it costs one voicing per book rather than more assets
per mood, and it lands naturally in the per-book generation job.

Note what this is **not**: an argument for more mood labels. Splitting
`ominous` into dread/foreboding/menacing would ask a classifier that is already
only ~70% reproducible across eight labels to hold a finer distinction steady,
and would multiply the library. Keep the vocabulary coarse and vary the voicing
by book-level context, which is stable.

This is the third time this phase that the missing signal turned out to be
something already computed and thrown away — after the classifier's `reason`
and the runner-up mood. That is starting to look like the pattern rather than a
coincidence.

## Generated music, per book

`tool/generate_beds.py` writes a book its own eight beds with a local music
model (MusicGen, on the GPU that already runs Ollama). `tool/loopify.py` turns
what comes out into something the engine can actually use.

This exists because every book played **the same eight files** — *Dracula* and
*Alice in Wonderland* were byte-identical on disk. The theme pass has always
worked out that one is "Horror. Strings, Horns, Harps, Timpani, Choir" and the
other "Children's Fantasy. Piano, Violin, Cello, Flute, Clarinet, Harp", and
nothing consumed either. The prompt for each bed is assembled from exactly that,
plus the mood's own tempo range and texture — `phase0/mapper.py` is *imported*
rather than transcribed, since the Dart port is already pinned to it by a parity
test and a third copy would be a third thing to keep in step.

### What a model gives you, and what it does not

A generated clip is not a bed. It starts and ends wherever it likes, at whatever
loudness it likes, with no guarantee its energy is anywhere a laptop speaker can
reproduce. `loopify.py` fixes the first two by measurement — equal-power tail
fold to close the wrap, RMS normalise to the same level as the synthesised beds
— and **rejects** on the third.

That guard paid for itself on the first generation ever run. Dracula's `ominous`
bed came back with **0.3% of its energy above 200 Hz**: inaudible, and precisely
the Phase 3 mistake. Alice's came back at 99.1%.

### Prompt wording lost to re-seeding, and I had it backwards

The obvious fix was to tell the model to stay out of the sub-bass. Measured, on
Dracula's `ominous`:

| prompt | seed | above 200 Hz |
| --- | --- | --- |
| plain | 0 | 0.3% — rejected |
| plain | 1 | **99.7%** |
| + "middle register, no sub-bass" | 0 | 4.9% — rejected |
| + "middle register, no sub-bass" | 1 | 0.3% — rejected |

The hint made it **worse**. Two things follow. The variance is dominated by the
seed, not the wording. And MusicGen has no negative prompting, so "no sub-bass"
is a conditioning signal *for* sub-bass — which casts real doubt on the rest of
the prompt's negations ("no drums, no vocals, no melody"), hence
`--positive-only` to test them.

So the mechanism is not prompt engineering, it is **rejection sampling**:
generate, measure, reject, re-seed. `--attempts` bounds it. The guard is cheap
and the model is stochastic, so this is the honest way round.

### The guard has to be two-sided

The audibility floor alone is not enough, and getting that wrong nearly shipped
a worse bed than the one it rejected. Dracula's `ominous`, with only a floor:

| seed | above 200 Hz | centroid | verdict |
| --- | --- | --- | --- |
| 0 | 0.3% | 73 Hz | rejected — inaudible |
| 1 | 99.7% | **2940 Hz** | *accepted* — and it is a horror drone with no weight at all |

Trading "cannot be heard" for "has no body" is not progress. So brightness is
checked from both ends, using the spectral centroid — one number for how bright
a bed is. With the ceiling in place the same mood carries on to something
actually usable:

| seed | above 200 Hz | centroid | verdict |
| --- | --- | --- | --- |
| 0 | 0.3% | 73 Hz | too quiet to hear |
| 1 | 99.7% | 2940 Hz | no body, all top end |
| 2 | 13.3% | 146 Hz | too quiet to hear |
| 3 | **24.8%** | **184 Hz** | kept |

Four attempts, about four and a half minutes, for one bed of one book. If
nothing passes within `--attempts`, the nearest miss is kept rather than
whichever came last.

### Where the failures actually land

They are not spread evenly, and the pattern is the point. Generating all eight
beds for both books, first attempt:

| book | rejected first time |
| --- | --- |
| *Dracula* — Horror; Strings, Horns, Harps, Timpani, Choir | **3 of 8** (ominous, tense, triumphant) |
| *Alice* — Children's Fantasy; Piano, Violin, Cello, Flute, Clarinet, Harp | **0 of 8** |

Horror instrumentation plus the mapper's "low drones" texture walks straight
into the sub-bass; a children's-fantasy palette sits naturally above 200 Hz.
The books whose genre matters most are the ones that need the retries.

And they do come out different. Spectral centroid per mood:

| mood | *Dracula* | *Alice* |
| --- | --- | --- |
| calm | 164 Hz | 788 Hz |
| melancholic | 183 Hz | 615 Hz |
| triumphant | 842 Hz | 500 Hz |
| whimsical | 493 Hz | 384 Hz |

Which is the whole point: they were previously the same bytes.

### Cost

About 70s per 30-second attempt on an RTX 4060, plus ~50s to load the model
cold and ~8s warm. A book of eight beds lands around 10–15 minutes depending on
how many get rejected. That is a background job at import, not something to make
a reader wait for.

The raw model output is kept beside each processed bed as `<mood>.raw.wav` — the
only way to hear what the processing did, and the only way to tell a bad
generation from a bad loop-fix.

### small vs medium

`--model facebook/musicgen-stereo-medium` is the bigger model. Both generated
all eight *Dracula* beds from identical prompts and seeds.

| | small | medium |
| --- | --- | --- |
| attempts for 8 beds | **11** | **15** |
| rejected by the guard | 3 | 7 |
| per attempt | ~66s | ~127s |
| wall clock | ~12 min | ~32 min |
| VRAM | ~2 GB | **6.7 GB** |

Three measurable differences, all consistent across moods:

- **medium is darker.** Spectral centroid falls on six of eight moods —
  whimsical 493 → 168 Hz, triumphant 842 → 202 Hz. This is also *why* it needs
  more retries: leaning low fights the audibility floor.
- **medium is more tonal.** Spectral flatness (near 0 tonal, near 1 noise) drops
  where small was noisiest: whimsical 0.0030 → 0.0002, triumphant 0.0013 →
  0.0001. Less hiss, more pitch.
- **medium is wider.** Stereo decorrelation rises on five of eight —
  melancholic 0.51 → 0.99, ominous 0.83 → 1.17.

The VRAM number is the operational one. 6.7 GB of an 8 GB card means medium
**cannot share the GPU with Ollama** (qwen2.5:7b wants ~5 GB), so generation and
classification have to take turns. small fits alongside it and does not.

### Playing them in the app

Settings -> Loops -> **Per book**. Generated beds live under the app's support
directory (`%APPDATA%/com.example/reader_shell/generated/<book id>/`), not in
the asset bundle, because there is a different set for every book. `--install
<book id>` writes them straight there. Note the app's ids are not the tool's: a
seeded chapter is `sample-dracula_ch1`.

The reader loads the right set *before* preparation preloads the opening cue,
or the first page would fade in on the previous book's music. A book with no
generated set falls back to the shipped one rather than playing nothing --
anything imported before generation existed has none, and silence would be a
worse answer than the shared beds.

This is the only path that uses SoLoud's `loadFile` rather than `loadAsset`,
and `integration_test/music_test.dart` is the only place it is exercised. That
test skips rather than fails when nothing has been generated, since a fresh
checkout has no reason to have spent half an hour of GPU time.

### The question this now makes answerable

Everything about the beds has been judged by auditioning them on their own, and
that is the wrong test. `make_loops.py` has claimed since Phase 3 that *"music
under prose has to survive being ignored: melody competes with the reader's
inner voice"*, and the generation prompt still asks for "no melody, no
build-up". **Nobody has ever checked that while reading.**

The medium model was chosen for having more individuality --
more simultaneous instruments and more movement, which the measurements agree
with (spectral movement 0.50 synthesised, 0.92 small, 1.01 medium; strong
partials 6, 14, 15). But more interesting to audition and better to read over
are different properties, and possibly opposite ones. That is now a half-hour
test rather than a design argument.


## The hook

[lib/mood_trigger.dart](lib/mood_trigger.dart) — `onMoodTrigger(ReadingPosition)`.
One function, one call site per mode. It records the trigger and hands the
position to the pipeline. It fires:

- once when a book is opened (or the mode is switched — that's a fresh reader);
- **Pages mode**: once per page turn — arrow keys, PageUp/PageDown, Space, the
  chevron buttons, or tapping the left/right half of the page. A *held* key
  auto-repeats at the OS level; those repeat events are ignored, so holding
  Right turns one page, not thirty.
- **Scroll mode**: once per *settled* scroll — 400ms (`settleDelay` in
  [lib/reading_style.dart](lib/reading_style.dart)) after the last scroll
  event, whatever produced it: drag, fling momentum, or mouse-wheel ticks.
  Nothing fires while the text is still moving.

Every firing prints one line, and the pipeline prints what it does about it:

```
[mood] #14 paragraph 27 (scroll, scroll settled)
[pipeline] classifying 27-32 (6 paragraphs)...
[pipeline] tagged 27-32 in 8.5s: ominous, ominous, tense, tense, tense, tense
```

`ReadingPosition` carries the paragraph index the pipeline classifies, the
mode, the reason, and in Pages mode the page number.

### How the position is found

- **Pages**: the paragraph containing the first character on the page.
- **Scroll**: the paragraph a third of the way down the viewport. On a
  scrolling page the eyes sit in the upper part of the screen and the reader
  scrolls when they near the bottom, so that's a better proxy than dead
  centre — which also misreports the top of a chapter, where a short heading
  pushes the centre onto paragraph three before anything's been read. This is
  a heuristic; Phase 4 (edge cases) is where it gets tuned by feel.

## Seeing what it is doing

[lib/inspector_panel.dart](lib/inspector_panel.dart) — the chart icon in the
reader's app bar. Beside the text on a window 900px or wider, full width below
that, because a cramped column of prose next to a cramped column of numbers is
worse than either alone.

There is a lot of machinery between a paragraph and a sound — classify, smooth
over a window, confirm, wait out a dwell, map, pick a loop, crossfade, sweep a
filter — and until this the only views onto it were a one-line banner and the
debug console. Both answer *what is playing*. Neither answers the question that
actually comes up while reading, which is **why that, and why now**.

So the panel shows the chain in the order the decision is made:

| section | what it answers |
| --- | --- |
| Book | the theme, which is quoted in every paragraph prompt and so sits upstream of every tag |
| Classifier | status, position, tagged/total, what is in flight, and the model's own `reason` for this paragraph |
| Cue selection | the four-paragraph window with its weights, what it came to, and what the selector is waiting for |
| Music | what the score **chose**, what is **sounding**, the branch it came down, the file, and the manifest's own record of that loop |
| Cue changes | every change so far this chapter, with the mood behind it |

Two of those deserve a note.

**"Chose" and "sounding" are different rows on purpose.** With music switched
off, no audio device, or a doze in progress, the score is still making
decisions — and that is exactly when you want to see them. The panel is useful
in silence.

**The waiting states are the point.** A new mood counting towards a change
(`considering tense (1 of 2 paragraphs)`) and a dwell not yet satisfied
(`dwell blocks a change for 8s`) are the reason the music *isn't* moving, and
nothing else in the app ever said so.

The `reason` field is worth singling out: the classifier has returned one since
Phase 1 and it has been cached, ignored and never shown to anyone. It is the
clearest evidence of whether a tag is defensible — *"poking out the spark
symbolizes extinguishing hope"* tells you far more than `ominous 0.70` does.

Read-only, and it polls the audio engine at 500ms only while it is open, so
having it up cannot be the reason a session behaved differently.

## Pagination

[lib/page_reader.dart](lib/page_reader.dart) lays the whole chapter out once
with `TextPainter`, walks the line metrics, and cuts a page wherever the next
line would overflow. Each page is a character range starting at a line
boundary, so rendering the substring alone wraps exactly as it did in the full
layout. Resizing the window re-paginates and keeps your place.

## Tests

```powershell
flutter test                              # 58 tests, ~8s, no Ollama, no audio
flutter test test_live/                   # real Ollama, ~70s

# Real app build; needs Developer Mode. One file per invocation -- see below.
flutter test integration_test/app_test.dart -d windows
flutter test integration_test/music_test.dart -d windows
flutter test integration_test/live_app_test.dart -d windows
flutter test integration_test/reading_with_music_test.dart -d windows
```

**Run the integration tests one file at a time.** `flutter test integration_test
-d windows` runs the first file and then fails every later one at launch with
*"Error waiting for a debug connection … Unable to start the app on the
device"* — Flutter cannot start a second Windows app in one invocation. That is
a harness limitation, not a failure of the tests; each file passes on its own.
Watch the exit code rather than the tail of the output, too: piping the run
through `grep` replaces `flutter`'s exit status with `grep`'s, which reported
success for a run in which three files had failed.

**`app_test`'s fling assertion is the suite's canary for the reading tree.**
Adding the inspector made it fail about half the time — 15 triggers where 14
were expected — while `master` passed 4 of 4. The cause was not the panel but
the `LayoutBuilder` originally wrapped around the reader *unconditionally*:
deferring the child's build to layout is enough to move when scroll
notifications land, and since the settle timer fires 400ms after the last one,
a ballistic tail that goes quiet for four of `pumpAndSettle`'s 100ms steps
settles twice. The fix was to keep the reading tree byte-identical when the
inspector is closed.

Two things worth keeping from that. First, **the assertion is doing real work**
— it caught a change nothing else noticed, so treat a fling failure as a signal
rather than a flake. Second, a first re-run passed, which nearly ended the
investigation early; it took four runs a side to see 2/4 against 4/4. One green
run does not clear a flaky test.

If a build stops with `LNK1168: cannot open reader_shell.exe for writing`, an
app from an earlier run is still holding the binary — and one that has the audio
device open can survive both `Stop-Process -Force` and `taskkill /F`, which
reports "no running instance" while the process is still listed. What does work:

```powershell
(Get-Process -Id <pid>).Kill()
```

`flutter test` is headless, so the engine reports unavailable there and every
audio call no-ops — which means the default run also exercises the
no-sound-device path. The audio itself is checked on the real Windows build:

- `integration_test/music_test.dart` — the device comes up, all eight generated
  loops decode and play, the licensed set loads, and a mood change is measurably
  a *fade* rather than a cut (incoming voice at 0.16 climbing to 0.74, two
  voices sounding during, one after). No Ollama needed.
- `integration_test/reading_with_music_test.dart` — the whole thing: a cold
  *Dracula* prepares in ~14s, the reader opens with music already sounding
  (0ms), and 40 page turns in 2.6s across six distinct moods produce **zero**
  crossfades. The cue-change bound is derived from the dwell rather than
  hardcoded, so it measures the rule and not how fast the classifier ran today.

`flutter test` covers the pipeline against a fake Ollama (theme-before-
paragraphs, batching, the in-flight guard, cache hits making zero calls,
re-prioritisation mid-call, and Ollama being down), the trigger timing from
Phase 1, and `split_parity_test.dart`, which pins the Dart paragraph splitter
byte-for-byte to `phase0/main.py`'s against a fixture regenerated by
[tool/dump_python_split.py](tool/dump_python_split.py).

`test_live/` hits the real model and measures it — cold start, whether tags
are ready when the reader arrives, and that a second pass makes no calls. It
writes `build/live_report.txt` with the whole chapter's tags to read against
the prose.

## Why Flutter

The two criteria were "which makes the iOS port less painful" and "which has
better audio-plugin support for Phase 3's adaptive crossfading."

- **iOS**: both frameworks need a Mac with Xcode to build for iOS, so no
  tooling advantage either way. Flutter's is the more mature cross-platform
  story: one widget tree renders identically on Windows and iOS, versus
  MAUI mapping to native controls per platform with the seams that implies.
- **Audio**: decisive. Flutter has `just_audio`, `media_kit` and
  `flutter_soloud`, all with Windows and iOS backends; `flutter_soloud` does
  real mixing, which is what a crossfade between two mood streams wants.
  MAUI's `Plugin.Maui.Audio` is basic playback.
- **Text layout**: `TextPainter` exposes line metrics, which is what makes
  the pagination above ~40 lines instead of a project. MAUI has no
  equivalent.

Cost of the choice: the Windows toolchain is heavier (Visual Studio Build
Tools with the C++ workload, ~4GB) and this machine had none of it, so setup
was most of the wall-clock time. That's paid now.

## Not here, on purpose

No PDF — a different and much worse problem than ePub. No cloud music API, no
cloud models (Ollama only), no text-to-speech, highlights or sync, no iOS build.
The Windows project was generated with `--platforms=windows`; adding iOS later
is `flutter create --platforms=ios .` in this directory.

**No automatic ducking**, and this one is a real gap rather than a choice.
Getting out of the way of other audio means knowing when something else is
playing, which on Windows is WASAPI audio-session enumeration
(`IAudioSessionManager2`). That is native code; `flutter_soloud` does not expose
it and no Dart package covers Windows. It would need a small platform channel.
The volume slider and the on/off switch cover the manual case in the meantime.

**Skimming needed no new machinery.** The concern was that flicking through
pages would queue a batch per page. It does not, and now there is a test
saying so: calls run one at a time and the next batch is chosen when the
previous finishes, from wherever the reader has got to — 49 rapid turns produce
at most four batches, and the work lands on the page they stopped at.
