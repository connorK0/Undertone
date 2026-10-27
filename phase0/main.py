"""Phase 0: does an LLM mood tag, mapped to music parameters, match the prose?

    python main.py sample_books/chapter1.txt
    python main.py sample_books/chapter1.txt --model local --reasons

One row per paragraph: text, mood, intensity, mapped music parameters. Tags are
cached per book and per model, so a second run with the same --model makes no
LLM calls, and switching --model re-classifies rather than reusing another
model's tags.
"""

import argparse
import re
import sys
from collections import Counter

from dotenv import load_dotenv

import classify
from cache import Cache, book_key, theme_id
from mapper import MOOD_PARAMS, format_params, map_to_music_params

TEXT_WIDTH = 58
MIN_PARAGRAPH_CHARS = 60


def split_paragraphs(text):
    """Blank-line separated blocks, internal whitespace collapsed.

    Headings, scene breaks and letter sign-offs arrive as their own tiny blocks
    and carry no mood of their own, so anything shorter than MIN_PARAGRAPH_CHARS
    is folded into the paragraph that follows it (or the last one, at the end).
    """
    blocks = [re.sub(r"\s+", " ", block).strip() for block in re.split(r"\n\s*\n", text)]
    paragraphs = []
    carry = ""
    for block in blocks:
        if not block:
            continue
        if len(block) < MIN_PARAGRAPH_CHARS:
            carry = f"{carry} {block}".strip()
            continue
        paragraphs.append(f"{carry} {block}".strip())
        carry = ""
    if carry:
        if paragraphs:
            paragraphs[-1] = f"{paragraphs[-1]} {carry}"
        else:
            paragraphs.append(carry)
    return paragraphs


def truncate(text, width):
    if len(text) <= width:
        return text
    return text[: width - 3].rstrip() + "..."


def print_table(paragraphs, tags, theme, show_reasons):
    header = f"{'#':>3}  {'paragraph':<{TEXT_WIDTH}}  {'mood':<11}  {'int':>4}  music params"
    print(header)
    print("-" * len(header))

    for index, paragraph in enumerate(paragraphs):
        text = truncate(paragraph, TEXT_WIDTH)
        tag = tags.get(index)
        if tag is None:
            print(f"{index:>3}  {text:<{TEXT_WIDTH}}  {'(untagged)':<11}  {'':>4}  -")
            continue

        if tag["mood"] in MOOD_PARAMS:
            params = format_params(map_to_music_params(tag["mood"], tag["intensity"], theme))
        else:
            # A model wandered off the taxonomy despite the schema. Show it.
            params = "(off-taxonomy mood, no mapping)"
        print(f"{index:>3}  {text:<{TEXT_WIDTH}}  {tag['mood']:<11}  {tag['intensity']:>4.2f}  {params}")
        if show_reasons:
            print(f"{'':>3}  -> {tag['reason']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("book", help="Path to a plain-text book or chapter (.txt)")
    parser.add_argument(
        "--model",
        choices=classify.BACKENDS,
        default="opus",
        help="Which model classifies: opus (default, quality baseline), haiku (cheap), local (Ollama, free)",
    )
    parser.add_argument(
        "--chunk-size", type=int, default=6, help="Paragraphs per classification call (default: 6)"
    )
    parser.add_argument("--reasons", action="store_true", help="Print the model's reason under each row")
    parser.add_argument("--no-cache", action="store_true", help="Ignore cached tags and re-call the model")
    parser.add_argument("--cache-file", default="mood_cache.json", help="Where tags are stored")
    args = parser.parse_args()

    load_dotenv()
    problem = classify.preflight(args.model)
    if problem:
        sys.exit(problem)

    with open(args.book, encoding="utf-8") as handle:
        text = handle.read()
    paragraphs = split_paragraphs(text)
    if not paragraphs:
        sys.exit(f"No paragraphs found in {args.book}.")

    model = classify.model_id(args.model)
    client = classify.make_client(args.model)
    cache = Cache(args.cache_file, book_key(args.book, text), model)

    # Pass 1: one theme call per book.
    theme = None if args.no_cache else cache.get_theme()
    if theme is None:
        print(f"Theme pass on {model}...", file=sys.stderr)
        try:
            theme = classify.classify_theme(args.model, client, text)
        except classify.Refusal as why:
            sys.exit(f"Theme pass declined: {why}")
        theme["theme_id"] = theme_id(theme["overall_theme"])
        cache.set_theme(theme)
        cache.save()

    # Pass 2: paragraph moods, several per call, skipping anything cached.
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
        first, last = chunk[0][0], chunk[-1][0]
        print(f"Mood pass, paragraphs {first}-{last} of {len(paragraphs) - 1}...", file=sys.stderr)
        try:
            scored = classify.classify_paragraphs(args.model, client, chunk, theme["overall_theme"])
        except classify.Refusal as why:
            print(f"  paragraphs {first}-{last} declined: {why}", file=sys.stderr)
            continue
        calls += 1
        for index, _ in chunk:
            if index in scored:
                tags[index] = scored[index]
                cache.set_paragraph(index, scored[index])
        cache.save()

    print()
    print(f"  model           {model}")
    print(f"  theme_id        {theme['theme_id']}")
    print(f"  overall_theme   {theme['overall_theme']}")
    print(f"  instrumentation {theme['instrumentation']}")
    print(f"  genre_seed      {theme['genre_seed']}")
    print()
    print_table(paragraphs, tags, theme, args.reasons)

    distribution = Counter(tag["mood"] for tag in tags.values())
    summary = ", ".join(f"{mood} {count}" for mood, count in distribution.most_common())
    untagged = len(paragraphs) - len(tags)
    print()
    print(f"{len(paragraphs)} paragraphs -- {summary}" + (f" -- {untagged} untagged" if untagged else ""))
    print(f"{len(paragraphs) - len(pending)} from cache, {len(pending)} sent to {model} in {calls} call(s).")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
