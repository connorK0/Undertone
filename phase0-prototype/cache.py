"""A local JSON cache so a second run on the same file costs nothing.

Keyed by book and paragraph index, per the brief. The book key also folds in a
hash of the file's contents and the model name: editing the text shifts every
paragraph index, and switching models should not silently serve tags the new
model never produced.
"""

import hashlib
import json
import re
from pathlib import Path


def book_id(path, text, model):
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]
    return f"{Path(path).stem}-{digest}-{model}"


def theme_id(overall_theme):
    """Stable string assigned once per book, derived from the theme text."""
    slug = re.sub(r"[^a-z0-9]+", "-", overall_theme.lower()).strip("-")
    digest = hashlib.sha256(overall_theme.encode("utf-8")).hexdigest()[:6]
    return f"{slug}-{digest}"


class Cache:
    def __init__(self, path, key):
        self.path = Path(path)
        self.key = key
        if self.path.exists():
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        else:
            self.data = {}
        self.book = self.data.setdefault(key, {"theme": None, "paragraphs": {}})

    def get_theme(self):
        return self.book["theme"]

    def set_theme(self, theme):
        self.book["theme"] = theme

    def get_paragraph(self, index):
        return self.book["paragraphs"].get(str(index))

    def set_paragraph(self, index, tag):
        self.book["paragraphs"][str(index)] = tag

    def save(self):
        self.path.write_text(
            json.dumps(self.data, indent=2, ensure_ascii=False), encoding="utf-8"
        )
