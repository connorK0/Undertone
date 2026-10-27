"""The two LLM passes -- one whole-book theme pass, then paragraph moods -- on
any of three backends, chosen by name:

    opus   claude-opus-5 on the Anthropic API. The quality baseline.
    haiku  claude-haiku-4-5 on the Anthropic API. Cheap tier, same account.
    local  An Ollama model on this machine. Free, offline, no key.

All three get the same prompts and return the same JSON shape, so their tags
can be read side by side. Each has its own request function because the
request bodies genuinely differ; there is no shared abstraction to fight.
"""

import json
import os

import anthropic
import ollama

BACKENDS = ("opus", "haiku", "local")

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

# --- Anthropic backends -----------------------------------------------------

OPUS_MODEL = "claude-opus-5"
HAIKU_MODEL = "claude-haiku-4-5"

# Opus 5 thinks by default -- `thinking` is omitted, which runs adaptive
# thinking -- and thinking tokens count against max_tokens, so these sit well
# above what the JSON needs. Effort is the cost dial: the theme pass is one
# call per book, the paragraph pass is the high-volume one.
OPUS_MAX_TOKENS = {"theme": 16000, "paragraphs": 8000}
OPUS_EFFORT = {"theme": "high", "paragraphs": "low"}

# Opus 5's safety classifiers can decline a request, and dark prose is exactly
# the input that trips a false positive. The request opts into a server-side
# fallback: a declined request is rerun on another model inside the same call.
FALLBACK_BETA = "server-side-fallback-2026-07-01"

# Haiku 4.5 does not think unless asked and rejects `output_config.effort`, so
# its request is the plain one: model, schema, prompt.
HAIKU_MAX_TOKENS = 4096

# --- Local backend ----------------------------------------------------------

DEFAULT_LOCAL_MODEL = "qwen2.5:7b"

# Ollama silently truncates the prompt to the model's context window, and its
# default is small (2048 tokens on many models). A chapter runs 8-10k tokens,
# so the theme pass needs headroom. 16k of KV cache fits beside a 7B Q4 model
# in 8GB of VRAM.
LOCAL_NUM_CTX = 16384

# A chapter fits any of these models' context; this guards whole books.
MAX_THEME_CHARS = 40000

# --- Shared prompts and schemas --------------------------------------------

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
                    "index": {"type": "integer", "description": "The paragraph's index from the input"},
                    "mood": {"type": "string", "enum": MOODS},
                    "intensity": {
                        "type": "number",
                        "description": "0.0 (barely present) to 1.0 (overwhelming)",
                    },
                    "reason": {"type": "string", "description": "One short phrase, for debugging"},
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
    "The tag drives what a reader hears while reading that paragraph, so score "
    "the feeling the passage lands on a reader, not its plot function. "
    "Intensity is how much the music should assert itself: a quiet dread and a "
    "loud panic can share a mood and differ by half a point of intensity. "
    "Paragraphs arrive in reading order and adjacent ones are usually related; "
    "let a scene build rather than resetting on every paragraph."
)


class Refusal(RuntimeError):
    """A hosted model's safety classifiers declined the request."""


# --- Backend selection ------------------------------------------------------


def local_model():
    # Read at call time so a value in .env, loaded after import, is honoured.
    return os.environ.get("OLLAMA_MODEL", DEFAULT_LOCAL_MODEL)


def model_id(name):
    """The concrete model behind a backend name. The cache is keyed on this."""
    return {"opus": OPUS_MODEL, "haiku": HAIKU_MODEL}.get(name) or f"ollama:{local_model()}"


def make_client(name):
    """An Anthropic client for the hosted backends; the local one needs none."""
    return anthropic.Anthropic() if name in ("opus", "haiku") else None


