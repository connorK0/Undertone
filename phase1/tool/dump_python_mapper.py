"""Regenerate test/python_mapper.json, the fixture mapper_parity_test.dart checks.

lib/music_params.dart is a port of phase0/mapper.py. The numbers in it decide
what a reader hears, and a silent drift between the two would be invisible --
the app would still play something, just not what Phase 0 validated. This dumps
Python's output over every mood and a dense intensity sweep so the Dart port can
be pinned to it.

    phase0/.venv/Scripts/python.exe phase1/tool/dump_python_mapper.py

Run from the repository root.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "phase0"))

from mapper import MOOD_PARAMS, map_to_music_params  # noqa: E402

# A real theme, so instrumentation concatenation and theme_id pass-through are
# covered too, not just the arithmetic.
THEME = {
    "genre_seed": "gothic-orchestral",
    "instrumentation": "low strings, distant choir, prepared piano",
    "theme_id": "mystery-and-gothic-4f2a1c",
}


def main():
    cases = []
    for mood in MOOD_PARAMS:
        # Every hundredth, so any rounding boundary that exists is hit.
        for step in range(0, 101):
            intensity = step / 100
            cases.append(
                {
                    "mood": mood,
                    "intensity": intensity,
                    "expected": map_to_music_params(mood, intensity, THEME),
                }
            )

    target = ROOT / "phase1" / "test" / "python_mapper.json"
    target.write_text(
        json.dumps({"theme": THEME, "cases": cases}, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"{len(cases)} cases over {len(MOOD_PARAMS)} moods")
    print(f"wrote {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
