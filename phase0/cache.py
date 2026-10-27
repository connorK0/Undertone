"""JSON cache laid out as book -> model -> {theme, paragraphs by index}.

The book key is the file stem plus a hash of its contents, so editing the text
(which shifts every paragraph index) starts fresh. The model sits one level
below that, so each backend's tags live apart: switching --model re-classifies
instead of quietly reusing another model's work.
"""

import hashlib
import json
import re
from pathlib import Path


def book_key(path, text):
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:10]
    return f"{Path(path).stem}-{digest}"


def theme_id(overall_theme):
    """Stable per-book id derived from the theme text itself."""
    slug = re.sub(r"[^a-z0-9]+", "-", overall_theme.lower()).strip("-")
    digest = hashlib.sha256(overall_theme.encode("utf-8")).hexdigest()[:6]
    return f"{slug}-{digest}"


class Cache:
    def __init__(self, path, book, model):
        self.path = Path(path)
        if self.path.exists():
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        else:
            self.data = {}
        self.entry = self.data.setdefault(book, {}).setdefault(
            model, {"theme": None, "paragraphs": {}}
        )

    def get_theme(self):
        return self.entry["theme"]

    def set_theme(self, theme):
        self.entry["theme"] = theme

    def get_paragraph(self, index):
        return self.entry["paragraphs"].get(str(index))

    def set_paragraph(self, index, tag):
        self.entry["paragraphs"][str(index)] = tag

    def save(self):
        self.path.write_text(
            json.dumps(self.data, indent=2, ensure_ascii=False), encoding="utf-8"
        )
