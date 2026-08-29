#!/usr/bin/env python3
"""Tempo, beat grid and downbeat estimation.

Musicians count in bars, not seconds. A beat grid turns "loop 41.2s to 46.8s"
into "loop bars 17 to 20", and lets the app snap seeking to something musical.

Detection is never certain, so every grid carries a confidence built from two
measurable things:

  regularity  How evenly spaced the beats are. A tracker that has locked on
              produces near-constant inter-beat intervals; one that is guessing
              wanders.

  fit         An F-measure between the beats and the onsets actually heard.
              Precision asks how many beats land on a real onset, which
              punishes a grid running too fast into the gaps; recall asks how
              many onsets got a beat, which punishes one running too slow.

Both halves are needed. An earlier version scored only "how loud is the audio
at the beats", and that quietly rewards *sparse* grids: a half-time grid keeps
only the strongest beats, so it scored better than the truth (3.09 against
2.56) and won. Precision alone will always prefer a slower grid; recall is what
holds it honest.

The grid maths (bars, beats, snapping, uniform grids) is pure standard library
and is tested without audio; only :func:`detect` needs librosa.
"""

from __future__ import annotations

import bisect
import math
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

__all__ = ["TempoGrid", "detect", "uniform_grid"]

DEFAULT_BEATS_PER_BAR = 4


