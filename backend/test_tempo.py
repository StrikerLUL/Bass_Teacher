#!/usr/bin/env python3
"""Tests for the beat grid. The grid maths needs no audio."""

from __future__ import annotations

import sys

from tempo import TempoGrid, _match_rate, describe_confidence, uniform_grid


def grid_at(bpm=120.0, duration=8.0, first_beat=0.0, beats_per_bar=4):
    return uniform_grid(bpm, duration, first_beat, beats_per_bar)


def test_uniform_grid_spacing():
    grid = grid_at(bpm=120.0, duration=4.0)
    assert grid.beats[:5] == [0.0, 0.5, 1.0, 1.5, 2.0]
    assert len(grid.beats) == 9          # 0.0 .. 4.0 inclusive
    assert grid.manual is True


def test_uniform_grid_rejects_nonsense_tempo():
    for bpm in (0, -30):
        try:
            uniform_grid(bpm, 10.0)
        except ValueError:
            continue
        raise AssertionError(f"bpm {bpm} should be rejected")


def test_grid_covers_the_track_even_from_a_late_downbeat():
    """A downbeat given mid-song still yields beats from the start."""
    grid = uniform_grid(120.0, 4.0, first_beat=2.25)
    assert grid.beats[0] < 0.5
    assert abs(grid.beats[0] - 0.25) < 1e-6


def test_bar_and_beat_counts_from_one():
    grid = grid_at(bpm=120.0, duration=8.0)     # beat every 0.5s, 4/4
    assert grid.bar_and_beat(0.0) == (1, 1)
    assert grid.bar_and_beat(0.5) == (1, 2)
    assert grid.bar_and_beat(1.5) == (1, 4)
    assert grid.bar_and_beat(2.0) == (2, 1)
    assert grid.bar_and_beat(4.0) == (3, 1)


def test_bar_and_beat_is_zero_before_the_first_beat():
    grid = uniform_grid(120.0, 8.0, first_beat=1.0)
    grid.beats = [1.0, 1.5, 2.0, 2.5, 3.0]
    assert grid.bar_and_beat(0.4) == (0, 0)


def test_bar_starts_follow_the_metre():
    grid = grid_at(bpm=120.0, duration=8.0)
    assert grid.bar_starts[:4] == [0.0, 2.0, 4.0, 6.0]

    three = grid_at(bpm=120.0, duration=8.0, beats_per_bar=3)
    assert three.bar_starts[:4] == [0.0, 1.5, 3.0, 4.5]


def test_snap_to_bar_takes_the_nearest():
    grid = grid_at(bpm=120.0, duration=8.0)     # bars at 0, 2, 4, 6, 8
    assert grid.snap_to_bar(2.1) == 2.0
    assert grid.snap_to_bar(3.4) == 4.0          # past halfway, rounds up
    assert grid.snap_to_bar(2.9) == 2.0
    assert grid.snap_to_bar(0.0) == 0.0
    assert grid.snap_to_bar(99.0) == 8.0         # clamped to the last bar


def test_snap_is_a_no_op_without_a_grid():
    empty = TempoGrid(bpm=0, beats=[])
    assert empty.snap_to_bar(12.3) == 12.3
    assert empty.bar_and_beat(12.3) == (0, 0)


def test_downbeat_index_shifts_the_bar_lines():
    grid = grid_at(bpm=120.0, duration=8.0)
    grid.downbeat_index = 2                      # bar 1 starts on the third beat
    assert grid.bar_starts[:3] == [1.0, 3.0, 5.0]
    assert grid.bar_and_beat(1.0) == (1, 1)
    assert grid.bar_and_beat(0.9) == (0, 0)


def test_to_dict_is_json_shaped():
    grid = grid_at(bpm=137.5, duration=4.0)
    document = grid.to_dict()
    assert document["bpm"] == 137.5
    assert document["beats_per_bar"] == 4
    assert document["manual"] is True
    assert set(document["detail"]) == {
        "regularity", "clarity", "precision", "recall",
        "downbeat_margin", "clarity_ratio", "beat_count",
    }


def test_confidence_wording():
    assert describe_confidence(0.9) == "strong"
    assert describe_confidence(0.6) == "usable"
    assert "check it" in describe_confidence(0.3)
    assert "by hand" in describe_confidence(0.1)


def test_match_rate_counts_hits_within_tolerance():
    reference = [0.0, 1.0, 2.0]
    assert _match_rate(reference, [0.0, 1.0, 2.0], 0.07) == 1.0
    assert _match_rate(reference, [0.5, 1.5], 0.07) == 0.0
    assert _match_rate(reference, [0.05, 1.5], 0.07) == 0.5
    assert _match_rate([], [1.0], 0.07) == 0.0
    assert _match_rate([1.0], [], 0.07) == 0.0


def test_a_half_time_grid_loses_on_recall():
    """The bias that made an earlier scoring pick half-time.

    Precision alone prefers the sparse grid; recall is what exposes it.
    """
    onsets = [i * 0.5 for i in range(16)]          # a hit every half second
    correct = onsets
    half = [i * 1.0 for i in range(8)]             # every other one

    assert _match_rate(onsets, correct, 0.07) == 1.0
    assert _match_rate(onsets, half, 0.07) == 1.0   # precision cannot tell them apart
    assert _match_rate(correct, onsets, 0.07) == 1.0
    assert _match_rate(half, onsets, 0.07) == 0.5   # recall can


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failures = 0
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {test.__name__}: {exc}")
        else:
            print(f"ok    {test.__name__}")
    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
