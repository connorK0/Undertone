"""Per-mood instruments, as a theme call: the theme model names specific
instruments for each mood of a book, instead of one palette for the whole book.

Same model, system prompt and options as the app's theme pass
(lib/ollama_client.dart: themeSystem, temperature 0, num_ctx 16384, first
40,000 characters). Only the request and the schema differ.
"""
import json
import pathlib
import sys
import urllib.request

ASSETS = pathlib.Path(__file__).resolve().parents[2] / "assets" / "books"
MOODS = ["calm", "melancholic", "neutral", "ominous", "romantic", "tense",
         "triumphant", "whimsical"]
SYSTEM = ("You are scoring a book for an adaptive music engine, the way a composer "
          "reads a script before writing a cue sheet. Judge the prose as written, "
          "not the subject matter in the abstract.")
SCHEMA = {
    "type": "object",
    "properties": {m: {"type": "string",
                       "description": f"2-5 specific named instruments for {m} "
                                      "passages in this book's score"}
                   for m in MOODS},
    "required": MOODS,
    "additionalProperties": False,
}


def ask(excerpt: str) -> dict:
    user = ("Identify the musical character of this book from the following "
            "excerpt, then decide its instruments mood by mood. The score is "
            "quiet background music heard while reading.\n\n"
            "For each mood, name the specific instruments this book's score "
            "would use for it: real, named instruments (for example \"cello and "
            "celesta\", not \"strings\"), chosen for this book's setting and "
            "period, and suited to that mood.\n\n"
            "--- EXCERPT ---\n" + excerpt[:40000])
    body = json.dumps({
        "model": "qwen2.5:7b", "stream": False, "format": SCHEMA,
        "options": {"temperature": 0, "num_ctx": 16384},
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(json.loads(r.read())["message"]["content"])


if __name__ == "__main__":
    out = {}
    for book in ("dracula_ch1", "alice_ch1"):
        text = (ASSETS / f"{book}.txt").read_text(encoding="utf-8")
        out[book] = ask(text)
        print(book, json.dumps(out[book], indent=1), flush=True)
    pathlib.Path(sys.argv[1]).write_text(json.dumps(out, indent=1), encoding="utf-8")
