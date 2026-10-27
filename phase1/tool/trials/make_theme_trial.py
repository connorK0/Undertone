"""A Kaggle job for the theme trial (SUMMARY 9.42).

Two books whose themes could hardly differ more -- Dracula (Horror) and Alice
(Children's Fantasy) -- and two cues, calm-0 and tense-1, each prompt at three
seeds. Three versions of the prompt:

  A  today's prompt, exactly as generate_beds.prompt_for builds it
  B  per-mood instruments: the book's one instrument palette replaced by the
     theme model's instruments for that mood (mood_instruments.py)
  C  B, with the shared ending lightened: no "Slow ... ambient", no list of
     negations, only "quiet background score for someone reading, no vocals"

Everything else is the arc jobs' settings. The question the result answers:
does book-against-book distance clear seed-against-seed, under each version?
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
CUES = [("calm", 0), ("tense", 1)]
TAKES = 3
SETTINGS = {"model": "facebook/musicgen-stereo-medium", "seconds": 30,
            "tokens_per_second": 50, "guidance": 3.0, "attempts": 4, "seed": 0,
            "batch": 2, "overgen": 1, "register_gate": False,
            "phrasing": "negated"}
LIGHT = "Quiet background score for someone reading, no vocals."
HEAVY = ("Sustained and quiet, no drums, no vocals, no melody, no build-up -- "
         "background score that sits underneath someone reading.")

per_mood = json.loads((TRIAL / "mood_instruments.json").read_text(encoding="utf-8"))


def lighten(prompt: str, mood: str) -> str:
    music_mood = gb.MOOD_PARAMS[mood]["music_mood"]
    shape = music_mood if music_mood == "ambient" else f"{music_mood} ambient"
    old = f"Slow {shape} underscore"
    assert prompt.count(old) == 1 and prompt.count(HEAVY) == 1, prompt
    return (prompt.replace(old, f"{music_mood.capitalize()} underscore")
                  .replace(HEAVY, LIGHT))


sets = []
for name, folder in BOOKS.items():
    theme = json.loads((GEN / folder / "manifest.json").read_text(encoding="utf-8"))["theme"]
    for version in "ABC":
        cues = []
        for mood, band in CUES:
            t = theme if version == "A" else dict(
                theme, instrumentation=per_mood[f"{name}_ch1"][mood])
            prompt = gb.prompt_for(mood, t, band=band)
            if version == "C":
                prompt = lighten(prompt, mood)
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
        sets.append({"dir": f"{name}-{version}", "arc": None, "start": 0, "end": 0,
                     "theme": theme if version == "A" else dict(
                         theme, instrumentation=per_mood[f"{name}_ch1"]),
                     "cues": cues})

job = {"book": "theme-trial",
       "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
       "palette": "trial", "settings": SETTINGS, "sets": sets}
path = TRIAL / "theme-trial.json"
path.write_text(json.dumps(job, indent=1), encoding="utf-8")
print(f"{sum(len(s['cues']) for s in sets)} takes in {len(sets)} sets -> {path}\n")
for s in sets:
    for c in s["cues"]:
        if c["variant"] == 0:
            print(f"{s['dir']:<10}{c['cue']:<8}{c['prompt']}\n")
