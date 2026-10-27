"""How unusual is each real split, among every 3-against-3 split of its six
takes? Rank 1 of 10 means the real split is the most separated one possible,
which is as strong as six takes can say (p = 0.1). Same for calm vs tense."""
import itertools, pathlib, statistics, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from theme_distance import shape, dist

pulled = pathlib.Path(sys.argv[1])
takes = {}
for p in sorted(pulled.glob("beds-gpu*/*/*.wav")):
    if p.name.endswith(".raw.wav"): continue
    book, version = p.parent.name.split("-")
    c = p.stem.rsplit("-v", 1)[0] if "-v" in p.stem else p.stem
    takes.setdefault((book, version, c), []).append(shape(p))

def score(xs, ys):
    cross = statistics.mean(dist(x, y) for x in xs for y in ys)
    within = statistics.mean([statistics.mean(dist(a, b) for a, b in itertools.combinations(g, 2)) for g in (xs, ys)])
    return cross / within

def rank(xs, ys):
    pool = xs + ys
    real = score(xs, ys)
    splits = []
    for idx in itertools.combinations(range(6), 3):
        if 0 not in idx: continue  # each split once
        a = [pool[i] for i in idx]; b = [pool[i] for i in range(6) if i not in idx]
        splits.append(score(a, b))
    return real, 1 + sum(s > real + 1e-9 for s in splits), len(splits)

print("books apart (Dracula vs Alice)")
for v in "ABC":
    for c in ("calm-0", "tense-1"):
        r, k, n = rank(takes[("dracula", v, c)], takes[("alice", v, c)])
        print(f"  {v} {c:<8} {r:.2f}x  rank {k} of {n}")
print("moods apart (calm vs tense)")
for v in "ABC":
    for b in ("dracula", "alice"):
        r, k, n = rank(takes[(b, v, "calm-0")], takes[(b, v, "tense-1")])
        print(f"  {v} {b:<8} {r:.2f}x  rank {k} of {n}")
