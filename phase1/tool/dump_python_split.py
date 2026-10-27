"""Regenerate test/python_split.json, the fixture split_parity_test.dart checks.

The classifier keys tags by paragraph index, and phase0's Python splitter is
where those indices were validated. This dumps what it produces so the Dart
splitter can be pinned to it.

    phase0/.venv/Scripts/python.exe phase1/tool/dump_python_split.py

Run from the repository root.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "phase0"))

from main import split_paragraphs  # noqa: E402  (needs the path above)

BOOKS = [
    "chapter1.txt",
    "dracula_ch1.txt",
    "christmas_carol_stave1.txt",
    "alice_ch1.txt",
]

# Read the app's own copies rather than phase0/sample_books: the later chapters
# only exist here, and these are the exact bytes the reader loads.
SOURCE = ROOT / "phase1" / "assets" / "books"


def main():
    out = {}
    for name in BOOKS:
        text = (SOURCE / name).read_text(encoding="utf-8")
        out[name] = split_paragraphs(text)
        print(f"{name}: {len(out[name])} paragraphs")

    target = ROOT / "phase1" / "test" / "python_split.json"
    target.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
