"""The second theme trial (SUMMARY 9.42). In the first, the books and the
moods both sounded different, C was a little too busy, and C's Dracula
tense-1 screeched; and the score should not keep a reader on edge the whole
time.

The book line is today's again: B showed that it carries the book's identity.
Versions, each at three seeds, Dracula and Alice:

  A  today's prompt, for tense-0 only (trial 1 has A's calm-0 and tense-1).
     tense-0 is the bed under 35 % of this book's reading.
  D  today's prompt with the ending softened rather than removed: "Slow" and
     "Sustained and quiet" stay, "ambient" and the negations go, except "no
     vocals". C lost both; this asks which half was flattening the moods and
     which half was keeping the beds calm.
  E  D, with tense written for momentum instead of fear: "suspense" becomes
     "focused" and "percussive attacks" becomes "steady forward momentum".
     The peak band's height phrase stays, so the band step is unchanged.
"""
import datetime
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import generate_beds as gb  # noqa: E402

GEN = pathlib.Path(os.environ["APPDATA"]) / "com.example" / "reader_shell" / "generated"
TRIAL = GEN / "_theme-trial"
BOOKS = {"dracula": "sample-dracula_ch1", "alice": "sample-alice_ch1"}
PLAN = {"A": [("tense", 0)],
        "D": [("calm", 0), ("tense", 0), ("tense", 1)],
        "E": [("tense", 0), ("tense", 1)]}
TAKES = 3
SETTINGS = json.loads((TRIAL / "theme-trial.json").read_text(encoding="utf-8"))["settings"]
HEAVY = ("Sustained and quiet, no drums, no vocals, no melody, no build-up -- "
         "background score that sits underneath someone reading.")
SOFT = "Sustained and quiet background score for someone reading, no vocals."


def soften(prompt: str, mood: str) -> str:
    music_mood = gb.MOOD_PARAMS[mood]["music_mood"]
    shape = music_mood if music_mood == "ambient" else f"{music_mood} ambient"
    old = f"Slow {shape} underscore"
    assert prompt.count(old) == 1 and prompt.count(HEAVY) == 1, prompt
    return (prompt.replace(old, f"Slow {music_mood} underscore")
                  .replace(HEAVY, SOFT))


def momentum(prompt: str) -> str:
    for old, new in (("pulsing low strings, percussive attacks",
                      "pulsing low strings, steady forward momentum"),
                     ("Slow suspense underscore", "Slow focused underscore")):
        assert prompt.count(old) == 1, prompt
        prompt = prompt.replace(old, new)
    return prompt


sets = []
for name, folder in BOOKS.items():
    theme = json.loads((GEN / folder / "manifest.json").read_text(encoding="utf-8"))["theme"]
    for version, plan in PLAN.items():
        cues = []
        for mood, band in plan:
            prompt = gb.prompt_for(mood, theme, band=band)
            if version in "DE":
                prompt = soften(prompt, mood)
            if version == "E":
                prompt = momentum(prompt)
            for variant in range(TAKES):
                cue = f"{mood}-{band}"
                cues.append({
                    "stem": cue if variant == 0 else f"{cue}-v{variant}",
                    "cue": cue, "variant": variant, "keep": TAKES, "mood": mood,
                    "band": band, "band_name": gb.BAND_NAMES[band],
                    "seed_base": gb.seed_base(SETTINGS["seed"], band, variant,
                                              SETTINGS["attempts"]),
                    "key": f"{gb.tonic_for(theme)} {gb.MOOD_MODE.get(mood, 'minor')}",
                    "prompt": prompt,
                })
        sets.append({"dir": f"{name}-{version}", "arc": None, "start": 0,
                     "end": 0, "theme": theme, "cues": cues})

job = {"book": "theme-trial-2",
       "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
       "palette": "trial", "settings": SETTINGS, "sets": sets}
path = TRIAL / "theme-trial-2.json"
path.write_text(json.dumps(job, indent=1), encoding="utf-8")
print(f"{sum(len(s['cues']) for s in sets)} takes in {len(sets)} sets -> {path}\n")
for s in sets:
    if s["dir"].startswith("alice"):
        continue
    for c in s["cues"]:
        if c["variant"] == 0:
            print(f"{s['dir']:<10}{c['cue']:<8}{c['prompt']}\n")
