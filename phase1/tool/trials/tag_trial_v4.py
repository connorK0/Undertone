"""v4 of the paragraph prompt (SUMMARY 9.43): win the minority moods back.

v3, re-tagging arcs 0-1 whole, took tense from 82 % of what sounds to 47 %,
but neutral rose to 51 % and every other mood fell from 11 % to under 3 %:
"use neutral when no other mood fits" became the model's easy answer. This
tries to bring the other moods back.

v4 keeps v3's narrow tense and changes how neutral is reached: pick the mood
that colours the passage even faintly, give a faint one a low intensity rather
than calling it neutral, and keep neutral for passages with no colour at all.
Neutral moves to the end of the list.

    python tool/trials/tag_trial_v4.py <out.json>

Compares against the old cached tags, as tag_trial.py does.
"""
import json
import sys
import urllib.request

import tag_trial

tag_trial.DEFINITIONS = (
    "Moods. Pick the one that colours the passage, even faintly; a faint "
    "mood gets a low intensity rather than being called neutral.\n"
    "- tense: danger, conflict or pressure unfolding right now: a fight, a "
    "chase, a threat being made, a confrontation, a narrow escape, a race "
    "against time, including what characters say in the middle of one. "
    "Talking about power, plans, ambition or past and future battles is not "
    "tense, and neither is a serious tone.\n"
    "- calm: rest, safety, quiet, meditation or routine practice, recovery, "
    "peaceful surroundings, gentle moments.\n"
    "- ominous: dread or foreboding; unease; a menace not yet acted on; "
    "something wrong or unexplained.\n"
    "- melancholic: loss, grief, regret, loneliness, weariness.\n"
    "- triumphant: victory, a breakthrough, achievement, pride, awe at power "
    "gained.\n"
    "- romantic: affection, attraction, intimacy, tenderness, care between "
    "characters.\n"
    "- whimsical: humour, playfulness, absurdity, light banter, curiosity.\n"
    "- neutral: only for passages with no emotional colour at all: rules, "
    "logistics, plain exposition.\n")


def classify(numbered, theme):
    blocks = "\n\n".join(f"[{i}]\n{t}" for i, t in numbered)
    user = (f'The book\'s overall theme is "{theme}". Use it for context only; '
            "judge each paragraph on what it actually says.\n\n"
            "Classify each numbered paragraph below. Return one entry per "
            "paragraph, echoing its index.\n\n" + tag_trial.DEFINITIONS +
            "\n- intensity: 0.0-1.0, relative to this book: 0.2-0.4 for a faint "
            "colour, 0.5 for an ordinary passage of its mood, 0.8 and above "
            "only for its strongest moments\n"
            "- reason: one short phrase, for debugging only\n\n"
            "--- PARAGRAPHS ---\n" + blocks)
    body = json.dumps({
        "model": "qwen2.5:7b", "stream": False, "format": tag_trial.SCHEMA,
        "options": {"temperature": 0, "num_ctx": 16384},
        "messages": [{"role": "system", "content": tag_trial.SYSTEM},
                     {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", data=body,
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        got = json.loads(json.loads(r.read())["message"]["content"])["paragraphs"]
    return {g["index"]: g for g in got}


if __name__ == "__main__":
    tag_trial.classify = classify
    tag_trial.main(sys.argv[1])
