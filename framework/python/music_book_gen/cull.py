"""Choosing which takes of a cue survive: movement, behind the register gate.

Extracted verbatim from phase1/tool/generate_beds.py (SUMMARY 9.29-9.36). The
movement measure is bench_palette's, reached through the `measure` module so
a test can stub it -- the same seam tool/test_cull.py used.
"""

from __future__ import annotations

import math
import statistics

from . import measure as bench_palette


def register_limits(wanted: dict, centroid: dict) -> dict:
    """Each banded cue's brightness limits, {(mood, band): [floor, ceiling]}.

    One line between each pair of adjacent bands of a mood, at the geometric
    mean of the two bands' median centroids: halfway between where the
    prompt put each band's typical take, on the log scale pitch is heard on.
    A band's ceiling is its line to the band above and its floor its line to
    the band below; the outermost bands have None on the open side.

    One line rather than "band 0 below band 1's darkest, and vice versa",
    because before the cull neither band's darkest or brightest *kept* take
    exists yet, and the pool's extremes are single outliers. Taken from the
    pool, the "vice versa" half sets band 1's floor at band 0's brightest
    take -- on arc 0's live set, tense-0-v4 at 1,632 Hz, which would reject 6
    of 13 peak takes. A line between the medians cannot be set by one take.

    [centroid] is bench_palette's, per take -- not loopify's centroid_hz,
    which is a different number (SUMMARY 9.34). Only usable takes count: an
    inaudible take's register is not one the reader hears.
    """
    by_band: dict[tuple[str, int], list[float]] = {}
    for stem, slot in wanted.items():
        if slot["band"] is not None and stem in centroid:
            by_band.setdefault((slot["mood"], slot["band"]), []).append(
                centroid[stem])
    limits = {key: [None, None] for key in by_band}
    for mood in sorted({mood for mood, _ in by_band}):
        bands = sorted(band for m, band in by_band if m == mood)
        for low, high in zip(bands, bands[1:]):
            line = math.sqrt(statistics.median(by_band[mood, low])
                             * statistics.median(by_band[mood, high]))
            limits[mood, low][1] = line
            limits[mood, high][0] = line
    return limits


