"""The two LLM passes: one whole-book theme pass, then paragraph moods.

Both passes run on Claude Opus 5. A few of its API rules shape this file:

  * Thinking is on by default. Omitting the `thinking` parameter runs adaptive
    thinking, which is what we want; `budget_tokens` is rejected with a 400.
    Depth is controlled with `output_config.effort` instead.
  * `temperature` / `top_p` / `top_k` are rejected.
  * Assistant prefill is rejected, so JSON is pinned with structured outputs
    (`output_config.format`) instead of a "reply with JSON only" instruction.
  * Safety classifiers can decline a request, which arrives as a successful
    HTTP 200 with `stop_reason == "refusal"`. Never read `.content` first.
"""

import json

MODEL = "claude-opus-5"

# Thinking tokens count against max_tokens, so these sit far above what the
# JSON itself needs. Truncating mid-thought wastes the whole call.
THEME_MAX_TOKENS = 16000
PARAGRAPH_MAX_TOKENS = 8000

# Effort is the primary cost/latency dial. The theme pass is one judgement
# call per book and worth paying for; the paragraph pass is the high-volume
# routine one, where low effort classifies perfectly well.
THEME_EFFORT = "high"
PARAGRAPH_EFFORT = "low"

# Dark prose is exactly the kind of input that can trip a false positive on
# the safety classifiers, so requests opt into a server-side fallback: on a
# policy decline the API reruns the request on another model in the same call.
FALLBACK_BETA = "server-side-fallback-2026-07-01"

# Whole chapters fit comfortably in the 1M context; this guards whole books.
MAX_THEME_CHARS = 40000

MOODS = [
    "tense",
    "calm",
    "melancholic",
    "triumphant",
    "romantic",
    "ominous",
    "whimsical",
    "neutral",
]

THEME_SCHEMA = {
    "type": "object",
    "properties": {
        "overall_theme": {
            "type": "string",
            "description": "2-4 word description of the general tone/genre for a musical score",
        },
        "instrumentation": {
            "type": "string",
            "description": 'Suggested instrument palette, e.g. "solo piano, sparse strings"',
        },
        "genre_seed": {
            "type": "string",
            "description": "Short genre/style token suitable for an adaptive music API",
        },
    },
    "required": ["overall_theme", "instrumentation", "genre_seed"],
    "additionalProperties": False,
}

PARAGRAPH_SCHEMA = {
    "type": "object",
    "properties": {
        "paragraphs": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "index": {
                        "type": "integer",
                        "description": "The paragraph index given in the input",
                    },
                    "mood": {"type": "string", "enum": MOODS},
                    "intensity": {
                        "type": "number",
                        "description": "0.0 (barely present) to 1.0 (overwhelming)",
                    },
                    "reason": {
                        "type": "string",
                        "description": "One short phrase, for debugging only",
                    },
                },
                "required": ["index", "mood", "intensity", "reason"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["paragraphs"],
    "additionalProperties": False,
}

THEME_SYSTEM = (
    "You are scoring a book for an adaptive music engine, the way a composer "
    "reads a script before writing a cue sheet. Judge the prose as written, "
    "not the subject matter in the abstract."
)

PARAGRAPH_SYSTEM = (
    "You are tagging prose paragraph by paragraph for an adaptive music engine. "
    "The tag drives what a reader hears while they are reading that paragraph, "
    "so score the feeling the passage lands on a reader, not its plot function. "
    "Intensity is how much the music should assert itself: a quiet dread and a "
    "loud panic can share a mood and differ by half a point of intensity. "
    "Paragraphs arrive in reading order and adjacent ones are usually related -- "
    "let a scene build rather than resetting each paragraph in isolation."
)


class RefusalError(RuntimeError):
    """The safety classifiers declined the request, and the fallback declined too."""


def _call(client, *, system, user, schema, effort, max_tokens):
    """One structured-output request. Returns the parsed JSON object."""
    response = client.beta.messages.create(
        model=MODEL,
        max_tokens=max_tokens,
        betas=[FALLBACK_BETA],
        fallbacks="default",
        system=system,
        output_config={
            "effort": effort,
            "format": {"type": "json_schema", "schema": schema},
        },
        messages=[{"role": "user", "content": user}],
    )

    # Check this before touching .content -- on a refusal it is empty.
    if response.stop_reason == "refusal":
        category = getattr(response.stop_details, "category", None)
        raise RefusalError(f"declined (category: {category})")

    text = next(block.text for block in response.content if block.type == "text")
    return json.loads(text)


def classify_theme(client, book_text):
    """One call per book: the overall palette every paragraph is scored against."""
    excerpt = book_text[:MAX_THEME_CHARS]
    user = (
        "Identify the musical character of this book from the following excerpt.\n\n"
        "- overall_theme: 2-4 word description of the general tone/genre for a musical score\n"
        "- instrumentation: a suggested instrument palette\n"
        "- genre_seed: a short genre/style token suitable for an adaptive music API\n\n"
        "--- EXCERPT ---\n" + excerpt
    )
    return _call(
        client,
        system=THEME_SYSTEM,
        user=user,
        schema=THEME_SCHEMA,
        effort=THEME_EFFORT,
        max_tokens=THEME_MAX_TOKENS,
    )


def classify_paragraphs(client, numbered_paragraphs, overall_theme):
    """Score a chunk of paragraphs. `numbered_paragraphs` is [(index, text), ...].

    Returns {index: {"mood", "intensity", "reason"}}. Several paragraphs go in
    one call: it costs far less than one call each, and it gives the model the
    surrounding scene, which is most of what mood continuity depends on.
    """
    blocks = "\n\n".join(
        f"[{index}]\n{text}" for index, text in numbered_paragraphs
    )
    user = (
        f'The book\'s overall theme is "{overall_theme}".\n\n'
        "Classify each numbered paragraph below. Return one entry per paragraph, "
        "echoing its index.\n\n"
        f"- mood: one of {', '.join(MOODS)}\n"
        "- intensity: 0.0-1.0\n"
        "- reason: one short phrase, for debugging only\n\n"
        "--- PARAGRAPHS ---\n" + blocks
    )
    result = _call(
        client,
        system=PARAGRAPH_SYSTEM,
        user=user,
        schema=PARAGRAPH_SCHEMA,
        effort=PARAGRAPH_EFFORT,
        max_tokens=PARAGRAPH_MAX_TOKENS,
    )

    tagged = {}
    for entry in result["paragraphs"]:
        tagged[entry["index"]] = {
            "mood": entry["mood"],
            "intensity": max(0.0, min(1.0, float(entry["intensity"]))),
            "reason": entry["reason"],
        }
    return tagged
