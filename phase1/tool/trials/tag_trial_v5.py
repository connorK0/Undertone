"""v5 of the paragraph prompt (SUMMARY 9.43).

v4 won back some minority moods (20 % -> 10 % under v3 -> 15 % on the eight
chapters), but partly out of tense rather than neutral: tense rose from 37 %
to 45 %. Its "a faint mood gets a low intensity rather than being called
neutral" turned faint tension into tense 0.5, so a chapter of rules and
arrivals went back to tense. v5 is v4 with one rule more: tense is never
faint. If nothing is happening yet it is ominous or neutral.

    python tool/trials/tag_trial_v5.py <out.json>
"""
import sys

import tag_trial
import tag_trial_v4

tag_trial.DEFINITIONS = tag_trial_v4.tag_trial.DEFINITIONS.replace(
    "Talking about power, plans, ambition or past and future battles is not "
    "tense, and neither is a serious tone.\n",
    "Talking about power, plans, ambition or past and future battles is not "
    "tense, and neither is a serious tone. Tense is never faint: if nothing is "
    "happening yet, it is ominous or neutral.\n")
assert "Tense is never faint" in tag_trial.DEFINITIONS

if __name__ == "__main__":
    tag_trial.classify = tag_trial_v4.classify
    tag_trial.main(sys.argv[1])
