"""Score the theme trial (make_theme_trial.py) once it is pulled.

For each prompt version and cue: how far apart Dracula's and Alice's takes are,
against how far apart three seeds of one prompt are. A version separates the
books if book/seed is clearly over 1. Also: whether calm and tense stay apart
within a book (a version that merges the moods is no use), how many takes
needed re-seeding, and a folder of the takes named for listening.
"""
import itertools
import json
import pathlib
import shutil
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bench_palette as bp  # noqa: E402
from theme_distance import shape, dist  # noqa: E402

pulled = pathlib.Path(sys.argv[1])
listen = pathlib.Path(sys.argv[2])
BOOKS, VERSIONS, CUES = ("dracula", "alice"), "ABC", ("calm-0", "tense-1")

takes, reports = {}, {}
for p in sorted(pulled.glob("beds-gpu*/*/*.wav")):
    if p.name.endswith(".raw.wav"):
        continue
    book, version = p.parent.name.split("-")
    cue = p.stem.rsplit("-v", 1)[0] if "-v" in p.stem else p.stem
    takes.setdefault((book, version, cue), []).append((p, shape(p), bp.measure(p)))
    reports[(book, version, p.stem)] = json.loads(
        p.with_name(f"{p.stem}.report.json").read_text(encoding="utf-8")) \
        if p.with_name(f"{p.stem}.report.json").exists() else {"usable": False}


def spread(group):
    return statistics.mean(dist(a[1], b[1]) for a, b in itertools.combinations(group, 2))


def cross(xs, ys):
    return statistics.mean(dist(x[1], y[1]) for x in xs for y in ys)


print(f"{'version':<9}{'cue':<9}{'seed':>7}{'books':>7}{'books/seed':>12}"
      f"{'centroid D':>12}{'centroid A':>12}")
for v in VERSIONS:
    for c in CUES:
        d, a = takes[("dracula", v, c)], takes[("alice", v, c)]
        seed = statistics.mean([spread(d), spread(a)])
        books = cross(d, a)
        cd = statistics.median(t[2]["centroid"] for t in d)
        ca = statistics.median(t[2]["centroid"] for t in a)
        print(f"{v:<9}{c:<9}{seed:>7.2f}{books:>7.2f}{books / seed:>11.2f}x"
              f"{cd:>11.0f}{ca:>12.0f}")

print("\ncalm against tense within a book (mood separation), over seed spread")
for v in VERSIONS:
    r = []
    for b in BOOKS:
        calm, tense = takes[(b, v, "calm-0")], takes[(b, v, "tense-1")]
        r.append(cross(calm, tense) / statistics.mean([spread(calm), spread(tense)]))
    print(f"  {v}: dracula {r[0]:.2f}x, alice {r[1]:.2f}x")

print("\nattempts (1 = passed first time) and unusable takes")
for b in BOOKS:
    for v in VERSIONS:
        rs = [r for (bb, vv, _), r in reports.items() if (bb, vv) == (b, v)]
        att = [r.get("attempt", 0) for r in rs if r.get("usable")]
        bad = sum(not r.get("usable") for r in rs)
        print(f"  {b}-{v}: {len(rs)} takes, attempts {att}, unusable {bad}")

listen.mkdir(parents=True, exist_ok=True)
for (b, v, c), group in takes.items():
    for i, (p, _, _) in enumerate(sorted(group, key=lambda t: t[0].name), 1):
        shutil.copy2(p, listen / f"{v}-{c}-{b}-{i}.wav")
print(f"\n{len(list(listen.glob('*.wav')))} files for listening in {listen}")
