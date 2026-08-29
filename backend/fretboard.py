#!/usr/bin/env python3
"""Fretboard geometry and fingering assignment for bass transcriptions.

A MIDI pitch does not identify a place on a bass neck: E2 (40) can be played at
string 0 fret 12, string 1 fret 7, or string 2 fret 2.  Choosing badly produces a
"tab" that is technically correct and physically unplayable, because the hand
teleports up and down the neck between sixteenth notes.

This module picks positions with a Viterbi pass over the note sequence: every
note contributes a *position* cost (prefer low frets and open strings) and every
adjacent pair contributes a *travel* cost (fret distance, string crossings),
weighted by the time available to make the move.  Fast passages are therefore
forced into a compact box while slow passages are free to relocate.

Pure standard library — no numpy/torch/audio deps — so it imports and runs
without the ML stack installed:

    python fretboard.py        # self-test / demo
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

__all__ = [
    "Instrument",
    "Position",
    "NoteEvent",
    "FingeringConfig",
    "assign_fingerings",
    "annotate_hand_positions",
    "assign_fingers",
    "FingerConfig",
    "fingering_stats",
    "note_name_to_midi",
    "midi_to_name",
]

SHARP_NAMES: Tuple[str, ...] = (
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
)
_LETTER_SEMITONES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
_ACCIDENTALS = {"#": 1, "♯": 1, "b": -1, "♭": -1}


# --------------------------------------------------------------------------- #
# Note names
# --------------------------------------------------------------------------- #

def note_name_to_midi(name: str) -> int:
    """``"E1" -> 28``, ``"F#2" -> 42``, ``"Bb0" -> 22``.  MIDI 60 is C4."""
    text = name.strip()
    if not text:
        raise ValueError("empty note name")
    letter = text[0].upper()
    if letter not in _LETTER_SEMITONES:
        raise ValueError(f"bad note name: {name!r}")

    semitone = _LETTER_SEMITONES[letter]
    i = 1
    while i < len(text) and text[i] in _ACCIDENTALS:
        semitone += _ACCIDENTALS[text[i]]
        i += 1

    octave_text = text[i:]
    if not octave_text.lstrip("-").isdigit():
        raise ValueError(f"bad note name: {name!r}")
    return semitone + (int(octave_text) + 1) * 12


def midi_to_name(midi: int) -> str:
    """``28 -> "E1"``."""
    return f"{SHARP_NAMES[midi % 12]}{midi // 12 - 1}"


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class Position:
    """A place on the neck.  ``string`` 0 is the *lowest pitched* string (E)."""

    string: int
    fret: int


@dataclass
class NoteEvent:
    """One transcribed note.  Times are seconds from the start of the track."""

    start: float
    end: float
    midi: int
    velocity: float = 1.0
    octave_shift: int = 0          # semitone/12 applied to fit the instrument
    string: Optional[int] = None   # filled in by assign_fingerings()
    fret: Optional[int] = None
    hand: Optional[int] = None     # filled in by annotate_hand_positions()
    finger: Optional[int] = None   # filled in by assign_fingers(); 0 == open

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)

    @property
    def name(self) -> str:
        return midi_to_name(self.midi)


@dataclass(frozen=True)
class Instrument:
    """Tuning is given low string first, e.g. E1 A1 D2 G2 for a 4-string bass."""

    tuning: Tuple[int, ...] = (28, 33, 38, 43)  # E1 A1 D2 G2
    frets: int = 24

    @classmethod
    def from_names(cls, names: Sequence[str], frets: int = 24) -> "Instrument":
        if not names:
            raise ValueError("tuning must contain at least one string")
        return cls(tuple(note_name_to_midi(n) for n in names), frets)

    @property
    def string_count(self) -> int:
        return len(self.tuning)

    @property
    def lowest_midi(self) -> int:
        return min(self.tuning)

    @property
    def highest_midi(self) -> int:
        return max(open_note + self.frets for open_note in self.tuning)

    @property
    def tuning_names(self) -> List[str]:
        return [midi_to_name(m) for m in self.tuning]

    def midi_at(self, string: int, fret: int) -> int:
        return self.tuning[string] + fret

    def positions_for(self, midi: int, max_fret: Optional[int] = None) -> List[Position]:
        """Every playable place for ``midi``, lowest fret first."""
        limit = self.frets if max_fret is None else min(max_fret, self.frets)
        found = [
            Position(string, midi - open_note)
            for string, open_note in enumerate(self.tuning)
            if 0 <= midi - open_note <= limit
        ]
        found.sort(key=lambda p: (p.fret, p.string))
        return found

    def fit_pitch(self, midi: int) -> Tuple[int, int]:
        """Octave-shift ``midi`` into range.  Returns ``(pitch, octaves_shifted)``."""
        shift = 0
        while midi < self.lowest_midi and shift < 4:
            midi += 12
            shift += 1
        while midi > self.highest_midi and shift > -4:
            midi -= 12
            shift -= 1
        return midi, shift


@dataclass(frozen=True)
class FingeringConfig:
    """Cost weights for the fingering search.  Units are arbitrary but relative.

    The defaults are tuned for fast electric bass lines: sliding is expensive,
    crossing strings is cheap, and open strings are a small bonus because they
    free the fretting hand.
    """

    max_fret: Optional[int] = None      # None -> instrument.frets

    # --- travel between consecutive notes ---------------------------------- #
    move_cost: float = 0.50             # per fret of hand travel
    stretch: int = 4                    # frets reachable without moving the hand
    jump_penalty: float = 0.90          # extra, per fret beyond `stretch`
    string_cost: float = 0.15           # per string crossed
    fast_cross_penalty: float = 0.50    # crossing 2+ strings in a hurry
    fast_cross_sec: float = 0.12

    # A move gets cheaper the more time there is to make it.  weight =
    # clamp(time_ref / dt, min_time_weight, 1.0): full price under `time_ref`
    # seconds, fading to `min_time_weight` for leisurely gaps.
    time_ref: float = 0.35
    min_time_weight: float = 0.20

    # --- per-note position preference -------------------------------------- #
    fret_cost: float = 0.04             # mild pull towards the low frets
    open_string_bonus: float = -0.50    # negative == preferred
    comfort_fret: int = 12              # above here the frets get cramped
    high_fret_penalty: float = 0.08

    hand_window_sec: float = 0.75       # smoothing window for the hand anchor


# --------------------------------------------------------------------------- #
# Cost model
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class _HandState:
    """Playing ``pos`` with the fretting hand anchored at ``anchor`` since ``since``.

    ``anchor`` is the fret the hand is parked at, which is set by fretted notes
    only — an open string is reachable from anywhere and leaves the anchor where
    it was.  Carrying the anchor (rather than just the previous position) is
    what stops a run like *fret 7 -> open D -> A2* from talking itself into a
    fret-2 fingering: the hand never actually left fret 7.
    """

    pos: Position
    anchor: int      # 0 means "no anchor established yet"
    since: float     # when the anchor was set


def _position_cost(pos: Position, cfg: FingeringConfig) -> float:
    cost = cfg.fret_cost * pos.fret
    if pos.fret == 0:
        cost += cfg.open_string_bonus
    if pos.fret > cfg.comfort_fret:
        cost += cfg.high_fret_penalty * (pos.fret - cfg.comfort_fret)
    return cost


def _time_weight(gap: float, cfg: FingeringConfig) -> float:
    return min(1.0, max(cfg.min_time_weight, cfg.time_ref / max(gap, 1e-3)))


def _travel_cost(
    prev: _HandState, curr: Position, now: float, dt: float, cfg: FingeringConfig
) -> float:
    """Cost of playing ``curr`` at time ``now``, ``dt`` after the previous note."""
    # Crossing strings is a picking-hand problem: it is costed against the gap
    # between the two notes.
    crossed = abs(curr.string - prev.pos.string)
    cost = cfg.string_cost * crossed * _time_weight(dt, cfg)
    if crossed >= 2 and dt < cfg.fast_cross_sec:
        cost += cfg.fast_cross_penalty

    if curr.fret == 0 or prev.anchor == 0:
        return cost  # nothing for the fretting hand to do

    # Moving the hand is costed against the time since the anchor was set,
    # which is longer than `dt` whenever open strings intervene — the hand is
    # free to travel while they ring.
    distance = float(abs(curr.fret - prev.anchor))
    weight = _time_weight(now - prev.since, cfg)
    cost += cfg.move_cost * distance * weight
    if distance > cfg.stretch:
        cost += cfg.jump_penalty * (distance - cfg.stretch) * weight

    return cost


# --------------------------------------------------------------------------- #
# Fingering search
# --------------------------------------------------------------------------- #

def assign_fingerings(
    notes: Sequence[NoteEvent],
    instrument: Instrument,
    config: Optional[FingeringConfig] = None,
) -> List[NoteEvent]:
    """Fill in ``string``/``fret`` on every note, minimising total hand travel.

    Notes are mutated in place and also returned.  Notes with no playable
    position (out of range for the instrument) are left as ``None`` and split
    the sequence into independent segments.
    """
    cfg = config or FingeringConfig()
    count = len(notes)
    if count == 0:
        return list(notes)

    max_fret = cfg.max_fret if cfg.max_fret is not None else instrument.frets
    candidates: List[List[Position]] = [
        instrument.positions_for(note.midi, max_fret) for note in notes
    ]

    # Forward pass.  `pred[i]` is the previous note that had candidates, which
    # may not be `i - 1`; `back[i][k]` indexes the state chosen there.
    states: List[List[_HandState]] = [[] for _ in range(count)]
    costs: List[List[float]] = [[] for _ in range(count)]
    back: List[List[int]] = [[] for _ in range(count)]
    pred: List[int] = [-1] * count
    previous = -1

    for i, options in enumerate(candidates):
        if not options:
            previous = -1  # unplayable note: start a fresh segment after it
            continue
        note = notes[i]

        if previous < 0:
            states[i] = [_HandState(p, p.fret, note.start) for p in options]
            costs[i] = [_position_cost(p, cfg) for p in options]
            back[i] = [-1] * len(options)
            pred[i] = -1
            previous = i
            continue

        dt = max(note.start - notes[previous].start, 0.0)
        prior = states[previous]
        prior_costs = costs[previous]
        row_states: List[_HandState] = []
        row_cost: List[float] = []
        row_back: List[int] = []

        for pos in options:
            if pos.fret > 0:
                # A fretted note pins the anchor, so all incoming states
                # collapse into one: keep the cheapest predecessor.
                best, best_k = math.inf, 0
                for k, prev in enumerate(prior):
                    total = prior_costs[k] + _travel_cost(prev, pos, note.start, dt, cfg)
                    if total < best:
                        best, best_k = total, k
                row_states.append(_HandState(pos, pos.fret, note.start))
                row_cost.append(best + _position_cost(pos, cfg))
                row_back.append(best_k)
            else:
                # An open note inherits the anchor, so keep the cheapest path
                # per distinct incoming anchor.  Bounded by the candidate count
                # of the last fretted note, so this stays small.
                best_by_anchor: Dict[Tuple[int, float], Tuple[float, int]] = {}
                for k, prev in enumerate(prior):
                    total = prior_costs[k] + _travel_cost(prev, pos, note.start, dt, cfg)
                    key = (prev.anchor, prev.since)
                    if key not in best_by_anchor or total < best_by_anchor[key][0]:
                        best_by_anchor[key] = (total, k)
                open_cost = _position_cost(pos, cfg)
                for (anchor, since), (total, k) in best_by_anchor.items():
                    row_states.append(_HandState(pos, anchor, since))
                    row_cost.append(total + open_cost)
                    row_back.append(k)

        states[i] = row_states
        costs[i] = row_cost
        back[i] = row_back
        pred[i] = previous
        previous = i

    # Backward pass, once per segment (walking from the end of each chain).
    chosen: List[Optional[Position]] = [None] * count
    for end in range(count - 1, -1, -1):
        if not candidates[end] or chosen[end] is not None:
            continue
        row = costs[end]
        k = min(range(len(row)), key=row.__getitem__)
        i = end
        while i >= 0 and k >= 0:
            chosen[i] = states[i][k].pos
            next_k = back[i][k]
            i = pred[i]
            k = next_k

    for note, pos in zip(notes, chosen):
        note.string = None if pos is None else pos.string
        note.fret = None if pos is None else pos.fret

    return list(notes)


def annotate_hand_positions(
    notes: Sequence[NoteEvent], window_sec: float = 0.75
) -> List[NoteEvent]:
    """Tag each note with the lowest fret its neighbourhood needs.

    The UI uses this to draw the four-fret box the hand should be sitting in,
    and to scroll the neck.  Open strings are ignored: they are reachable from
    anywhere and would otherwise drag every box down to fret 0.
    """
    fretted = [(n.start, n.fret) for n in notes if n.fret is not None and n.fret > 0]
    if not fretted:
        for note in notes:
            note.hand = 0
        return list(notes)

    starts = [s for s, _ in fretted]
    lo = hi = 0
    last = fretted[0][1]

    for note in notes:
        while lo < len(starts) and starts[lo] < note.start - window_sec:
            lo += 1
        while hi < len(starts) and starts[hi] <= note.start + window_sec:
            hi += 1
        if lo < hi:
            last = min(fret for _, fret in fretted[lo:hi])
        note.hand = last

    return list(notes)


@dataclass(frozen=True)
class FingerConfig:
    """How the fretting hand covers the neck.

    ``span`` fingers cover ``span`` consecutive frets, one each. ``stretch`` is
    how far beyond that the hand will reach rather than move.
    """

    span: int = 4       # index, middle, ring, pinky
    stretch: int = 1    # one fret either side is a reach, not a shift


def assign_fingers(
    notes: Sequence[NoteEvent], config: Optional[FingerConfig] = None
) -> List[NoteEvent]:
    """Number the fretting fingers 1-4, given the hand position of each note.

    Inside the box it is one finger per fret, counting up from the index at the
    hand position. One fret past either edge is a stretch — the pinky reaches
    up, the index reaches back — because moving the whole hand for a single
    note is slower than reaching for it. Anything further means the hand has
    shifted, and a shift lands on the index.

    Requires :func:`annotate_hand_positions` to have run. Open strings get 0:
    nothing is fretted, so no finger is involved.
    """
    cfg = config or FingerConfig()
    for note in notes:
        if note.fret is None:
            note.finger = None
            continue
        if note.fret == 0:
            note.finger = 0
            continue

        hand = note.hand if note.hand and note.hand > 0 else note.fret
        offset = note.fret - hand

        if 0 <= offset < cfg.span:
            note.finger = offset + 1                 # in the box
        elif offset == cfg.span:
            note.finger = cfg.span                   # stretch up with the pinky
        elif -cfg.stretch <= offset < 0:
            note.finger = 1                          # reach back with the index
        else:
            note.finger = 1                          # shifted; land on the index
    return list(notes)


def fingering_stats(notes: Sequence[NoteEvent]) -> Dict[str, float]:
    """Playability + density metrics, handy for spotting a bad transcription."""
    played = [n for n in notes if n.fret is not None]
    if not played:
        return {"notes": 0}

    frets = [n.fret for n in played]
    # Hand travel is measured between consecutive *fretted* notes: open strings
    # in between do not move the hand, but they do not hide a jump either.
    anchors = [n.fret for n in played if n.fret > 0]
    jumps = [abs(b - a) for a, b in zip(anchors, anchors[1:])]
    span = max((n.end for n in notes), default=0.0) - min(n.start for n in notes)

    # Densest one-second window, via a sliding count over the onsets.
    onsets = sorted(n.start for n in notes)
    peak, lo = 0, 0
    for hi, onset in enumerate(onsets):
        while onset - onsets[lo] > 1.0:
            lo += 1
        peak = max(peak, hi - lo + 1)

    return {
        "notes": len(notes),
        "unplayable": len(notes) - len(played),
        "duration_sec": round(span, 3),
        "notes_per_sec": round(len(notes) / span, 2) if span > 0 else 0.0,
        "peak_notes_per_sec": peak,
        "pitch_low": midi_to_name(min(n.midi for n in notes)),
        "pitch_high": midi_to_name(max(n.midi for n in notes)),
        "fret_low": min(frets),
        "fret_high": max(frets),
        "open_string_ratio": round(sum(1 for f in frets if f == 0) / len(frets), 3),
        "mean_fret_jump": round(sum(jumps) / len(jumps), 2) if jumps else 0.0,
        "max_fret_jump": max(jumps) if jumps else 0,
    }


# --------------------------------------------------------------------------- #
# Demo / self-test
# --------------------------------------------------------------------------- #

def _demo() -> None:
    bass = Instrument.from_names(["E1", "A1", "D2", "G2"], frets=24)
    print(f"instrument: {'-'.join(bass.tuning_names)}  "
          f"{bass.frets} frets  range {midi_to_name(bass.lowest_midi)}"
          f"..{midi_to_name(bass.highest_midi)}")

    # A driving octave riff: the naive choice for each octave leap is a 12-fret
    # slide on one string; the search should cross strings and stay in a box.
    roots = [40, 38, 36, 35]            # E2 D2 C2 B1
    riff = [0, 0, 12, 0, 7, 0, 12, 0]   # sixteenths
    step = 0.1
    notes: List[NoteEvent] = []
    t = 0.0
    for root in roots:
        for offset in riff:
            notes.append(NoteEvent(start=t, end=t + step * 0.85, midi=root + offset))
            t += step

    assign_fingerings(notes, bass)
    annotate_hand_positions(notes)
    assign_fingers(notes)

    print("\n  time   note  str fret  hand  finger")
    for note in notes[:16]:
        print(f"  {note.start:5.2f}  {note.name:>4}   {note.string}   "
              f"{note.fret:>2}    {note.hand:>2}      {note.finger}")

    stats = fingering_stats(notes)
    print("\nstats:")
    for key, value in stats.items():
        print(f"  {key:>20}: {value}")

    assert stats["max_fret_jump"] <= 5, "octave leaps should not become slides"
    assert all(n.string is not None for n in notes)
    print("\nself-test OK")


if __name__ == "__main__":
    _demo()
