"""How far along is the classifier?

    python tool/progress.py <bookId> [--arc N] [--watch]

Reads the mood cache directly, so it works against a run started from anywhere
-- a background job, another terminal, the app itself -- and needs nothing from
the process it is watching.

Counts twice a few seconds apart to get a rate, because the useful question
while a forty-minute job is running is not "how many" but "how much longer".
"""

import argparse
import json
import os
import sqlite3
import sys
import time

SUPPORT = os.path.join(os.environ.get("APPDATA", ""), "com.example",
                       "reader_shell")

# The model column of a current tag: lib/ollama_client.dart's tagModel. Tags
# under an older prompt version stay in the file and must not be counted.
TAG_MODEL = "qwen2.5:7b tags-v2"


def arc_range(book: str, arc: int):
    """(start, end) chapter indices for an arc, or None for the whole book."""
    path = os.path.join(SUPPORT, "generated", book, "arcs.json")
    if arc < 0 or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        arcs = json.load(f).get("arcs", [])
    for entry in arcs:
        if entry.get("index") == arc:
            return entry["start"], entry["end"]
    return None


def expected(book: str, arc: int):
    """Paragraphs this arc had when it was last counted, if we know."""
    path = os.path.join(SUPPORT, "generated", book, "allocation.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for entry in data.get("sets", []):
        if arc in entry.get("arcs", []):
            return entry.get("observations")
    return data.get("whole", {}).get("observations")


def count(book: str, span) -> tuple[int, int]:
    """(paragraphs tagged, chapters touched) inside the span."""
    db = os.path.join(SUPPORT, "mood_cache.db")
    rows = sqlite3.connect(f"file:{db}?mode=ro", uri=True).execute(
        "SELECT book_key, COUNT(*) FROM tags WHERE book_key LIKE ? "
        "AND model = ? GROUP BY book_key", (f"{book}#%", TAG_MODEL)).fetchall()
    total = 0
    chapters = 0
    for key, n in rows:
        # <book>#<idx>-<hash>
        try:
            index = int(key[len(book) + 1:].split("-", 1)[0])
        except ValueError:
            continue
        if span and not (span[0] <= index <= span[1]):
            continue
        total += n
        chapters += 1
    return total, chapters


def line(book: str, arc: int, span, target, first, started) -> str:
    total, chapters = count(book, span)
    where = f"arc {arc}" if span else "the whole book"
    of_chapters = f"{chapters}" + (f" of {span[1] - span[0] + 1}" if span else "")
    out = f"{total} paragraphs across {of_chapters} chapters in {where}"
    if target:
        out += f"  ({total * 100 // target}% of {target})"

    elapsed = time.time() - started
    done = total - first
    if elapsed > 1 and done > 0:
        rate = done / elapsed
        out += f"  - {rate:.2f}/s"
        if target and total < target:
            left = (target - total) / rate
            out += f", about {int(left // 60)}m{int(left % 60):02d}s left"
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Classifier progress.")
    parser.add_argument("book")
    parser.add_argument("--arc", type=int, default=-1)
    parser.add_argument("--watch", action="store_true",
                        help="keep printing until interrupted")
    parser.add_argument("--every", type=float, default=10.0,
                        help="seconds between lines when watching")
    args = parser.parse_args()

    if not os.path.exists(os.path.join(SUPPORT, "mood_cache.db")):
        sys.exit(f"no mood cache under {SUPPORT}")

    span = arc_range(args.book, args.arc)
    if args.arc >= 0 and span is None:
        sys.exit(f"no arc {args.arc} in this book's cut")
    target = expected(args.book, args.arc)

    first, _ = count(args.book, span)
    started = time.time()
    print(line(args.book, args.arc, span, target, first, started), flush=True)
    if not args.watch:
        return
    try:
        while True:
            time.sleep(args.every)
            print(line(args.book, args.arc, span, target, first, started),
                  flush=True)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
