"""Phase 0: does an LLM mood tag, mapped to music parameters, match the prose?

    python main.py sample_books/chapter1.txt

Prints one row per paragraph -- text, mood, intensity, mapped music parameters --
so the output can be read next to the source text and sanity-checked. Results
are cached, so a second run on the same file makes no API calls.
"""

import argparse
import os
import re
import sys
from collections import Counter

import anthropic
from dotenv import load_dotenv

import classify
from cache import Cache, book_id, theme_id
from mapper import format_params, map_to_music_params

TEXT_COLUMN_WIDTH = 58


def split_paragraphs(text):
    """Blank-line separated blocks, whitespace collapsed."""
    blocks = re.split(r"\n\s*\n", text)
    return [re.sub(r"\s+", " ", block).strip() for block in blocks if block.strip()]


def truncate(text, width):
    if len(text) <= width:
        return text
    return text[: width - 3].rstrip() + "..."


def print_table(paragraphs, tags, theme, show_reasons):
    header = (
        f"{'#':>3}  {'paragraph':<{TEXT_COLUMN_WIDTH}}  "
        f"{'mood':<11}  {'int':>4}  music params"
    )
    print(header)
    print("-" * len(header))

    for index, paragraph in enumerate(paragraphs):
        tag = tags.get(index)
        if tag is None:
            print(
                f"{index:>3}  {truncate(paragraph, TEXT_COLUMN_WIDTH):<{TEXT_COLUMN_WIDTH}}  "
                f"{'(declined)':<11}  {'':>4}  -"
            )
            continue

        params = map_to_music_params(tag["mood"], tag["intensity"], theme)
        print(
            f"{index:>3}  {truncate(paragraph, TEXT_COLUMN_WIDTH):<{TEXT_COLUMN_WIDTH}}  "
            f"{tag['mood']:<11}  {tag['intensity']:>4.2f}  {format_params(params)}"
        )
        if show_reasons:
            print(f"{'':>3}  -> {tag['reason']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("book", help="Path to a plain-text book or chapter (.txt)")
    parser.add_argument(
        "--chunk-size",
        type=int,
        default=8,
        help="Paragraphs classified per API call (default: 8)",
    )
    parser.add_argument(
        "--reasons", action="store_true", help="Print the model's one-phrase reason per paragraph"
    )
    parser.add_argument(
        "--cache-file", default="mood_cache.json", help="Where to store cached tags"
    )
    parser.add_argument(
        "--no-cache", action="store_true", help="Ignore cached tags and re-call the LLM"
    )
    args = parser.parse_args()

    load_dotenv()
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY is not set. Copy .env.example to .env and fill it in.")

    with open(args.book, encoding="utf-8") as handle:
        text = handle.read()

    paragraphs = split_paragraphs(text)
    if not paragraphs:
        sys.exit(f"No paragraphs found in {args.book}.")

    client = anthropic.Anthropic()
    cache = Cache(args.cache_file, book_id(args.book, text, classify.MODEL))

    # Pass 1: one whole-book theme call.
    theme = None if args.no_cache else cache.get_theme()
    if theme is None:
        print(f"Theme pass on {classify.MODEL}...", file=sys.stderr)
        theme = classify.classify_theme(client, text)
        theme["theme_id"] = theme_id(theme["overall_theme"])
        cache.set_theme(theme)
        cache.save()

    # Pass 2: paragraph moods, in chunks, skipping anything already cached.
    tags = {}
    pending = []
    for index, paragraph in enumerate(paragraphs):
        cached = None if args.no_cache else cache.get_paragraph(index)
        if cached is None:
            pending.append((index, paragraph))
        else:
            tags[index] = cached

    calls = 0
    for start in range(0, len(pending), args.chunk_size):
        chunk = pending[start : start + args.chunk_size]
        indices = [index for index, _ in chunk]
        print(
            f"Mood pass {indices[0]}-{indices[-1]} of {len(paragraphs) - 1}...",
            file=sys.stderr,
        )
        try:
            scored = classify.classify_paragraphs(client, chunk, theme["overall_theme"])
        except classify.RefusalError as error:
            print(f"  paragraphs {indices[0]}-{indices[-1]}: {error}", file=sys.stderr)
            continue
        calls += 1
        for index, tag in scored.items():
            tags[index] = tag
            cache.set_paragraph(index, tag)
        cache.save()

    print()
    print(f"  theme_id        {theme['theme_id']}")
    print(f"  overall_theme   {theme['overall_theme']}")
    print(f"  instrumentation {theme['instrumentation']}")
    print(f"  genre_seed      {theme['genre_seed']}")
    print()

    print_table(paragraphs, tags, theme, args.reasons)

    distribution = Counter(tag["mood"] for tag in tags.values())
    summary = ", ".join(f"{mood} {count}" for mood, count in distribution.most_common())
    print()
    print(f"{len(paragraphs)} paragraphs -- {summary}")
    print(
        f"{len(paragraphs) - len(pending)} from cache, "
        f"{len(pending)} classified in {calls} call(s) to {classify.MODEL}."
    )


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
