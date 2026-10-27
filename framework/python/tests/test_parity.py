"""The extracted generation code, pinned to its originals while they exist.

Run: python framework/python/tests/test_parity.py

music_book_gen.prompts was cut verbatim out of phase1/tool/generate_beds.py,
and MOOD_PARAMS vendored from phase0/mapper.py. Two copies drift the moment
one is edited, and a drifted prompt is a different bed -- silently, since
nothing about a bed says which prompt made it. So while the originals are in
the repository, every prompt the framework can build must be byte-for-byte
the one the reader app's generator builds, over every mood, band and flag.
When phase1 is retired this test has nothing to compare with and says so.
"""

import importlib.util
import itertools
import sys
from pathlib import Path

FRAMEWORK = Path(__file__).resolve().parents[1]
REPO = FRAMEWORK.parents[1]
sys.path.insert(0, str(FRAMEWORK))
from music_book_gen import prompts  # noqa: E402

ORIGINAL = REPO / "phase1" / "tool" / "generate_beds.py"
MAPPER = REPO / "phase0" / "mapper.py"


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


THEMES = [
    {"genre_seed": "action-drama", "overall_theme": "Drama and Action",
     "instrumentation": "Orchestral with a focus on brass and percussion",
     "key_seed": "98068df9f6f3e739#arc0"},
    # No key_seed: the tonic falls back to the theme text.
    {"genre_seed": "gothic", "overall_theme": "Victorian Horror",
     "instrumentation": "low strings, organ"},
]

FLAGS = ["register_hint", "positive_only", "with_key", "mood_constraint",
         "mood_first", "book_first"]


def main() -> None:
    if not ORIGINAL.exists() or not MAPPER.exists():
        print("skipped: phase1/phase0 originals are not in this checkout")
        return
    gb = load(ORIGINAL, "_original_generate_beds")
    mapper = load(MAPPER, "_original_mapper")

    assert prompts.MOOD_PARAMS == mapper.MOOD_PARAMS
    print("  ok  MOOD_PARAMS is phase0/mapper.py's")

    compared = 0
    for mood, band, theme in itertools.product(
            sorted(prompts.MOOD_PARAMS), [None, 0, 1], THEMES):
        for values in itertools.product([False, True], repeat=len(FLAGS)):
            flags = dict(zip(FLAGS, values))
            ours = prompts.prompt_for(mood, theme, band=band, **flags)
            theirs = gb.prompt_for(mood, theme, band=band, **flags)
            assert ours == theirs, (mood, band, flags, ours, theirs)
            compared += 1
    print(f"  ok  {compared} prompts identical to generate_beds.prompt_for")

    for theme in THEMES:
        assert prompts.tonic_for(theme) == gb.tonic_for(theme)
    for seed, band, variant, attempts in itertools.product(
            [0, 7], [None, 0, 1], range(40), [1, 4]):
        assert (prompts.seed_base(seed, band, variant, attempts)
                == gb.seed_base(seed, band, variant, attempts))
    plan = {"tense-1": 13, "tense-0": 11, "calm-0": 1, "ominous-1": 1,
            "romantic-0": 1}
    for overgen in (1, 2, 3):
        assert (prompts.slots_for(sorted(prompts.MOOD_PARAMS), "full", plan,
                                  overgen=overgen)
                == gb.slots_for(sorted(gb.MOOD_PARAMS), "full", plan,
                                overgen=overgen))
    for report in ({"usable": True, "centroid_hz": 431.0},
                   {"usable": False, "centroid_hz": 93.0},
                   {"usable": True, "centroid_hz": None}):
        assert prompts.guard_rank(report) == gb.guard_rank(report)
    assert prompts.cues_for(["tense"], "full") == gb.cues_for(["tense"],
                                                                "full")
    print("  ok  tonics, seeds, slots, guard rank and cues match")
    print("all passed")


if __name__ == "__main__":
    main()
