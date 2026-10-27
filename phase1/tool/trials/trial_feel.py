"""What the trial takes sound like, in numbers: busyness (onsets/s, flux) and harshness
(share of energy above 4 kHz, and the loudest 4-8 kHz moment against the bed's
own median), per version, book and cue of the theme trial."""
import pathlib, statistics, sys, json
import numpy as np
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bench_palette as bp

def harsh(path):
    x, rate = bp.read_wav(path)
    F, H = 2048, 1024
    n = 1 + (len(x) - F) // H
    idx = np.arange(F)[None, :] + H * np.arange(n)[:, None]
    mag = np.abs(np.fft.rfft(x[idx] * np.hanning(F)[None, :], axis=1)) ** 2
    f = np.fft.rfftfreq(F, 1 / rate)
    hi = mag[:, (f >= 4000)].sum(axis=1); tot = mag.sum(axis=1) + 1e-12
    band = mag[:, (f >= 4000) & (f < 8000)].sum(axis=1) + 1e-12
    return float(hi.sum() / tot.sum()), float(10 * np.log10(band.max() / np.median(band)))

root = pathlib.Path(sys.argv[1])
rows = {}
for p in sorted(root.glob("*.wav")):
    v, rest = p.stem.split("-", 1)
    cue = "-".join(rest.split("-")[:2]); book = rest.split("-")[2]
    m = bp.measure(p); share, peak = harsh(p)
    rows.setdefault((v, cue, book), []).append((m["onsets"], m["flux"], share, peak))
print(f"{'cell':<22}{'onsets/s':>9}{'flux':>7}{'>4kHz %':>9}{'4-8k peak dB':>14}")
for k in sorted(rows):
    a = np.array(rows[k]).mean(axis=0)
    print(f"{'-'.join(k):<22}{a[0]:>9.2f}{a[1]:>7.1f}{100*a[2]:>9.2f}{a[3]:>14.1f}")
