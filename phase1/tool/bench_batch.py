"""Does generating several beds at once cost less than generating them in turn?

The generator makes one bed per call, and a 32-cue palette is 32 calls of about
128 seconds each. That is the shape of the cost, and the question this answers
is whether the shape is necessary or merely how it was written first.

The reason to expect a win: MusicGen's decoder runs 1,500 autoregressive steps,
and at batch 1 each step reads 1.5B parameters out of VRAM to do a handful of
tiny matmuls. That is memory-bandwidth-bound, not compute-bound, so several
sequences can ride along on the same weight reads nearly free -- until the KV
cache grows enough to run the card out of memory, which on an 8 GB laptop 4060
is the thing that will actually bite.

Both halves get measured here: seconds per clip, and peak VRAM.

    python tool/bench_batch.py                  # 1, 2, 4
    python tool/bench_batch.py --batches 1 2 4 8
    python tool/bench_batch.py --seconds 10     # quicker, less representative
"""

import argparse
import time

SECONDS = 30
TOKENS_PER_SECOND = 50
DEFAULT_MODEL = "facebook/musicgen-stereo-medium"

# Eight real prompts would be better still, but the point of measurement here
# is the decode loop, which does not care what the text says -- only how many
# sequences are in flight.
PROMPT = ("epic fantasy. Drama and Action. Orchestral with brass and "
          "percussion; sustained pads, wide reverb. Slow ambient underscore, "
          "around 60 BPM. Sustained, quiet and static, a single held texture "
          "-- background score that sits underneath someone reading.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--batches", type=int, nargs="*", default=[1, 2, 4])
    parser.add_argument("--seconds", type=int, default=SECONDS)
    parser.add_argument("--guidance", type=float, default=3.0,
                        help="3.0 is what the generator uses. Classifier-free "
                             "guidance doubles the effective batch, so 1.0 "
                             "halves the work -- at a quality cost this does "
                             "not measure")
    args = parser.parse_args()

    import torch
    from transformers import AutoProcessor, MusicgenForConditionalGeneration

    if not torch.cuda.is_available():
        raise SystemExit("no CUDA device; this benchmark needs one")

    name = torch.cuda.get_device_name(0)
    total = torch.cuda.get_device_properties(0).total_memory / 2**30
    print(f"{name}, {total:.1f} GiB")
    print(f"{args.model}, {args.seconds}s clips, guidance {args.guidance}\n")

    started = time.time()
    processor = AutoProcessor.from_pretrained(args.model)
    model = MusicgenForConditionalGeneration.from_pretrained(
        args.model, dtype=torch.float16).to("cuda")
    weights = torch.cuda.memory_allocated() / 2**30
    print(f"loaded in {time.time() - started:.1f}s, weights {weights:.2f} GiB\n")

    tokens = args.seconds * TOKENS_PER_SECOND
    print(f"{'batch':>5}  {'wall s':>8}  {'s/clip':>8}  {'speedup':>8}  "
          f"{'peak GiB':>9}")
    print("-" * 48)

    baseline = None
    for batch in args.batches:
        torch.cuda.empty_cache()
        torch.cuda.reset_peak_memory_stats()
        inputs = processor(text=[PROMPT] * batch, padding=True,
                           return_tensors="pt").to("cuda")
        try:
            torch.manual_seed(0)
            # One short warm-up so the first timing is not paying for lazy
            # kernel selection and autotuning.
            with torch.no_grad():
                model.generate(**inputs, do_sample=True,
                               guidance_scale=args.guidance, max_new_tokens=16)
            torch.cuda.synchronize()

            torch.manual_seed(0)
            began = time.time()
            with torch.no_grad():
                model.generate(**inputs, do_sample=True,
                               guidance_scale=args.guidance,
                               max_new_tokens=tokens)
            torch.cuda.synchronize()
            wall = time.time() - began
        # Not just torch.OutOfMemoryError: once the card is genuinely full the
        # failure surfaces asynchronously as a plain RuntimeError from whatever
        # call happens to sync next, which is how batch 4 got past this.
        except (torch.OutOfMemoryError, RuntimeError) as error:
            if "out of memory" not in str(error).lower():
                raise
            print(f"{batch:>5}  {'OOM':>8}  {'':>8}  {'':>8}  "
                  f"{torch.cuda.max_memory_reserved() / 2**30:>9.2f}")
            torch.cuda.empty_cache()
            continue

        per = wall / batch
        baseline = baseline or per
        peak = torch.cuda.max_memory_reserved() / 2**30
        print(f"{batch:>5}  {wall:>8.1f}  {per:>8.1f}  "
              f"{baseline / per:>7.2f}x  {peak:>9.2f}")

    print("\nspeedup is throughput against batch 1: 2.00x means a 32-bed "
          "palette takes half as long.")


if __name__ == "__main__":
    main()
