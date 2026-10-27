"""The book workspace, read from Python.

The Dart package (framework/dart) writes a workspace up to allocation.json;
this side reads it and writes the bed sets and palette.json. FORMAT.md at the
framework root is the contract both hold to. Only what generation needs is
read here -- the text never is.
"""

from __future__ import annotations

import json
from pathlib import Path

FORMAT = 1


class WorkspaceError(Exception):
    pass


class Workspace:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        info = self.root / "workspace.json"
        if not info.exists():
            raise WorkspaceError(f"no workspace at {self.root}")
        self.info = json.loads(info.read_text(encoding="utf-8"))
        if int(self.info.get("format", 0)) > FORMAT:
            raise WorkspaceError(f"{self.root} is format {self.info['format']}"
                                 f"; this build reads up to {FORMAT}")

    @property
    def book_id(self) -> str:
        return self.info["book"]

    @property
    def title(self) -> str:
        return self.info.get("title", "")

    def _json(self, name: str, default):
        path = self.root / name
        if not path.exists():
            return default
        return json.loads(path.read_text(encoding="utf-8"))

    def themes(self) -> dict:
        """{"book": theme, "arcs": {"0": theme, ...}}."""
        return self._json("themes.json", {})

    def arcs(self) -> list[dict]:
        return self._json("arcs.json", {}).get("arcs", [])

    def allocation(self) -> dict:
        return self._json("allocation.json", {})

    def generated_arcs(self) -> int:
        """The highest arc with beds, plus one -- the reader app's rule
        (generate_beds.arcs_on_disk). Counting directories rather than the
        arcs of one run is what stops generating arc 3 alone from declaring a
        one-arc book and clamping the reader back to arc 0."""
        highest = -1
        for child in self.root.glob("arc-*"):
            if (child / "manifest.json").exists():
                try:
                    highest = max(highest, int(child.name.split("-")[1]))
                except (IndexError, ValueError):
                    continue
        return highest + 1

    def write_palette(self, palette: str, cues: int) -> None:
        """How a player finds the set for a chapter. Same shape as the reader
        app's generated/<book>/palette.json, so either can play it."""
        (self.root / "palette.json").write_text(json.dumps({
            "book": self.book_id,
            "palette": palette,
            "arc_size": 0,
            # What exists rather than what was planned: generating one arc
            # must not shrink the book, and reading past the last generated
            # arc plays the last one.
            "arcs": max(self.generated_arcs(), 1),
            "cues": cues,
            "boundaries": self.arcs(),
        }, indent=2) + "\n", encoding="utf-8")