def cull_by_movement(out, wanted: dict, best: dict,
                     register_gate: bool = True) -> dict:
    """Keep each cue's `keep` takes by measured movement; delete the rest.

    Returns the surviving slots, renumbered so that variant 0 has the cue's
    own name and the rest are -v1, -v2 ... in the order they ranked. Files
    are renamed to match and `best` is re-keyed in place, so everything
    downstream -- the manifest, the identical-takes check -- sees a set that
    was generated at the plan's own counts.

    Band 0 keeps the stillest, band 1 the busiest, an unbanded cue the
    stillest (it is the whole mood, and a bed under prose errs still).
    Ranked by flux rank plus onset rank rather than a z-score, because a
    pool of two has no standard deviation worth the name. Unusable takes
    rank last whatever they measure: they are inaudible.

    Before any of that, the register gate (SUMMARY 9.35). Movement is one
    lever and brightness the other, and the cull used to see only the
    first: tense-0-v7, bright and middling-still, passed on its movement and
    made 12 of its 13 crossings to tense-1 inaudible. So a take on the wrong
    side of its band's line (see register_limits) ranks behind every take on
    the right side, however it moves. It is demoted, not dropped: if too few
    takes are inside the line to fill the band, the nearest ones outside it
    fill the gap and a warning says so -- more headroom is --overgen's job,
    and a run hours in must not die for want of it. A gated take still ranks
    ahead of an unusable one, since a bed in the wrong register is at least
    audible.

    Nothing is re-keyed in place. Renumbering is a permutation, not a
    sequence of moves: `tense-0-v13` becomes `tense-0-v3` while the real
    `tense-0-v3` becomes `tense-0-v6`, so any dict updated as it is walked
    loses an entry it still needs -- which is exactly what happened, three
    hours into a run, after the cull had already printed its results. Both
    the slots and the reports are collected into fresh dicts and swapped in
    at the end, and the files go through a .tmp pass for the same reason.
    """
    # Every usable take is measured before any cue is culled, because the
    # register gate needs both bands of a mood to place the line between them.
    measured = {st: bench_palette.measure(out / f"{st}.wav")
                for st in wanted if best[st][3]["usable"]}
    centroid = {st: m["centroid"] for st, m in measured.items() if m}
    limits = register_limits(wanted, centroid) if register_gate else {}

    survivors = {}
    carried = {}
    for cue in sorted({slot["cue"] for slot in wanted.values()}):
        stems = [st for st, slot in wanted.items() if slot["cue"] == cue]
        keep = wanted[stems[0]]["keep"]
        mood = wanted[stems[0]]["mood"]
        band = wanted[stems[0]]["band"]
        usable = [st for st in stems if st in measured]
        unusable = sorted((st for st in stems if st not in usable),
                          key=lambda st: best[st][0])
        movement = {st: (measured[st]["flux"], measured[st]["onsets"])
                    if measured[st] else (0.0, 0.0) for st in usable}
        floor, ceiling = limits.get((mood, band), (None, None))

        def outside(st):
            """How far past the line a take is, as a log ratio; 0 if inside.
            A take bench_palette could not measure is not judged."""
            c = centroid.get(st)
            if c is None:
                return 0.0
            if ceiling is not None and c > ceiling:
                return math.log(c / ceiling)
            if floor is not None and c < floor:
                return math.log(floor / c)
            return 0.0

        inside = [st for st in usable if outside(st) == 0.0]
        gated = sorted((st for st in usable if st not in inside), key=outside)
        by_flux = sorted(inside, key=lambda st: movement[st][0])
        by_onset = sorted(inside, key=lambda st: movement[st][1])
        ranked = sorted(inside,
                        key=lambda st: by_flux.index(st) + by_onset.index(st))
        if band == 1:
            ranked.reverse()
        chosen = (ranked + gated + unusable)[:keep]
        for st in chosen:
            if st in movement:
                best[st][3]["movement"] = {
                    "flux": round(movement[st][0], 1),
                    "onsets": round(movement[st][1], 2),
                }
            if (floor, ceiling) != (None, None) and st in centroid:
                best[st][3]["register"] = {
                    "bench_centroid": round(centroid[st]),
                    "floor": None if floor is None else round(floor),
                    "ceiling": None if ceiling is None else round(ceiling),
                    "inside": st in inside,
                }
        if (floor, ceiling) != (None, None):
            line = (f"under {ceiling:.0f} Hz" if floor is None
                    else f"over {floor:.0f} Hz" if ceiling is None
                    else f"between {floor:.0f} and {ceiling:.0f} Hz")
            print(f"  {cue:16s} register gate: {len(inside)} of "
                  f"{len(usable)} usable takes {line} (bench centroid)"
                  + ("" if not gated else ", outside: " + ", ".join(
                      f"{st} {centroid[st]:.0f}" for st in gated)),
                  flush=True)
            short = [st for st in chosen if st in gated]
            if short:
                print(f"  !  {cue}: only {len(inside)} inside the line for "
                      f"{keep} slots, so {len(short)} kept from outside it, "
                      f"nearest first: " + ", ".join(
                          f"{st} {centroid[st]:.0f} Hz" for st in short)
                      + ". Raise --overgen for more headroom.", flush=True)
        if len(stems) > keep:
            print(f"  {cue:16s} kept {len(chosen)} of {len(stems)} by "
                  f"movement ({'busiest' if band == 1 else 'stillest'}): "
                  + ", ".join(f"{st} {movement[st][0]:.0f}/{movement[st][1]:.1f}"
                              for st in chosen if st in movement),
                  flush=True)
        for st in stems:
            if st not in chosen:
                for suffix in (".wav", ".raw.wav"):
                    (out / f"{st}{suffix}").unlink(missing_ok=True)
        # Renumber in two passes, since a survivor's new name may be a
        # dropped take's old one -- or another survivor's.
        names = {st: (cue if i == 0 else f"{cue}-v{i}")
                 for i, st in enumerate(chosen)}
        for st, new in names.items():
            if st != new:
                for suffix in (".wav", ".raw.wav"):
                    src = out / f"{st}{suffix}"
                    if src.exists():
                        src.rename(out / f"{st}.tmp{suffix}")
        for i, (st, new) in enumerate(names.items()):
            if st != new:
                for suffix in (".wav", ".raw.wav"):
                    tmp = out / f"{st}.tmp{suffix}"
                    if tmp.exists():
                        tmp.rename(out / f"{new}{suffix}")
            survivors[new] = dict(wanted[st], stem=new, variant=i)
            carried[new] = best[st]
    best.clear()
    best.update(carried)
    return survivors
