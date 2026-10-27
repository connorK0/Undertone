"""Does conditioning an arc's beds on one seed clip make them cohere?

The pitch: `musicgen-stereo-melody` accepts an audio prompt and conditions on
its chromagram. Generate one short signature clip per arc, condition all of
that arc's cues on it, and the arc stops being 32 unrelated pieces that merely
share adjectives -- crossfades between them become movements of one idea rather
than collisions of two.

That is a claim, and this measures it. Tonal coherence is the mean pairwise
cosine similarity between the beds' chroma vectors: how much the same pitch
classes carry the energy.

**The control is the production model, not the melody model with the audio left
out.** That was tried first and is not a control at all: given text and no
audio, `MusicgenMelodyForConditionalGeneration.generate` returned a
byte-identical clip for four different prompts -- same MD5 -- so the arm
measured four copies of one unconditional sample and scored a meaningless
1.000. The processor was fine; the text reaches it and `input_ids` differ. The
model simply does not use them on that path. Since nobody would ship
text-only-melody either, the honest comparison is the pipeline as it stands
against the pipeline with conditioning:

    text-only : musicgen-stereo-medium, text prompts        (what runs today)
    melody    : musicgen-stereo-melody, same prompts + signature

That confounds the model with the conditioning, and it is still the right
comparison, because those are the two things that could actually be shipped.

    python tool/bench_melody.py --book <id> --arc 0

What this does NOT measure is whether the result is *nicer*. Chroma similarity
would also be high for four beds that were boringly identical. Read it beside
the audio it writes, which is why the files are kept.
"""

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_beds as gb  # noqa: E402
import loopify  # noqa: E402

MELODY_MODEL = "facebook/musicgen-stereo-melody"
PLAIN_MODEL = "facebook/musicgen-stereo-medium"


def chroma(audio: np.ndarray, rate: int) -> np.ndarray:
    """Energy per pitch class, as a unit 12-vector.

    Deliberately simple: one FFT over the whole clip, every bin folded to its
    pitch class by frequency. A proper chromagram would window over time and
    weight perceptually; none of that changes which pitch classes a sustained
    bed sits on, which is the only question here.
    """
    mono = audio.mean(axis=1) if audio.ndim > 1 else audio
    spectrum = np.abs(np.fft.rfft(mono * np.hanning(len(mono))))
    freqs = np.fft.rfftfreq(len(mono), 1 / rate)
    # Below 55 Hz the bins are too coarse to name a pitch; above 2 kHz the
    # energy is overtones, which smear across every class alike.
    keep = (freqs >= 55) & (freqs <= 2000)
    freqs, spectrum = freqs[keep], spectrum[keep]
    classes = np.rint(69 + 12 * np.log2(freqs / 440.0)).astype(int) % 12
    out = np.zeros(12)
    np.add.at(out, classes, spectrum)
    norm = np.linalg.norm(out)
    return out / norm if norm else out


def coherence(vectors: list[np.ndarray]) -> float:
    """Mean pairwise cosine similarity. 1 is identical, 0 is unrelated."""
    if len(vectors) < 2:
        return float("nan")
    scores = [float(a @ b)
              for i, a in enumerate(vectors) for b in vectors[i + 1:]]
    return sum(scores) / len(scores)


