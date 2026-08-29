#!/usr/bin/env python3
"""Tests for the fingering search. Standard library only:

    python test_fretboard.py        # or: pytest test_fretboard.py
"""

from __future__ import annotations

import sys
from typing import List

from fretboard import (
    Instrument,
    NoteEvent,
    annotate_hand_positions,
    assign_fingerings,
    fingering_stats,
    midi_to_name,
    note_name_to_midi,
)

BASS = Instrument.from_names(["E1", "A1", "D2", "G2"], frets=24)


def positions(notes: List[NoteEvent]) -> List[str]:
    return [f"{n.string}:{n.fret}" for n in notes]


def phrase(pitches, start=0.0, step=0.1, gate=0.85) -> List[NoteEvent]:
    notes = []
    time = start
    for pitch in pitches:
        notes.append(NoteEvent(time, time + step * gate, pitch))
        time += step
    return notes


def test_note_names():
    assert note_name_to_midi("E1") == 28
    assert note_name_to_midi("A1") == 33
    assert note_name_to_midi("G2") == 43
    assert note_name_to_midi("C4") == 60
    assert note_name_to_midi("F#2") == 42
    assert note_name_to_midi("Bb0") == 22
    assert midi_to_name(28) == "E1"
    assert midi_to_name(60) == "C4"
    for name in ("", "H2", "E", "Ex"):
        try:
            note_name_to_midi(name)
        except ValueError:
            continue
        raise AssertionError(f"expected {name!r} to be rejected")


def test_positions_for():
    assert positions_of(BASS.positions_for(40)) == ["2:2", "1:7", "0:12"]
    assert len(BASS.positions_for(40, max_fret=5)) == 1
    assert BASS.positions_for(27) == []          # below open E
    assert BASS.positions_for(68) == []          # above the 24th fret of G


def positions_of(found) -> List[str]:
    return [f"{p.string}:{p.fret}" for p in found]


def test_octave_riff_stays_in_one_position():
    """A fast 0/12 riff must cross strings, not slide 12 frets."""
    notes = phrase([40, 40, 52, 40, 47, 40, 52, 40])
    assign_fingerings(notes, BASS)
    assert positions(notes)[:6] == ["1:7", "1:7", "3:9", "1:7", "2:9", "1:7"]
    assert fingering_stats(notes)["max_fret_jump"] <= 3


def test_open_string_does_not_reset_the_hand():
    """D3 parks the hand at fret 7; A2 is playable at fret 2 or fret 7.

    The open D in between must not make the search forget where the hand is.
    """
    notes = [
        NoteEvent(0.0, 0.08, 50),   # D3
        NoteEvent(0.1, 0.18, 38),   # D2, open D string
        NoteEvent(0.2, 0.28, 45),   # A2
    ]
    assign_fingerings(notes, BASS)
    assert positions(notes) == ["3:7", "2:0", "2:7"]


def test_phrase_relocates_when_it_pays_to():
    """One high note then a long low phrase: the hand should walk down.

    A per-note rule would strand the phrase up the neck; the Viterbi pass
    relocates because the accumulated position costs outweigh the one shift.
    """
    notes = [NoteEvent(0.0, 0.5, 64)]                       # E4, fret 21
    notes += phrase([40, 42, 43, 45] * 4, start=2.0, step=0.12)
    assign_fingerings(notes, BASS)

    assert notes[0].fret == 21
    settled = [n.fret for n in notes[-8:]]
    assert max(settled) <= 4, f"phrase did not settle low: {settled}"


def test_out_of_range_notes_are_left_unassigned():
    notes = [NoteEvent(0.0, 0.2, 20), NoteEvent(0.3, 0.5, 40)]
    assign_fingerings(notes, BASS)
    assert notes[0].string is None and notes[0].fret is None
    assert notes[1].fret is not None


def test_segments_either_side_of_a_gap_are_both_solved():
    notes = [
        NoteEvent(0.0, 0.1, 40),
        NoteEvent(0.2, 0.3, 20),    # unplayable: splits the sequence
        NoteEvent(0.4, 0.5, 45),
    ]
    assign_fingerings(notes, BASS)
    assert notes[0].fret is not None
    assert notes[1].fret is None
    assert notes[2].fret is not None


def test_empty_and_single_note():
    assert assign_fingerings([], BASS) == []
    single = [NoteEvent(0.0, 0.5, 40)]
    assign_fingerings(single, BASS)
    assert single[0].fret == 2       # cheapest position with nothing to travel from


def test_hand_positions_ignore_open_strings():
    """Positions are given, so this exercises the annotation on its own."""
    notes = [
        NoteEvent(0.0, 0.1, 47, string=2, fret=9),
        NoteEvent(0.1, 0.2, 38, string=2, fret=0),   # open D, ignored
        NoteEvent(0.2, 0.3, 45, string=2, fret=7),
    ]
    annotate_hand_positions(notes)
    assert all(n.hand == 7 for n in notes), [n.hand for n in notes]


def test_fit_pitch_shifts_octaves():
    assert BASS.fit_pitch(16) == (28, 1)     # an octave below open E
    assert BASS.fit_pitch(40) == (40, 0)
    assert BASS.fit_pitch(80) == (56, -2)    # keeps going until it is in range
    assert BASS.fit_pitch(68) == (56, -1)    # one fret above the 24th


def test_five_string_tuning():
    five = Instrument.from_names(["B0", "E1", "A1", "D2", "G2"], frets=24)
    assert five.string_count == 5
    assert five.lowest_midi == 23
    notes = phrase([23, 28, 35])
    assign_fingerings(notes, five)
    assert notes[0].string == 0 and notes[0].fret == 0


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
