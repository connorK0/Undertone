"""Robustness of theme_distance.py: the same comparisons under two other
measures. (a) spectral shape on 50 Hz-4 kHz only, where nearly all the energy
is, so near-silent high bands cannot dominate; (b) bench_palette's own timbre
(rms, centroid, flux, onsets, standardised over all beds pooled)."""
import itertools, statistics, sys
import numpy as np
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1]))
import bench_palette as bp
import theme_distance as td

def run(label, feats, dist):
    rows = {k: [] for k in ("seed", "arc theme", "mood (arc)", "book theme", "mood (book)")}
    for a in (0, 1):
        s = feats["arc"][a]
        for x, y in itertools.combinations(s, 2):
            if td.cue(x) == td.cue(y): rows["seed"].append(dist(s[x], s[y]))
            elif td.mood(td.cue(x)) != td.mood(td.cue(y)): rows["mood (arc)"].append(dist(s[x], s[y]))
    for c in sorted({td.cue(k) for k in feats["arc"][0]} & {td.cue(k) for k in feats["arc"][1]}):
        xs = [v for k, v in feats["arc"][0].items() if td.cue(k) == c]
        ys = [v for k, v in feats["arc"][1].items() if td.cue(k) == c]
        rows["arc theme"].append(statistics.mean(dist(x, y) for x in xs for y in ys))
    for b1, b2 in itertools.combinations(td.SAMPLES, 2):
        for m in feats["book"][b1]:
            rows["book theme"].append(dist(feats["book"][b1][m], feats["book"][b2][m]))
    for b in td.SAMPLES:
        for x, y in itertools.combinations(feats["book"][b], 2):
            rows["mood (book)"].append(dist(feats["book"][b][x], feats["book"][b][y]))
    print(label)
    for k, v in rows.items():
        print(f"  {k:<14}{len(v):>5}  median {statistics.median(v):6.2f}")

low = {"arc": {a: {k: v[:td.BANDS * 0 + 28] for k, v in s.items()} for a, s in td.arcs.items()},
       "book": {b: {k: v[:28] for k, v in s.items()} for b, s in td.books.items()}}
# band 28 of 40 on a 50 Hz-10 kHz mel scale is ~4 kHz; re-centre so level still does not count
low = {g: {s: {k: v - v.mean() for k, v in d.items()} for s, d in grp.items()} for g, grp in low.items()}
run("(a) shape, 50 Hz-4 kHz", low, td.dist)

raw = {"arc": {a: bp.beds_under(td.BOOK / f"arc-00{a}") for a in (0, 1)},
       "book": {b: bp.beds_under(td.GEN / b) for b in td.SAMPLES}}
keys = ("rms", "centroid", "flux", "onsets")
pool = np.array([[m[k] for k in keys] for g in raw.values() for s in g.values() for m in s.values()])
mu, sd = pool.mean(axis=0), pool.std(axis=0) + 1e-9
vec = {g: {s: {k: (np.array([m[x] for x in keys]) - mu) / sd for k, m in d.items()} for s, d in grp.items()} for g, grp in raw.items()}
run("(b) bench_palette timbre", vec, lambda a, b: float(np.linalg.norm(a - b)))
