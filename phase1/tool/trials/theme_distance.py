"""Do different themes sound different? Measured on beds already on disk.

Spectral shape: the long-term average spectrum on 40 mel bands (50 Hz-10 kHz),
in dB, with its own mean removed so loudness does not count. Distance between
two beds is the RMS difference of their shapes, in dB. This is closer to "what
instruments" than bench_palette's timbre (rms, centroid, flux, onsets), which
cannot tell a flute from a violin at the same brightness.

Compared:
  seed          same cue, same arc, different takes   (what a reseed moves)
  arc theme     same cue, arc 0 against arc 1         (Drama and Action -> Martial Fantasy)
  mood (arc)    different moods, same arc
  book theme    same mood, different sample book      (Horror / Children's Fantasy / Victorian Gothic)
  mood (book)   different moods, same sample book
"""
import itertools
import os
import pathlib
import statistics
import sys
import wave

import numpy as np

GEN = pathlib.Path(os.environ["APPDATA"]) / "com.example" / "reader_shell" / "generated"
BOOK = GEN / "98068df9f6f3e739"
SAMPLES = ["sample-alice_ch1", "sample-dracula_ch1", "sample-christmas_carol_stave1"]
FFT, HOP, BANDS, LOW, HIGH = 4096, 1024, 40, 50.0, 10000.0


def read(path):
    with wave.open(str(path), "rb") as w:
        rate, n, width, ch = w.getframerate(), w.getnframes(), w.getsampwidth(), w.getnchannels()
        raw = w.readframes(n)
    assert width == 2, path
    x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return (x.reshape(-1, ch).mean(axis=1) if ch > 1 else x), rate


def mel(f):
    return 2595 * np.log10(1 + f / 700)


def shape(path):
    x, rate = read(path)
    count = 1 + (len(x) - FFT) // HOP
    idx = np.arange(FFT)[None, :] + HOP * np.arange(count)[:, None]
    power = (np.abs(np.fft.rfft(x[idx] * np.hanning(FFT)[None, :], axis=1)) ** 2).mean(axis=0)
    freqs = np.fft.rfftfreq(FFT, 1 / rate)
    edges = np.linspace(mel(LOW), mel(HIGH), BANDS + 1)
    m = mel(freqs)
    bands = np.array([power[(m >= a) & (m < b)].sum() for a, b in zip(edges, edges[1:])])
    db = 10 * np.log10(bands + 1e-12)
    return db - db.mean()


def dist(a, b):
    return float(np.sqrt(np.mean((a - b) ** 2)))


def cue(stem):
    return stem.rsplit("-v", 1)[0] if "-v" in stem else stem


def mood(c):
    head, _, tail = c.rpartition("-")
    return head if tail.isdigit() and head else c


def beds(folder):
    return {p.stem: shape(p) for p in sorted(folder.glob("*.wav")) if not p.name.endswith(".raw.wav")}


arcs = {0: beds(BOOK / "arc-000"), 1: beds(BOOK / "arc-001")}
books = {b: beds(GEN / b) for b in SAMPLES}

rows = {k: [] for k in ("seed", "arc theme", "mood (arc)", "book theme", "mood (book)")}
per_cue_seed, per_cue_arc = {}, {}
for a, set_ in arcs.items():
    for x, y in itertools.combinations(set_, 2):
        d = dist(set_[x], set_[y])
        if cue(x) == cue(y):
            rows["seed"].append(d)
            per_cue_seed.setdefault(cue(x), []).append(d)
        elif mood(cue(x)) != mood(cue(y)):
            rows["mood (arc)"].append(d)
for c in sorted({cue(s) for s in arcs[0]} & {cue(s) for s in arcs[1]}):
    xs = [v for s, v in arcs[0].items() if cue(s) == c]
    ys = [v for s, v in arcs[1].items() if cue(s) == c]
    d = [dist(x, y) for x in xs for y in ys]
    per_cue_arc[c] = statistics.mean(d)
    rows["arc theme"].append(per_cue_arc[c])
for b1, b2 in itertools.combinations(SAMPLES, 2):
    for m in books[b1]:
        if m in books[b2]:
            rows["book theme"].append(dist(books[b1][m], books[b2][m]))
for b in SAMPLES:
    for x, y in itertools.combinations(books[b], 2):
        rows["mood (book)"].append(dist(books[b][x], books[b][y]))

print(f"{'comparison':<14}{'pairs':>6}{'median dB':>11}{'mean dB':>9}")
for k, v in rows.items():
    print(f"{k:<14}{len(v):>6}{statistics.median(v):>11.2f}{statistics.mean(v):>9.2f}")

print("\nper cue: arc 0 vs arc 1, against that cue's own take spread where it has one")
for c, d in per_cue_arc.items():
    s = per_cue_seed.get(c)
    print(f"  {c:<14}{d:>6.2f} dB" + (f"   takes {statistics.mean(s):.2f} dB" if s else ""))

print("\nper mood: the three books against each other")
for m in sorted(books[SAMPLES[0]]):
    ds = [dist(books[a][m], books[b][m]) for a, b in itertools.combinations(SAMPLES, 2)]
    print(f"  {m:<12}" + "  ".join(f"{d:5.2f}" for d in ds) + "   (alice-dracula, alice-carol, dracula-carol)")
