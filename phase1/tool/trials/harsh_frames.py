"""Intermittent screech: the share of a bed's frames with more than 10 % of
their energy above 4 kHz. loopify's shrill guard averages brightness over the
whole bed, so a screech that comes and goes passes it. Calibrated on the one
trial take heard as screeching: C-tense-1-dracula-1, 32 % harsh frames."""
import json, pathlib, sys
import numpy as np
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import bench_palette as bp

def harsh_frames(p):
    x, rate = bp.read_wav(p)
    F, H = 2048, 1024
    n = 1 + (len(x) - F) // H
    idx = np.arange(F)[None, :] + H * np.arange(n)[:, None]
    mag = np.abs(np.fft.rfft(x[idx] * np.hanning(F)[None, :], axis=1)) ** 2
    f = np.fft.rfftfreq(F, 1 / rate)
    share = mag[:, f >= 4000].sum(axis=1) / (mag.sum(axis=1) + 1e-12)
    return 100 * float((share > 0.10).mean())

if __name__ == "__main__":
    for folder in sys.argv[1:]:
        root = pathlib.Path(folder)
        beds = [p for p in sorted(root.glob("*.wav")) if not p.name.endswith(".raw.wav")]
        scores = {p.stem: harsh_frames(p) for p in beds}
        flagged = {k: v for k, v in scores.items() if v > 5}
        print(f"{root.name}: {len(beds)} beds, {sum(v > 15 for v in scores.values())} over 15 %, "
              f"{sum(v > 5 for v in scores.values())} over 5 %")
        for k, v in sorted(flagged.items(), key=lambda kv: -kv[1]):
            print(f"   {k:<18} {v:5.1f} %")
