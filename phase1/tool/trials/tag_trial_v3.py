"""tag_trial.py's revision, after reading what it changed.

v2 took tense from 61 % to 22 % on the eight chapters, but sent neutral to
69 % and calm to 0 %: "Most paragraphs of most books are neutral" pushed too
hard. By eye, its tense -> neutral moves were mostly right (explanations,
introductions, following orders), but it also moved a call to arms in the
middle of a fight, and meditation and rest went from calm to neutral.

v3: no claim about what most paragraphs are; neutral is for when nothing
else fits; calm names rest, meditation and routine practice; tense keeps the
dialogue spoken inside a fight.
"""
import sys

import tag_trial

tag_trial.DEFINITIONS = (
    "Moods:\n"
    "- neutral: ordinary narration, explanation, dialogue, planning, travel or "
    "description with no particular pull; use it when no other mood fits.\n"
    "- calm: rest, safety, quiet, meditation or routine practice, peaceful "
    "surroundings, gentle moments.\n"
    "- tense: danger, conflict or pressure unfolding right now: a fight, a "
    "chase, a threat being made, a confrontation, a narrow escape, a race "
    "against time, including what characters say in the middle of one. "
    "Talking about power, plans, ambition or past and future battles is not "
    "tense, and neither is a serious tone.\n"
    "- ominous: dread or foreboding; a menace not yet acted on; something "
    "wrong.\n"
    "- melancholic: loss, grief, regret, loneliness.\n"
    "- triumphant: victory, a breakthrough, achievement, awe at power gained.\n"
    "- romantic: affection, attraction, intimacy, tenderness.\n"
    "- whimsical: humour, playfulness, absurdity, light banter.\n")

if __name__ == "__main__":
    tag_trial.main(sys.argv[1])
