"""cull_by_movement, over the permutation that broke it.

Run: python framework/python/tests/test_cull.py

Ported from phase1/tool/test_cull.py; only the imports changed.

The bug this exists for: renumbering the survivors is a permutation, not a
sequence of moves. On the real arc-0 run `tense-0-v13` became `tense-0-v3`
while the surviving `tense-0-v3` became `tense-0-v6`, so a dict re-keyed as
it was walked lost an entry that was still needed -- and it failed three
hours in, after the cull had printed a correct-looking result, with a
KeyError from the manifest loop. Cheap to pin, expensive to rediscover.

What is under test is the bookkeeping: which take survives, what it is
renamed to, that its report and slot travel with it, and that nothing is
left on disk. The movement *measurement* is bench_palette's own and is
exercised on real beds (SUMMARY 9.29), so here it is stubbed -- otherwise
the test would be a search for synthetic audio that happens to rank in a
chosen order, which tests the wrong thing and fails for the wrong reasons.

No GPU, no model, no real audio.
"""

import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from music_book_gen import cull as generate_beds
from music_book_gen import loopify
from music_book_gen import measure as bench_palette


def touch_wav(path: Path) -> None:
    """A valid, tiny wav. Only its existence and name matter here."""
    loopify.write_wav(path, np.zeros((2205, 2), dtype=np.float32))


def stub_movement(by_stem: dict[str, tuple[float, float]],
                  centroid: dict[str, float] | None = None):
    """Make bench_palette.measure report a chosen flux/onsets per file, and
    for the register gate a chosen centroid (800 Hz where none is given)."""
    def measure(path):
        stem = Path(path).stem
        flux, onsets = by_stem[stem]
        return {"flux": flux, "onsets": onsets, "rms": 0.1,
                "centroid": (centroid or {}).get(stem, 800.0),
                "rms_cv": 0.5, "chroma": np.zeros(12)}
    return measure


def fake_report(usable: bool = True) -> dict:
    return {"usable": usable, "audible": usable, "centroid_hz": 800.0,
            "energy_above_200hz": 0.9 if usable else 0.01}


def run_cull(out: Path, cue: str, band: int, pool: int, keep: int,
             rank: list[int], usable: set[int] | None = None):
    """Build a pool of takes, stub their movement so they rank as [rank],
    and cull. Returns (survivors, best, stems)."""
    stems = [cue if v == 0 else f"{cue}-v{v}" for v in range(pool)]
    usable = set(range(pool)) if usable is None else usable
    # Band 0 keeps the stillest, band 1 the busiest, so flux and onsets
    # ascend with rank position for band 0 and descend for band 1.
    movement = {}
    for position, take in enumerate(rank):
        steps = position if band == 0 else pool - 1 - position
        movement[stems[take]] = (100.0 + 10.0 * steps, 2.0 + 0.5 * steps)
    bench_palette.measure = stub_movement(movement)

    wanted, best = {}, {}
    for v, stem in enumerate(stems):
        touch_wav(out / f"{stem}.wav")
        touch_wav(out / f"{stem}.raw.wav")
        wanted[stem] = {"stem": stem, "cue": cue, "mood": "tense",
                        "band": band, "variant": v, "keep": keep,
                        "prompt": f"prompt for {stem}"}
        # The clip and loop are opaque to the cull, so tag them: a report
        # that travels to the wrong name is then visible, not merely wrong.
        best[stem] = ((v not in usable, 0.0), f"clip:{stem}", f"loop:{stem}",
                      fake_report(usable=v in usable))
    survivors = generate_beds.cull_by_movement(out, wanted, best)
    return survivors, best, stems


def case(name: str, band: int, rank: list[int], keep: int,
         usable: set[int] | None = None, expect: list[int] | None = None):
    """[rank] is a full permutation of the pool, in the order the cull should
    produce. [expect] overrides which takes survive, for the case where an
    unusable take is demoted out of its movement rank."""
    out = Path(tempfile.mkdtemp())
    try:
        pool = len(rank)
        assert sorted(rank) == list(range(pool)), f"{name}: not a permutation"
        cue = f"tense-{band}"
        survivors, best, stems = run_cull(out, cue, band, pool, keep, rank,
                                          usable)
        survived = rank[:keep] if expect is None else expect

        names = [cue if i == 0 else f"{cue}-v{i}" for i in range(keep)]
        assert list(survivors) == names, f"{name}: names {list(survivors)}"
        assert len(best) == keep, f"{name}: best holds {len(best)}"
        for i, new in enumerate(names):
            was = stems[survived[i]]
            assert new in best, f"{name}: {new} lost from best"
            assert best[new][1] == f"clip:{was}", (
                f"{name}: {new} carries {best[new][1]}, wanted clip:{was}")
            assert best[new][2] == f"loop:{was}", f"{name}: {new} loop"
            assert survivors[new]["variant"] == i, f"{name}: {new} variant"
            assert survivors[new]["stem"] == new, f"{name}: {new} stem"
            assert survivors[new]["prompt"] == f"prompt for {was}", (
                f"{name}: {new} prompt")
        on_disk = {p.name for p in out.glob("*")}
        assert on_disk == {f"{n}{s}" for n in names
                           for s in (".wav", ".raw.wav")}, (
            f"{name}: files on disk {sorted(on_disk)}")
        print(f"  ok  {name}")
    finally:
        shutil.rmtree(out, ignore_errors=True)


