"""A workspace's plan as a job: which sets, which takes, which seeds, and no
book text.

Run: python framework/python/tests/test_export.py

The workspace is written by hand in the shapes FORMAT.md gives, which is also
the check that this side reads the contract the Dart side writes.
"""

import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from music_book_gen import jobs, prompts  # noqa: E402
from music_book_gen.workspace import Workspace  # noqa: E402

# A sentence that occurs in the book and nowhere else. If it ever turns up in
# a job, book text is leaving the machine.
SENTINEL = "Mirren pressed the brass key into the lock of the Halvard lighthouse"


def make_workspace(root: Path) -> Workspace:
    root.mkdir(parents=True)

    def write(name, json_value):
        (root / name).write_text(json.dumps(json_value), encoding="utf-8")

    write("workspace.json", {"format": 1, "book": "0123456789abcdef",
                             "title": "Test"})
    write("chapters.json", [{"index": i, "title": f"Chapter {i + 1} - "
                             f"{SENTINEL}", "paragraphs": [SENTINEL]}
                            for i in range(30)])
    write("arcs.json", {"arcs": [
        {"index": 0, "start": 0, "end": 9, "title": SENTINEL, "palette": 0},
        {"index": 1, "start": 10, "end": 19, "title": "", "palette": 0},
        {"index": 2, "start": 20, "end": 29, "title": "", "palette": 2},
    ]})
    theme = {"genre_seed": "drama", "overall_theme": "Drama",
             "instrumentation": "strings", "theme_id": "drama-1",
             "sample": "x", "backend": "test"}
    write("themes.json", {"book": theme, "arcs": {
        "0": theme, "1": theme,
        "2": dict(theme, genre_seed="sea-epic", overall_theme="Nautical"),
    }})
    write("allocation.json", {"book": "0123456789abcdef", "budget": 4,
                              "sets": [
        {"palette": 0, "allocation": {"tense-1": 2, "tense-0": 1,
                                      "calm-0": 1}},
        {"palette": 2, "allocation": {"calm-0": 2}},
    ]})
    return Workspace(root)


def main() -> None:
    root = Path(tempfile.mkdtemp())
    try:
        ws = make_workspace(root / "ws")

        job = jobs.export_job(ws, overgen=3)
        assert [s["arc"] for s in job["sets"]] == [0, 2], job["sets"]
        print("  ok  every planned set, and not the arc that shares one")

        arc0 = job["sets"][0]["cues"]
        assert len(arc0) == (2 + 1 + 1) * 3, len(arc0)
        keeps = {c["cue"]: c["keep"] for c in arc0}
        assert keeps == {"tense-1": 2, "tense-0": 1, "calm-0": 1}, keeps
        # Takes of one cue share a prompt, so they must never share a seed
        # (or the "variety" is one file twice); nor may the bands of one mood.
        # Different cues *do* share one -- that is what lets them batch -- and
        # their prompts differ.
        for mood in {c["mood"] for c in arc0}:
            seeds = [c["seed_base"] + a for c in arc0 if c["mood"] == mood
                     for a in range(4)]
            assert len(seeds) == len(set(seeds)), f"{mood}: a seed repeats"
        print("  ok  the pool is the plan x overgen; no seed repeats in a mood")

        theme = dict(json.loads((ws.root / "themes.json").read_text())
                     ["arcs"]["0"], key_seed=f"{ws.book_id}#arc0")
        for cue in arc0:
            assert cue["prompt"] == prompts.prompt_for(
                cue["mood"], theme, band=cue["band"]), cue["stem"]
        assert job["sets"][1]["cues"][0]["prompt"].startswith("sea-epic.")
        print("  ok  prompts are prompt_for's, from each arc's own theme")

        text = json.dumps(job)
        assert SENTINEL not in text, "book text in the job"
        assert "Halvard" not in text
        print("  ok  no book text in the job -- not chapters, not titles")

        try:
            jobs.export_job(ws, [1])
        except SystemExit as refusal:
            assert "do not represent a set" in str(refusal)
        else:
            raise AssertionError("arc 1 plays arc 0's beds; exported anyway")
        print("  ok  an arc that shares another's beds is refused")

        ws.write_palette("full", 16)
        palette = json.loads((ws.root / "palette.json").read_text())
        assert palette["arcs"] == 1 and len(palette["boundaries"]) == 3
        (ws.root / "arc-002").mkdir()
        (ws.root / "arc-002" / "manifest.json").write_text("{}")
        ws.write_palette("full", 16)
        palette = json.loads((ws.root / "palette.json").read_text())
        assert palette["arcs"] == 3, palette["arcs"]
        print("  ok  palette.json counts up to the highest arc generated")
        print("all passed")
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
