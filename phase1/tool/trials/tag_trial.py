"""Does a revised classifier prompt stop tense being the default?

The current prompt (lib/ollama_client.dart, paragraphSystem + paragraphs())
tags 72.8 % of this book's paragraphs tense, including ones whose own reasons
are "clear sky", "Soft hand", "Master's explanation". It gives the model the
eight mood names and nothing about what each is for.

The revision keeps the schema, the batch (24, as tool/allocate.dart) and the
theme line, and adds two things: what the music is for (keeping the reader
absorbed) and what each mood means, with neutral as the default and tense
reserved for danger or conflict happening now.

Baseline is the tags already cached for these chapters: the current prompt's
real output. Writes a JSON of both labels per paragraph for checking by eye.
"""
import collections
import json
import os
import re
import sqlite3
import sys
import time
import urllib.request

APP = os.path.join(os.environ["APPDATA"], "com.example", "reader_shell")
BOOK = "98068df9f6f3e739"
CHAPTERS = [5, 20, 40, 60, 70, 85, 100, 112]  # idx; arc 0 is 0-65, arc 1 66-115
BATCH = 24
MOODS = ["tense", "calm", "melancholic", "triumphant", "romantic", "ominous",
         "whimsical", "neutral"]

SYSTEM = (
    "You are tagging prose paragraph by paragraph for an adaptive music engine. "
    "The tag picks the background music a reader hears under that paragraph, "
    "and the music's job is to keep them absorbed in the book, not to "
    "dramatise every line. Score the feeling the passage actually lands on a "
    "reader, not its plot function or the book's genre. "
    "Intensity is how much the music should assert itself: a quiet dread and a "
    "loud panic can share a mood and differ by half a point of intensity. "
    "Paragraphs arrive in reading order and adjacent ones are usually related; "
    "let a scene build rather than resetting on every paragraph.")

DEFINITIONS = (
    "Moods, most common first:\n"
    "- neutral: the default. Ordinary narration, explanation, dialogue, "
    "planning, travel, training, study, description or reflection with no "
    "strong pull either way. Most paragraphs of most books are neutral.\n"
    "- calm: rest, safety, quiet, peaceful surroundings, gentle moments.\n"
    "- tense: danger, conflict or pressure unfolding right now: a fight, a "
    "chase, a threat being made, a confrontation, a narrow escape, a race "
    "against time. Talking about power, plans, ambition or past and future "
    "battles is not tense, and neither is a serious tone.\n"
    "- ominous: dread or foreboding; a menace not yet acted on; something "
    "wrong.\n"
    "- melancholic: loss, grief, regret, loneliness.\n"
    "- triumphant: victory, a breakthrough, achievement, awe at power gained.\n"
    "- romantic: affection, attraction, intimacy, tenderness.\n"
    "- whimsical: humour, playfulness, absurdity, light banter.\n")

SCHEMA = {
    "type": "object",
    "properties": {"paragraphs": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "index": {"type": "integer", "description": "The paragraph's index from the input"},
            "mood": {"type": "string", "enum": MOODS},
            "intensity": {"type": "number", "description": "0.0 (barely present) to 1.0 (overwhelming)"},
            "reason": {"type": "string", "description": "One short phrase, for debugging"},
        },
        "required": ["index", "mood", "intensity", "reason"],
        "additionalProperties": False}}},
    "required": ["paragraphs"], "additionalProperties": False,
}


def paragraphs_of(raw):
    """Book.fromText, line for line (minParagraphChars = 60)."""
    out, carry = [], ""
    for block in re.split(r"\n\s*\n", raw):
        t = re.sub(r"\s+", " ", block).strip()
        if not t:
            continue
        if len(t) < 60:
            carry = f"{carry} {t}".strip()
            continue
        out.append(f"{carry} {t}".strip())
        carry = ""
    if carry:
        if out:
            out[-1] = f"{out[-1]} {carry}"
        else:
            out.append(carry)
    return out


def classify(numbered, theme):
    blocks = "\n\n".join(f"[{i}]\n{t}" for i, t in numbered)
    user = (f'The book\'s overall theme is "{theme}". Use it for context only; '
            "judge each paragraph on what it actually says.\n\n"
            "Classify each numbered paragraph below. Return one entry per "
            "paragraph, echoing its index.\n\n" + DEFINITIONS +
            "\n- intensity: 0.0-1.0, relative to this book: 0.5 is an ordinary "
            "passage of its mood; keep 0.8 and above for its strongest moments\n"
            "- reason: one short phrase, for debugging only\n\n"
            "--- PARAGRAPHS ---\n" + blocks)
    body = json.dumps({
        "model": "qwen2.5:7b", "stream": False, "format": SCHEMA,
        "options": {"temperature": 0, "num_ctx": 16384},
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        got = json.loads(json.loads(r.read())["message"]["content"])["paragraphs"]
    return {g["index"]: g for g in got}


def main(out_path):
    lib = sqlite3.connect(f"file:{os.path.join(APP, 'library.db')}?mode=ro", uri=True)
    cache = sqlite3.connect(f"file:{os.path.join(APP, 'mood_cache.db')}?mode=ro", uri=True)
    (theme,) = cache.execute("select overall_theme from themes where book_key = ?",
                             (BOOK,)).fetchone()
    rows, started = [], time.time()
    for idx in CHAPTERS:
        (body,) = lib.execute("select body from chapters where book_id = ? and idx = ?",
                              (BOOK, idx)).fetchone()
        paras = paragraphs_of(body)
        old = {i: (m, x, r) for i, m, x, r in cache.execute(
            "select paragraph_index, mood, intensity, reason from tags "
            "where book_key like ? and model = 'qwen2.5:7b'", (f"{BOOK}#{idx}-%",))}
        new = {}
        for at in range(0, len(paras), BATCH):
            new.update(classify([(i, paras[i]) for i in range(at, min(at + BATCH, len(paras)))], theme))
        for i, text in enumerate(paras):
            if i in old and i in new:
                rows.append({"chapter": idx + 1, "paragraph": i, "text": text,
                             "old": old[i], "new": (new[i]["mood"], new[i]["intensity"], new[i]["reason"])})
        print(f"chapter {idx + 1}: {len(paras)} paragraphs, {time.time() - started:.0f} s", flush=True)
    json.dump(rows, open(out_path, "w", encoding="utf-8"), indent=1)

    for which in ("old", "new"):
        c = collections.Counter(r[which][0] for r in rows)
        t = [r[which][1] for r in rows if r[which][0] == "tense"]
        print(f"\n{which}: " + ", ".join(f"{m} {100 * n / len(rows):.0f}%" for m, n in c.most_common()))
        print(f"  tense at 0.65 or more (the peak band): {100 * sum(x >= 0.65 for x in t) / len(rows):.0f}% of paragraphs")
    moved = collections.Counter((r["old"][0], r["new"][0]) for r in rows if r["old"][0] != r["new"][0])
    print("\nchanged:", ", ".join(f"{a}->{b} {n}" for (a, b), n in moved.most_common(10)))
    print(f"{len(rows)} paragraphs compared")


if __name__ == "__main__":
    main(sys.argv[1])