def movement_recorded():
    out = Path(tempfile.mkdtemp())
    try:
        _, best, _ = run_cull(out, "tense-1", 1, pool=3, keep=2,
                              rank=[2, 0, 1])
        for new in ("tense-1", "tense-1-v1"):
            row = best[new][3]
            assert "movement" in row, f"{new}: {row}"
            assert set(row["movement"]) == {"flux", "onsets"}, row["movement"]
        # The busiest survives first, so its recorded flux is the higher one.
        assert (best["tense-1"][3]["movement"]["flux"]
                > best["tense-1-v1"][3]["movement"]["flux"])
        print("  ok  each kept take records what it was ranked on")
    finally:
        shutil.rmtree(out, ignore_errors=True)


def nothing_to_do():
    out = Path(tempfile.mkdtemp())
    try:
        survivors, best, _ = run_cull(out, "calm-0", 0, pool=1, keep=1,
                                      rank=[0])
        assert list(survivors) == ["calm-0"], list(survivors)
        assert best["calm-0"][1] == "clip:calm-0"
        print("  ok  one take for one slot is left alone")
    finally:
        shutil.rmtree(out, ignore_errors=True)


# The register gate (SUMMARY 9.35, 9.36). It needs both bands of a mood in
# one cull, because the line it gates on sits between them -- so these build
# two cues at once, where everything above builds one. Every single-band case
# above is also a case of the gate standing aside: a mood with one band has
# no line to be on the wrong side of.

def cull_two_bands(out: Path, keep: tuple[int, int],
                   takes: tuple[list, list], unusable: set[str] = frozenset(),
                   register_gate: bool = True):
    """Both bands of `tense` through one cull. [takes] is, per band, a list
    of (centroid, flux, onsets) in take order. Returns, per band, the
    *original* stems of the survivors in their new order, and `best`."""
    movement, centroid, wanted, best = {}, {}, {}, {}
    for band in (0, 1):
        cue = f"tense-{band}"
        for v, (c, flux, onsets) in enumerate(takes[band]):
            stem = cue if v == 0 else f"{cue}-v{v}"
            movement[stem], centroid[stem] = (flux, onsets), c
            touch_wav(out / f"{stem}.wav")
            touch_wav(out / f"{stem}.raw.wav")
            wanted[stem] = {"stem": stem, "cue": cue, "mood": "tense",
                            "band": band, "variant": v, "keep": keep[band],
                            "prompt": f"prompt for {stem}"}
            ok = stem not in unusable
            best[stem] = ((not ok, 0.0), f"clip:{stem}", f"loop:{stem}",
                          fake_report(usable=ok))
    bench_palette.measure = stub_movement(movement, centroid)
    survivors = generate_beds.cull_by_movement(out, wanted, best,
                                               register_gate=register_gate)
    # The renaming bookkeeping must hold with the gate as without it.
    on_disk = {p.name for p in out.glob("*")}
    assert on_disk == {f"{n}{s}" for n in survivors
                       for s in (".wav", ".raw.wav")}, sorted(on_disk)
    kept = {band: [best[new][1].removeprefix("clip:") for new in survivors
                   if survivors[new]["band"] == band] for band in (0, 1)}
    return kept, best


def in_a_temp_dir(test):
    def run():
        out = Path(tempfile.mkdtemp())
        try:
            test(out)
        finally:
            shutil.rmtree(out, ignore_errors=True)
    return run


@in_a_temp_dir
def gate_drops_the_wrong_register(out):
    # Band 0 median 550 Hz, band 1 median 1,900 Hz: the line is their
    # geometric mean, 1,022 Hz. tense-0-v1 is the stillest take in its band
    # and 1,500 Hz -- tense-0-v7's shape (SUMMARY 9.35). tense-1-v1 is the
    # busiest in its band and 900 Hz, darker than the line.
    takes = ([(400, 100, 2.0), (1500, 90, 1.5), (500, 110, 2.5),
              (600, 150, 4.0)],
             [(2000, 150, 4.0), (900, 220, 6.0), (1800, 180, 5.0),
              (2200, 120, 3.0)])
    kept, best = cull_two_bands(out, (2, 2), takes)
    assert kept[0] == ["tense-0", "tense-0-v2"], kept[0]
    assert kept[1] == ["tense-1-v2", "tense-1"], kept[1]
    row = best["tense-0"][3]["register"]
    assert row == {"bench_centroid": 400, "floor": None, "ceiling": 1022,
                   "inside": True}, row
    assert best["tense-1"][3]["register"]["floor"] == 1022
    print("  ok  the gate drops a still take in the peak's register, and "
          "the reverse")