def load(name: str, melody: bool):
    import torch
    from transformers import AutoProcessor

    if melody:
        from transformers import MusicgenMelodyForConditionalGeneration as Cls
    else:
        from transformers import MusicgenForConditionalGeneration as Cls

    print(f"loading {name}...", flush=True)
    started = time.time()
    processor = AutoProcessor.from_pretrained(name)
    model = Cls.from_pretrained(name, dtype=torch.float16).to("cuda")
    print(f"  loaded in {time.time() - started:.1f}s")
    return processor, model


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--book", required=True)
    parser.add_argument("--arc", type=int, default=None)
    parser.add_argument("--cues", nargs="*",
                        default=["calm-0", "tense-2", "ominous-1",
                                 "triumphant-3"])
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--guidance", type=float, default=3.0)
    parser.add_argument("--out", type=Path, default=Path("build/melody"))
    args = parser.parse_args()

    import torch

    known = gb.themes()
    key = args.book if args.arc is None else f"{args.book}#arc{args.arc}"
    theme = known.get(key)
    if theme is None:
        raise SystemExit(f"no cached theme for {key}")
    theme["key_seed"] = key
    tonic = gb.tonic_for(theme)

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tokens = gb.SECONDS * gb.TOKENS_PER_SECOND
    prompts = {}
    for cue in args.cues:
        mood, _, band = cue.partition("-")
        prompts[cue] = gb.prompt_for(mood, theme, positive_only=True,
                                     band=int(band) if band else None)

    # The arc's signature: its own theme stated plainly in its own key, with
    # nothing of any particular mood about it. Every cue is then asked to be a
    # version of this.
    signature_prompt = (
        f"{theme['genre_seed']}. {theme['overall_theme']}. "
        f"{theme['instrumentation']}. A simple sustained statement of one "
        f"harmonic idea in {tonic} minor, slow, unhurried, no drums."
    )

    results = {}
    rows = []

    # --- arm one: the pipeline as it stands.
    processor, model = load(PLAIN_MODEL, melody=False)
    rate = model.config.audio_encoder.sampling_rate

    def plain(prompt: str, seed: int):
        torch.manual_seed(seed)
        inputs = processor(text=[prompt], padding=True,
                           return_tensors="pt").to("cuda")
        with torch.no_grad():
            audio = model.generate(**inputs, do_sample=True,
                                   guidance_scale=args.guidance,
                                   max_new_tokens=tokens)
        return audio[0].to(torch.float32).cpu().numpy().T

    print(f"\nsignature in {tonic}")
    signature = plain(signature_prompt, args.seed)
    loopify.write_wav_at(out / "signature.raw.wav", signature, rate)

    print("\n--- text-only (musicgen-stereo-medium, what runs today) ---")
    vectors = []
    for cue, prompt in prompts.items():
        began = time.time()
        clip = plain(prompt, args.seed)
        loop, report = loopify.process(clip, rate)
        loopify.write_wav(out / f"text-only-{cue}.wav", loop)
        vectors.append(chroma(loop, loopify.SAMPLE_RATE))
        print(f"  {cue:14s} {time.time() - began:5.1f}s  "
              f"centroid {report['centroid_hz']:6.0f} Hz"
              f"{'' if report['usable'] else '   REJECTED'}", flush=True)
        rows.append({"group": "text-only", "cue": cue, **report})
    results["text-only"] = coherence(vectors)
    print(f"  tonal coherence: {results['text-only']:.3f}")

    del model, processor
    torch.cuda.empty_cache()

    # --- arm two: conditioned on the signature.
    processor, model = load(MELODY_MODEL, melody=True)
    melody_in = signature.mean(axis=1)

    print("\n--- melody (conditioned on one signature) ---")
    vectors = []
    for cue, prompt in prompts.items():
        began = time.time()
        torch.manual_seed(args.seed)
        inputs = processor(audio=melody_in, sampling_rate=rate, text=[prompt],
                           padding=True, return_tensors="pt").to("cuda")
        # The feature extractor returns float32 chroma against an fp16 model,
        # which fails inside the projection with "mat1 and mat2 must have the
        # same dtype". Cast rather than run the model in fp32.
        if "input_features" in inputs:
            inputs["input_features"] = inputs["input_features"].to(model.dtype)
        with torch.no_grad():
            audio = model.generate(**inputs, do_sample=True,
                                   guidance_scale=args.guidance,
                                   max_new_tokens=tokens)
        clip = audio[0].to(torch.float32).cpu().numpy().T
        loop, report = loopify.process(clip, rate)
        loopify.write_wav(out / f"melody-{cue}.wav", loop)
        vectors.append(chroma(loop, loopify.SAMPLE_RATE))
        print(f"  {cue:14s} {time.time() - began:5.1f}s  "
              f"centroid {report['centroid_hz']:6.0f} Hz"
              f"{'' if report['usable'] else '   REJECTED'}", flush=True)
        rows.append({"group": "melody", "cue": cue, **report})
    results["melody"] = coherence(vectors)
    print(f"  tonal coherence: {results['melody']:.3f}")

    # A guard against measuring copies of one clip again: four beds that are
    # byte-identical would score a perfect 1.000 and mean nothing.
    md5s = {p.name: hash(p.read_bytes()) for p in out.glob("melody-*.wav")}
    distinct = len(set(md5s.values()))
    print(f"  {distinct}/{len(md5s)} melody beds are distinct files")

    (out / "results.json").write_text(
        json.dumps({"book": args.book, "arc": args.arc, "tonic": tonic,
                    "signature": signature_prompt,
                    "coherence": results, "distinct_melody_beds": distinct,
                    "rows": rows}, indent=2), encoding="utf-8")

    delta = results["melody"] - results["text-only"]
    print(f"\ntext-only {results['text-only']:.3f}   "
          f"melody {results['melody']:.3f}   ({delta:+.3f})")
    print(f"audio in {out} -- the number is not the verdict, listening is")


if __name__ == "__main__":
    main()
