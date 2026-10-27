"""Download the CC0/CC-BY loop set into phase1/assets/music/licensed/.

    phase0/.venv/Scripts/python.exe phase1/tool/fetch_licensed_loops.py

Run from the repository root. Standard library only. Committed so the
provenance of every file is reproducible rather than a claim in a README.

This is the second of two libraries. The generated one (tool/make_loops.py) is
what the app plays by default, because on this machine there is no way to
verify that found music loops cleanly or sits at a matched level -- no ffmpeg,
no numpy, nothing that can decode an MP3. This set exists so the licensed path
is real and switchable: set MusicLibrary.licensed in lib/music_library.dart and
these play instead.

Only CC0 and CC-BY are accepted. Anything NC or ND is refused outright: "no
derivatives" is at best strained by crossfading and re-levelling a track, and
"non-commercial" would have to be unpicked later. The check is against the
licence the page actually declares, not against what a search filter promised.
"""

import html
import json
import re
import urllib.request
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "phase1" / "assets" / "music" / "licensed"
UA = {"User-Agent": "Mozilla/5.0 (music-book asset fetch)"}

ALLOWED = {"CC0", "CC-BY 3.0", "CC-BY 4.0"}

# Candidate OpenGameArt submissions per mood, best first; the first one that is
# reachable and acceptably licensed wins. Alternates matter: OpenGameArt returns
# a 502 often enough to lose a mood on a single-candidate run, and a page's real
# licence is regularly not the one the search filter implied -- 'Her Violet
# Eyes' turned out CC-BY-SA, which would push share-alike onto this project.
#
# Chosen by title, tags and description. Nothing here has been listened to,
# which is exactly why this is not the default set.
PICKS = {
    "calm": ["crystal-cave-song18", "seashore-peace-ambiance", "calm-bgm"],
    "neutral": ["loading-screen-loop", "menu-music", "town-theme-rpg"],
    "melancholic": ["tragic-ambient-main-menu", "contemplation-0"],
    "ominous": ["dark-ambient-loop-13", "dark-ambient-drone", "dark-ambiance"],
    "tense": ["perpetual-tension", "imminent-threat"],
    "triumphant": ["awake-megawall-10", "at-home-orchestral"],
    "romantic": ["the-field-of-dreams", "new-beginning", "her-violet-eyes"],
    "whimsical": ["enchanted-tiki-86", "bossa-nova"],
}

AUDIO = re.compile(
    r"https://opengameart\.org/sites/default/files/[^\"'\s]+?\.(?:ogg|mp3|wav)",
    re.I,
)


def get(url):
    request = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def parse_page(page):
    text = page.decode("utf-8", "replace")

    licenses = sorted(set(re.findall(
        r"<div class='license-name'>([^<]+)</div>", text)))
    licenses = [html.unescape(name).strip() for name in licenses]

    author = None
    match = re.search(
        r"field-name-author-submitter.*?<a[^>]*>([^<]+)</a>", text, re.S)
    if match:
        author = html.unescape(match.group(1)).strip()

    title = None
    match = re.search(r"<title>(.*?)\s*\|\s*OpenGameArt", text, re.S)
    if match:
        title = html.unescape(match.group(1)).strip()

    attribution = None
    match = re.search(
        r"field-name-field-art-attribution.*?field-item[^>]*>(.*?)</div>",
        text, re.S)
    if match:
        attribution = html.unescape(re.sub(r"<[^>]+>", " ", match.group(1)))
        attribution = re.sub(r"\s+", " ", attribution).strip() or None

    # Real downloads only: skip the site's own generated previews and thumbs.
    files = []
    for url in AUDIO.findall(text):
        if "/audio_preview/" in url or "/styles/" in url:
            continue
        if url not in files:
            files.append(url)

    return {
        "title": title,
        "author": author,
        "licenses": licenses,
        "attribution": attribution,
        "files": files,
    }


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    entries = []
    skipped = []

    for mood, candidates in PICKS.items():
        entry = None
        reasons = []

        for slug in candidates:
            url = f"https://opengameart.org/content/{slug}"
            try:
                info = parse_page(get(url))
            except Exception as error:  # noqa: BLE001 -- try the next candidate
                reasons.append(f"{slug}: fetch failed: {error}")
                continue

            usable = [name for name in info["licenses"] if name in ALLOWED]
            if not usable:
                reasons.append(f"{slug}: licence not CC0/CC-BY: {info['licenses']}")
                continue
            if not info["files"]:
                reasons.append(f"{slug}: no downloadable audio file")
                continue

            source_url = info["files"][0]
            suffix = Path(unquote(source_url)).suffix.lower()
            target = OUT_DIR / f"{mood}{suffix}"
            try:
                data = get(source_url)
            except Exception as error:  # noqa: BLE001
                reasons.append(f"{slug}: download failed: {error}")
                continue

            # A mood keeps exactly one file; drop any left by an earlier run
            # under a different extension.
            for stale in OUT_DIR.glob(f"{mood}.*"):
                if stale != target:
                    stale.unlink()
            target.write_bytes(data)

            entry = {
                "mood": mood,
                "file": target.name,
                "bytes": len(data),
                "title": info["title"],
                "author": info["author"],
                "license": usable[0],
                "all_licenses": info["licenses"],
                "attribution_required": usable[0] != "CC0",
                "attribution_text": info["attribution"],
                "page": url,
                "source_url": source_url,
            }
            print(f"{mood:12s} {usable[0]:9s} {len(data)/1e6:5.2f}MB  "
                  f"{info['title']} -- {info['author']}")
            break

        if entry is None:
            skipped.append((mood, ",".join(candidates), "; ".join(reasons)))
            print(f"{mood:12s} SKIP  " + "; ".join(reasons))
        else:
            entries.append(entry)

    manifest = {
        "library": "licensed",
        "note": "Downloaded from OpenGameArt by tool/fetch_licensed_loops.py. "
                "CC0 and CC-BY only. Nothing here has been auditioned, "
                "loop-checked or level-matched -- see that script's docstring.",
        "loops": sorted(entries, key=lambda e: e["mood"]),
        "skipped": [
            {"mood": mood, "slug": slug, "reason": reason}
            for mood, slug, reason in skipped
        ],
    }
    (OUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"\n{len(entries)} downloaded, {len(skipped)} skipped")
    print(f"wrote {(OUT_DIR / 'manifest.json').relative_to(ROOT)}")


if __name__ == "__main__":
    main()