@in_a_temp_dir
def gate_off_is_the_old_cull(out):
    # The same pool with the gate off keeps exactly what movement alone
    # chooses -- which is how arc-000's beds on disk were culled.
    takes = ([(400, 100, 2.0), (1500, 90, 1.5), (500, 110, 2.5),
              (600, 150, 4.0)],
             [(2000, 150, 4.0), (900, 220, 6.0), (1800, 180, 5.0),
              (2200, 120, 3.0)])
    kept, best = cull_two_bands(out, (2, 2), takes, register_gate=False)
    assert kept[0] == ["tense-0-v1", "tense-0"], kept[0]
    assert kept[1] == ["tense-1-v1", "tense-1-v2"], kept[1]
    assert all("register" not in best[st][3] for st in best)
    print("  ok  --no-register-gate culls on movement alone")


@in_a_temp_dir
def gate_that_cannot_fill_falls_back(out):
    # Band 0 median 1,000, band 1 median 2,100: the line is 1,449 Hz. Two of
    # band 0's four takes are over it and three are wanted, so one must come
    # from outside -- the nearer one, 1,500 Hz, even though the 1,700 Hz one
    # is the stillest take in the pool. Being on the right side of the line
    # is what failed, so nearness to it is what orders the fallback.
    takes = ([(400, 120, 3.0), (1700, 90, 1.5), (1500, 130, 3.5),
              (500, 110, 2.5)],
             [(2000, 150, 4.0), (2400, 220, 6.0), (1800, 180, 5.0),
              (2200, 120, 3.0)])
    kept, best = cull_two_bands(out, (3, 2), takes)
    assert kept[0] == ["tense-0-v3", "tense-0", "tense-0-v2"], kept[0]
    assert best["tense-0-v2"][3]["register"]["inside"] is False
    assert best["tense-0"][3]["register"]["inside"] is True
    assert kept[1] == ["tense-1-v1", "tense-1-v2"], kept[1]
    print("  ok  a band the gate cannot fill keeps the nearest outside, "
          "not a crash")


@in_a_temp_dir
def gated_ranks_ahead_of_unusable(out):
    # An inaudible take is worse than one in the wrong register. The
    # unusable take is also the darkest and stillest, and does not count
    # towards the line: 950 and 2,100 give 1,412 Hz.
    takes = ([(400, 110, 2.5), (1500, 120, 3.0), (300, 80, 1.0)],
             [(2000, 150, 4.0), (2200, 180, 5.0)])
    kept, _ = cull_two_bands(out, (2, 1), takes, unusable={"tense-0-v2"})
    assert kept[0] == ["tense-0", "tense-0-v1"], kept[0]
    print("  ok  a take outside the line still ranks ahead of an unusable one")


@in_a_temp_dir
def no_line_without_the_other_band(out):
    # Every peak take failed the audibility guard, so there is no band 1 to
    # draw a line against, and band 0 culls on movement alone.
    takes = ([(400, 110, 2.5), (1500, 90, 1.5), (500, 130, 3.5)],
             [(900, 150, 4.0), (1000, 180, 5.0)])
    kept, best = cull_two_bands(out, (2, 1), takes,
                                unusable={"tense-1", "tense-1-v1"})
    assert kept[0] == ["tense-0-v1", "tense-0"], kept[0]
    assert "register" not in best["tense-0"][3]
    print("  ok  no usable takes in the other band means no line")


if __name__ == "__main__":
    real_measure = bench_palette.measure
    try:
        print("cull_by_movement")
        # The permutation from the real run: eleven survivors of twenty-two,
        # sending take 13 to -v3 while the surviving take 3 goes to -v6. The
        # in-place version of this function failed exactly here, and only
        # here -- every smaller case passed.
        kept = [8, 10, 9, 13, 17, 4, 3, 19, 15, 11, 5]
        case("the arc-0 permutation, band 0", band=0,
             rank=kept + [v for v in range(22) if v not in kept], keep=11)
        case("a straight swap", band=0, rank=[1, 0], keep=2)
        case("already in order", band=0, rank=[0, 1, 2], keep=3)
        case("a cycle of three", band=0, rank=[2, 0, 1], keep=3)
        case("busiest first for the peak band", band=1, rank=[2, 0, 1], keep=2)
        case("keep one of many", band=1, rank=[3, 0, 1, 2], keep=1)
        # The stillest take never passed the guard, so it must rank behind
        # both usable ones however quiet it measures.
        case("an unusable take ranks last however it measures", band=0,
             rank=[0, 1, 2], keep=2, usable={1, 2}, expect=[1, 2])
        movement_recorded()
        nothing_to_do()
        print("register gate")
        gate_drops_the_wrong_register()
        gate_off_is_the_old_cull()
        gate_that_cannot_fill_falls_back()
        gated_ranks_ahead_of_unusable()
        no_line_without_the_other_band()
        print("all passed")
    finally:
        bench_palette.measure = real_measure
