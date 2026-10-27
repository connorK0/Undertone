"""Run an offload job on a Modal GPU, and bring the pool home.

    python -m music_book_gen export <workspace> --arc 0 --overgen 3 --out job.json
    $env:OFFLOAD_GPU = "A10"      # optional; A10 is the default
    modal run framework/python/music_book_gen/modal_app.py --job job.json [--out <dir>]
    python -m music_book_gen import <workspace> --job job.json --results <dir>/beds

`modal` is the CLI in phase1/.venv/Scripts. It needs `modal token new` once,
which opens a browser and keeps the token in ~/.modal.toml -- outside the repo.

What goes up is the job (prompts, keys, seeds -- no book text, see
music_book_gen.jobs), runner.py and loopify.py. What runs there is runner.py
unchanged: generate every take of the pool, apply the audibility guard,
re-seed what fails. What comes back is the whole pool. The movement cull and
the register gate run at home, on import. This file is only transport.

Three things about running on Modal that shape it:

  * **GPU functions are preemptible and cannot opt out.** A preempted
    function restarts on the same input. runner.py resumes from every
    take already written, so a restart costs the take in flight, not the set.
    The beds live on a Volume for that reason: it outlives the container.
  * **The local side can go away.** With `modal run --detach` the job keeps
    going if this machine sleeps; the download below then never runs, and
    the results are fetched afterwards with
        modal volume get music-book-beds <run name>/beds <local dir>
    Re-running with the same --name also resumes a run that died.
  * **The image pins what phase1/.venv has** -- Python 3.13, torch 2.6.0,
    transformers 5.16.1 -- so a difference between a cloud set and a local
    one is the GPU's, not a library's. It will still not reproduce a local
    take at the same seed: sampling on different hardware diverges.
"""

import os
import pathlib
import subprocess
import sys
import time

import modal

TOOL = pathlib.Path(__file__).resolve().parent

# Which GPU, chosen before the app is built. It has to be: Modal validates the
# decorator's static value when the app starts, so a call-time
# `with_options(gpu=...)` never got the chance to replace it -- the first real
# run asked for an A10 and was refused over the default. Baked into the image
# too, so the container evaluates the same decorator the laptop did.
GPU = os.environ.get("OFFLOAD_GPU", "A10")

image = (
    modal.Image.debian_slim(python_version="3.13")
    .uv_pip_install("torch==2.6.0", "transformers==5.16.1", "numpy==2.5.3",
                    "soundfile==0.14.0")
    .env({"HF_HOME": "/cache/huggingface", "OFFLOAD_GPU": GPU})
    .add_local_file(TOOL / "runner.py", "/root/runner.py")
    .add_local_file(TOOL / "loopify.py", "/root/loopify.py")
)
app = modal.App("music-book-offload", image=image)

# The model's weights download once, not once per run.
weights = modal.Volume.from_name("music-book-hf-cache", create_if_missing=True)
# Where the beds land. The Volume commits in the background while the
# function runs, so what has settled survives a preemption or a timeout.
beds = modal.Volume.from_name("music-book-beds", create_if_missing=True)

# Modal's list prices, 2026-09-24, per GPU-second. Only for the estimate this
# prints at the end; CPU and memory are billed on top, and are small.
PRICE = {"T4": 0.000164, "L4": 0.000222, "A10": 0.000306, "L40S": 0.000542,
         "A100-40GB": 0.000583, "A100-80GB": 0.000694, "H100": 0.001097}


@app.function(gpu=GPU, timeout=8 * 3600, retries=0,
              volumes={"/cache": weights, "/beds": beds})
def run(job_text: str, name: str, batch: int) -> int:
    folder = pathlib.Path("/beds") / name
    folder.mkdir(parents=True, exist_ok=True)
    job = folder / "job.json"
    job.write_text(job_text, encoding="utf-8")
    command = [sys.executable, "-u", "/root/runner.py", str(job),
               "--out", str(folder / "beds")]
    if batch:
        command += ["--batch", str(batch)]
    code = subprocess.call(command)
    beds.commit()
    return code


def download(name: str, dest: pathlib.Path) -> int:
    """Everything under <name>/beds on the Volume, into dest/beds."""
    count = 0
    for entry in beds.listdir(f"{name}/beds", recursive=True):
        if entry.type != modal.volume.FileEntryType.FILE:
            continue
        relative = pathlib.PurePosixPath(entry.path.lstrip("/")).relative_to(
            name)
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as handle:
            for chunk in beds.read_file(entry.path):
                handle.write(chunk)
        count += 1
    return count


@app.local_entrypoint()
def main(job: str, batch: int = 0, out: str = "", name: str = ""):
    path = pathlib.Path(job).resolve()
    name = name or f"{path.stem}-{time.strftime('%Y%m%d-%H%M%S')}"
    dest = pathlib.Path(out).resolve() if out else path.parent / name
    print(f"{name}: on {GPU}, beds to volume music-book-beds/{name}/beds",
          flush=True)

    started = time.time()
    code = run.remote(path.read_text(encoding="utf-8"), name, batch)
    took = time.time() - started
    cost = (f", about ${took * PRICE[GPU]:.2f} of GPU at list price"
            if GPU in PRICE else "")
    print(f"runner exited {code} after {took / 60:.1f} min{cost}")

    files = download(name, dest)
    print(f"downloaded {files} file(s) to {dest / 'beds'}")
    print(f"next: python -m music_book_gen import <workspace> --job {path} "
          f"--results {dest / 'beds'}")
    if code:
        sys.exit(code)