def preflight(name):
    """Why this backend can't run right now, or None if it can."""
    if name in ("opus", "haiku"):
        if os.environ.get("ANTHROPIC_API_KEY"):
            return None
        return "ANTHROPIC_API_KEY is not set. Copy .env.example to .env and fill it in."

    model = local_model()
    try:
        ollama.show(model)
    except ConnectionError:
        return "Ollama isn't running. Launch the Ollama app (or run `ollama serve`) and try again."
    except ollama.ResponseError:
        return f"Ollama doesn't have '{model}' yet. Run: ollama pull {model}"
    return None


# --- The three request shapes ----------------------------------------------


def _request_opus(client, system, user, schema, pass_kind):
    response = client.beta.messages.create(
        model=OPUS_MODEL,
        max_tokens=OPUS_MAX_TOKENS[pass_kind],
        betas=[FALLBACK_BETA],
        fallbacks="default",
        system=system,
        output_config={
            "effort": OPUS_EFFORT[pass_kind],
            "format": {"type": "json_schema", "schema": schema},
        },
        messages=[{"role": "user", "content": user}],
    )
    return _parse_anthropic(response)


def _request_haiku(client, system, user, schema, pass_kind):
    response = client.messages.create(
        model=HAIKU_MODEL,
        max_tokens=HAIKU_MAX_TOKENS,
        system=system,
        output_config={"format": {"type": "json_schema", "schema": schema}},
        messages=[{"role": "user", "content": user}],
    )
    return _parse_anthropic(response)


def _parse_anthropic(response):
    # Check this before touching .content: on a refusal it is empty or partial.
    if response.stop_reason == "refusal":
        category = getattr(response.stop_details, "category", None)
        raise Refusal(f"category {category}")
    text = next(block.text for block in response.content if block.type == "text")
    return json.loads(text)


def _request_local(client, system, user, schema, pass_kind):
    response = ollama.chat(
        model=local_model(),
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        format=schema,
        options={"temperature": 0, "num_ctx": LOCAL_NUM_CTX},
    )
    return json.loads(response.message.content)


REQUEST = {"opus": _request_opus, "haiku": _request_haiku, "local": _request_local}


# --- The two passes ---------------------------------------------------------


def classify_theme(name, client, book_text):
    """One call per book: the palette every paragraph is scored against."""
    user = (
        "Identify the musical character of this book from the following excerpt.\n\n"
        "- overall_theme: 2-4 word description of the general tone/genre for a musical score\n"
        "- instrumentation: a suggested instrument palette\n"
        "- genre_seed: a short genre/style token suitable for an adaptive music API\n\n"
        "--- EXCERPT ---\n" + book_text[:MAX_THEME_CHARS]
    )
    return REQUEST[name](client, THEME_SYSTEM, user, THEME_SCHEMA, "theme")


def classify_paragraphs(name, client, numbered_paragraphs, overall_theme):
    """Score a chunk of paragraphs. `numbered_paragraphs` is [(index, text), ...].

    Returns {index: {"mood", "intensity", "reason"}}. Several paragraphs go in
    one call: it costs far less than one each, and it gives the model the
    surrounding scene, which is most of what mood continuity depends on.
    """
    blocks = "\n\n".join(f"[{index}]\n{text}" for index, text in numbered_paragraphs)
    user = (
        f'The book\'s overall theme is "{overall_theme}".\n\n'
        "Classify each numbered paragraph below. Return one entry per paragraph, "
        "echoing its index.\n\n"
        f"- mood: one of {', '.join(MOODS)}\n"
        "- intensity: 0.0-1.0\n"
        "- reason: one short phrase, for debugging only\n\n"
        "--- PARAGRAPHS ---\n" + blocks
    )
    result = REQUEST[name](client, PARAGRAPH_SYSTEM, user, PARAGRAPH_SCHEMA, "paragraphs")

    tagged = {}
    for entry in result["paragraphs"]:
        tagged[entry["index"]] = {
            "mood": entry["mood"],
            "intensity": max(0.0, min(1.0, float(entry["intensity"]))),
            "reason": entry["reason"],
        }
    return tagged