@dataclass
class TempoGrid:
    """A beat grid with the confidence of the estimate that produced it."""

    bpm: float
    beats: List[float]                       # absolute times, ascending
    beats_per_bar: int = DEFAULT_BEATS_PER_BAR
    downbeat_index: int = 0                  # which beat starts bar 1
    confidence: float = 0.0
    regularity: float = 0.0
    clarity: float = 0.0
    precision: float = 0.0
    recall: float = 0.0
    downbeat_margin: float = 0.0
    clarity_ratio: float = 0.0     # raw onset strength at beats / average
    manual: bool = False
    source: str = "librosa.beat.beat_track"

    @property
    def first_downbeat(self) -> float:
        if not self.beats:
            return 0.0
        return self.beats[self.downbeat_index % max(1, len(self.beats))]

    @property
    def bar_starts(self) -> List[float]:
        return [
            self.beats[i]
            for i in range(self.downbeat_index, len(self.beats), self.beats_per_bar)
        ]

    def bar_and_beat(self, time: float) -> tuple[int, int]:
        """1-based ``(bar, beat)`` at ``time``. ``(0, 0)`` before the first beat."""
        if not self.beats or time < self.beats[0]:
            return (0, 0)
        index = bisect.bisect_right(self.beats, time) - 1
        offset = index - self.downbeat_index
        if offset < 0:
            return (0, 0)
        return (offset // self.beats_per_bar + 1, offset % self.beats_per_bar + 1)

    def snap_to_bar(self, time: float) -> float:
        """Nearest bar start, or ``time`` unchanged if there is no grid."""
        starts = self.bar_starts
        if not starts:
            return time
        index = bisect.bisect_left(starts, time)
        candidates = [starts[i] for i in (index - 1, index) if 0 <= i < len(starts)]
        return min(candidates, key=lambda t: abs(t - time)) if candidates else time

    def to_dict(self) -> Dict[str, Any]:
        return {
            "bpm": round(self.bpm, 3),
            "beats_per_bar": self.beats_per_bar,
            "first_downbeat_sec": round(self.first_downbeat, 4),
            "confidence": round(self.confidence, 3),
            "manual": self.manual,
            "source": self.source,
            "detail": {
                "regularity": round(self.regularity, 3),
                "clarity": round(self.clarity, 3),
                "precision": round(self.precision, 3),
                "recall": round(self.recall, 3),
                "downbeat_margin": round(self.downbeat_margin, 3),
                "clarity_ratio": round(self.clarity_ratio, 3),
                "beat_count": len(self.beats),
            },
        }


def uniform_grid(
    bpm: float,
    duration: float,
    first_beat: float = 0.0,
    beats_per_bar: int = DEFAULT_BEATS_PER_BAR,
    *,
    manual: bool = True,
    source: str = "manual",
) -> TempoGrid:
    """A perfectly even grid, for a manually supplied tempo."""
    if bpm <= 0:
        raise ValueError("bpm must be positive")
    interval = 60.0 / bpm
    # Walk back to the earliest beat at or after zero, so a downbeat given
    # mid-song still produces a grid covering the whole track.
    start = first_beat - math.floor(first_beat / interval) * interval
    count = max(0, int((duration - start) / interval) + 1)
    beats = [round(start + i * interval, 6) for i in range(count)]
    return TempoGrid(
        bpm=bpm,
        beats=beats,
        beats_per_bar=beats_per_bar,
        downbeat_index=0,
        confidence=1.0 if manual else 0.0,
        regularity=1.0,
        clarity=0.0,
        manual=manual,
        source=source,
    )


def _regularity(beats: Sequence[float]) -> float:
    """1 for a perfectly even grid, falling to 0 as the spacing wanders."""
    if len(beats) < 3:
        return 0.0
    gaps = [b - a for a, b in zip(beats, beats[1:])]
    mean = sum(gaps) / len(gaps)
    if mean <= 0:
        return 0.0
    variance = sum((g - mean) ** 2 for g in gaps) / len(gaps)
    cv = math.sqrt(variance) / mean
    return max(0.0, min(1.0, 1.0 - cv / 0.12))


def _match_rate(reference: Sequence[float], probe: Sequence[float],
                tolerance: float) -> float:
    """Fraction of ``probe`` times within ``tolerance`` of some reference time."""
    if not reference or not probe:
        return 0.0
    hits = 0
    for time in probe:
        index = bisect.bisect_left(reference, time)
        for i in (index - 1, index):
            if 0 <= i < len(reference) and abs(reference[i] - time) <= tolerance:
                hits += 1
                break
    return hits / len(probe)


def _restore_scipy_hann() -> None:
    """Put back ``scipy.signal.hann`` for librosa 0.10.1.

    SciPy 1.13 moved ``hann`` into ``scipy.signal.windows`` and dropped the old
    alias; librosa 0.10.1's beat tracker still calls the old name and dies with
    an AttributeError. Restoring the alias is deliberate rather than pinning or
    upgrading either package: the transcription engines are measured working
    against these exact versions, and a beat tracker is not worth risking that.
    """
    try:
        import scipy.signal

        if not hasattr(scipy.signal, "hann"):
            from scipy.signal.windows import hann

            scipy.signal.hann = hann  # type: ignore[attr-defined]
    except ImportError:
        pass


SEARCH_STARTS: Tuple[float, ...] = (90.0, 120.0, 150.0, 180.0)
TOLERANCE_SEC = 0.07   # how close a beat must be to an onset to count


def detect(
    audio,
    sample_rate: int,
    *,
    beats_per_bar: int = DEFAULT_BEATS_PER_BAR,
    start_bpm: Optional[float] = None,
) -> Optional[TempoGrid]:
    """Track the beat from several starting tempos and keep the best grid.

    librosa's tracker is steered by where the search begins, and on a fast song
    starting at 120 it can lock onto two thirds of the real tempo — measured on
    a 172 bpm track it returned 112.3, hearing three eighth notes as one beat.
    Starting nearer found 172.3 with *higher* confidence, so the score already
    ranks the right answer above the wrong one; only the starting point was at
    fault. Trying a spread and keeping the most confident result fixes it
    without hard-coding a tempo range.

    Pass ``start_bpm`` to force a single starting point.

    Returns None if librosa is missing or the track is too short to analyse.
    """
    try:
        import librosa
        import numpy as np
    except ImportError:
        return None

    if len(audio) < sample_rate:
        return None

    _restore_scipy_hann()
    onset_env = librosa.onset.onset_strength(y=audio, sr=sample_rate)

    starts = (start_bpm,) if start_bpm is not None else SEARCH_STARTS
    best: Optional[TempoGrid] = None
    for start in starts:
        grid = _track_from(onset_env, sample_rate, beats_per_bar, start, np, librosa)
        if grid is not None and (best is None or grid.confidence > best.confidence):
            best = grid
    return best


def _track_from(onset_env, sample_rate, beats_per_bar, start_bpm, np, librosa):
    tempo, beat_frames = librosa.beat.beat_track(
        onset_envelope=onset_env, sr=sample_rate, start_bpm=start_bpm
    )
    bpm = float(np.atleast_1d(tempo)[0])
    if len(beat_frames) < 4 or bpm <= 0:
        return None

    beats = [float(t) for t in librosa.frames_to_time(beat_frames, sr=sample_rate)]

    at_beats = onset_env[np.clip(beat_frames, 0, len(onset_env) - 1)]
    average = float(onset_env.mean()) or 1e-9
    ratio = float(at_beats.mean()) / average
    clarity = max(0.0, min(1.0, (ratio - 1.0) / 2.0))
    regularity = _regularity(beats)

    # Fit: precision punishes a grid that is too fast (beats landing in gaps),
    # recall punishes one that is too slow (onsets with no beat). Either alone
    # is biased; together they pin the tempo.
    onset_times = [
        float(t) for t in librosa.onset.onset_detect(
            onset_envelope=onset_env, sr=sample_rate, units="time"
        )
    ]
    precision = _match_rate(onset_times, beats, TOLERANCE_SEC)
    recall = _match_rate(beats, onset_times, TOLERANCE_SEC)
    fit = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0

    # Downbeat: assume a constant metre and choose the phase whose beats carry
    # the most onset weight. The margin over the runner-up says how sure that
    # choice is.
    scores: List[float] = []
    for phase in range(beats_per_bar):
        picked = at_beats[phase::beats_per_bar]
        scores.append(float(picked.mean()) if len(picked) else 0.0)
    best = max(range(beats_per_bar), key=lambda i: scores[i])
    ordered = sorted(scores, reverse=True)
    margin = 0.0 if ordered[0] <= 0 else (ordered[0] - ordered[1]) / ordered[0]

    return TempoGrid(
        bpm=bpm,
        beats=beats,
        beats_per_bar=beats_per_bar,
        downbeat_index=best,
        confidence=round(0.3 * regularity + 0.7 * fit, 4),
        regularity=regularity,
        clarity=clarity,
        precision=precision,
        recall=recall,
        downbeat_margin=margin,
        clarity_ratio=ratio,
    )


def describe_confidence(value: float) -> str:
    if value >= 0.75:
        return "strong"
    if value >= 0.5:
        return "usable"
    if value >= 0.25:
        return "weak — check it by ear"
    return "unreliable — set the bpm by hand"
