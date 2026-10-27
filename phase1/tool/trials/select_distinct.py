"""How much separation would choosing takes for distinctness buy?

Arc 0 and arc 1 each generated a pool of 96 takes and kept 32. For every cue
the two arcs share, this compares the distance between the arcs (spectral
shape, theme_distance.py's measure) three ways:

  kept     the takes actually kept (by movement and the register gate)
  pool     every pair across the two pools: what an arbitrary pick averages
  far      the takes each arc would keep if chosen to be far from the other
           arc's pool, the same count as kept, still inside the register gate

and sets each against the cue's seed spread (takes of one cue in one pool).
"""
import hashlib
import itertools
import os
import pathlib
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bench_palette as bp  # noqa: E402
from theme_distance import shape, dist, cue  # noqa: E402

BOOK = pathlib.Path(os.environ["APPDATA"]) / "com.example" / "reader_shell" / "generated" / "98068df9f6f3e739"
POOLS = {0: BOOK / "_cloud-arc0" / "arc0-kaggle", 1: BOOK / "_cloud-arc1" / "arc1-kaggle"}
LIVE = {0: BOOK / "arc-000", 1: BOOK / "arc-001"}
# The import's gate lines (bench centroid), SUMMARY 9.38 and 9.40.
GATE = {0: {"tense": 1158, "ominous": 743}, 1: {"tense": 1096, "ominous": 631}}


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def pool(arc):
    out = {}
    for p in sorted(POOLS[arc].glob(f"beds-gpu*/arc-00{arc}/*.wav")):
        if p.name.endswith(".raw.wav"):
            continue
        out[p.stem] = {"path": p, "shape": shape(p), "hash": digest(p),
                       "centroid": bp.measure(p)["centroid"]}
    return out


def in_gate(arc, c, take):
    mood, _, band = c.rpartition("-")
    line = GATE[arc].get(mood)
    if line is None:
        return True
    return take["centroid"] < line if band == "0" else take["centroid"] > line


def mean_cross(xs, ys):
    return statistics.mean(dist(x["shape"], y["shape"]) for x in xs for y in ys)


pools = {a: pool(a) for a in (0, 1)}
live = {a: {digest(p) for p in LIVE[a].glob("*.wav") if not p.name.endswith(".raw.wav")}
        for a in (0, 1)}

print(f"{'cue':<14}{'k':>4}{'seed':>7}{'kept':>7}{'pool':>7}{'far':>7}   far/seed  kept/seed")
ratios = {"kept": [], "far": []}
for c in sorted({cue(s) for s in pools[0]} & {cue(s) for s in pools[1]}):
    takes = {a: [t for s, t in pools[a].items() if cue(s) == c] for a in (0, 1)}
    kept = {a: [t for t in takes[a] if t["hash"] in live[a]] for a in (0, 1)}
    gated = {a: [t for t in takes[a] if in_gate(a, c, t)] for a in (0, 1)}
    seed = statistics.mean(dist(x["shape"], y["shape"])
                           for a in (0, 1) for x, y in itertools.combinations(takes[a], 2))
    # Far: each take scored by its mean distance to the other arc's gated pool,
    # the k most distant kept, alternating until the picks stop changing.
    far = {a: kept[a] for a in (0, 1)}
    for _ in range(5):
        for a in (0, 1):
            other = far[1 - a]
            ranked = sorted(gated[a], key=lambda t: -mean_cross([t], other))
            far[a] = ranked[:len(kept[a])]
    k = f"{len(kept[0])}/{len(kept[1])}"
    row = (seed, mean_cross(kept[0], kept[1]), mean_cross(takes[0], takes[1]),
           mean_cross(far[0], far[1]))
    ratios["kept"].append(row[1] / seed)
    ratios["far"].append(row[3] / seed)
    print(f"{c:<14}{k:>4}" + "".join(f"{v:>7.2f}" for v in row)
          + f"   {row[3] / seed:8.2f}x {row[1] / seed:8.2f}x")
print(f"\nmedian over cues: kept {statistics.median(ratios['kept']):.2f}x seed, "
      f"far {statistics.median(ratios['far']):.2f}x seed")


# One-sided, which is the real case: the first book's beds are already chosen
# and fixed, and only the new book's takes are picked for distance from them.
print("\none-sided: arc 0 as kept, arc 1 chosen far from it")
one = []
for c in sorted({cue(s) for s in pools[0]} & {cue(s) for s in pools[1]}):
    takes = {a: [t for s, t in pools[a].items() if cue(s) == c] for a in (0, 1)}
    kept = {a: [t for t in takes[a] if t["hash"] in live[a]] for a in (0, 1)}
    gated1 = [t for t in takes[1] if in_gate(1, c, t)]
    seed = statistics.mean(dist(x["shape"], y["shape"])
                           for a in (0, 1) for x, y in itertools.combinations(takes[a], 2))
    pick = sorted(gated1, key=lambda t: -mean_cross([t], kept[0]))[:len(kept[1])]
    one.append(mean_cross(kept[0], pick) / seed)
    print(f"  {c:<14}{mean_cross(kept[0], kept[1]) / seed:6.2f}x -> {one[-1]:5.2f}x")
print(f"  median {statistics.median(one):.2f}x seed")
