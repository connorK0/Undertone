"""Score both theme trials together (SUMMARY 9.42).

For every (version, cue, book) cell: busyness (onsets/s), harshness (energy
share above 4 kHz), and attempts. Then, set against each prompt's own seed
spread, with the real split's rank among the ten 3-against-3 splits:
  books apart   Dracula against Alice, per version and cue
  moods apart   calm-0 against tense-0, and calm-0 against tense-1
  band step     tense-0 against tense-1
Trial 1 supplies A's calm-0 and tense-1 and all of B and C; trial 2 supplies
A's tense-0 and all of D and E. Same settings, same card type, batch 1.
"""
import itertools
import json
import pathlib
import shutil
import statistics
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bench_palette as bp  # noqa: E402
from theme_distance import shape, dist  # noqa: E402

trial = pathlib.Path(sys.argv[1])
cells = {}
for pulled in (trial / "pulled", trial / "pulled-2"):
    for p in sorted(pulled.glob("beds-gpu*/*/*.wav")):
        if p.name.endswith(".raw.wav"):
            continue
        book, version = p.parent.name.split("-")
        cue = p.stem.rsplit("-v", 1)[0] if "-v" in p.stem else p.stem
        report = p.with_name(f"{p.stem}.report.json")
        x, rate = bp.read_wav(p)
        F, H = 2048, 1024
        n = 1 + (len(x) - F) // H
        idx = np.arange(F)[None, :] + H * np.arange(n)[:, None]
        mag = np.abs(np.fft.rfft(x[idx] * np.hanning(F)[None, :], axis=1)) ** 2
        f = np.fft.rfftfreq(F, 1 / rate)
        cells.setdefault((version, cue, book), []).append({
            "path": p, "shape": shape(p), "onsets": bp.measure(p)["onsets"],
            "high": float(mag[:, f >= 4000].sum() / mag.sum()),
            "attempt": json.loads(report.read_text())["attempt"] if report.exists() else None,
        })


def score(xs, ys):
    cross = statistics.mean(dist(x["shape"], y["shape"]) for x in xs for y in ys)
    within = statistics.mean(
        statistics.mean(dist(a["shape"], b["shape"]) for a, b in itertools.combinations(g, 2))
        for g in (xs, ys))
    return cross / within


def ranked(xs, ys):
    pool, real = xs + ys, score(xs, ys)
    splits = [score([pool[i] for i in s], [pool[i] for i in range(6) if i not in s])
              for s in itertools.combinations(range(6), 3) if 0 in s]
    return f"{real:.2f}x (rank {1 + sum(s > real + 1e-9 for s in splits)})"


versions = sorted({v for v, _, _ in cells})
print("feel, mean of three takes")
print(f"  {'cell':<22}{'onsets/s':>9}{'>4kHz %':>9}  attempts")
for k in sorted(cells):
    g = cells[k]
    print(f"  {'-'.join(k):<22}{statistics.mean(t['onsets'] for t in g):>9.2f}"
          f"{100 * statistics.mean(t['high'] for t in g):>9.2f}  "
          f"{[t['attempt'] for t in g]}")

print("\nbooks apart")
for v in versions:
    for c in ("calm-0", "tense-0", "tense-1"):
        if (v, c, "dracula") in cells and (v, c, "alice") in cells:
            print(f"  {v} {c:<8} {ranked(cells[(v, c, 'dracula')], cells[(v, c, 'alice')])}")

print("\nmoods apart, and the band step")
for v in versions:
    for book in ("dracula", "alice"):
        def get(c):
            # E changes only tense; its calm is D's.
            return cells.get((v, c, book)) or (cells.get(("D", c, book)) if v == "E" else None)
        calm, t0, t1 = get("calm-0"), get("tense-0"), get("tense-1")
        parts = []
        if calm and t0:
            parts.append(f"calm/tense-0 {ranked(calm, t0)}")
        if calm and t1:
            parts.append(f"calm/tense-1 {ranked(calm, t1)}")
        if t0 and t1:
            parts.append(f"band step {ranked(t0, t1)}")
        if parts:
            print(f"  {v} {book:<8} " + "   ".join(parts))

listen = trial / "listen-2"
listen.mkdir(exist_ok=True)
for (v, c, b), g in cells.items():
    if v in "ADE":
        for i, t in enumerate(sorted(g, key=lambda t: t["path"].name), 1):
            shutil.copy2(t["path"], listen / f"{v}-{c}-{b}-{i}.wav")
print(f"\n{len(list(listen.glob('*.wav')))} files for listening in {listen}")
