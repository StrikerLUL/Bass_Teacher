#!/usr/bin/env python3
"""Tests for the note-recognition stages. Standard library only:

    python test_transcribe.py        # or: pytest test_transcribe.py

Everything here operates on plain sequences, which is the point: the stages
that decide where one note ends and the next begins can be checked without
torch, librosa, a model download or an audio file.
"""

from __future__ import annotations

import sys
from importlib.util import find_spec
from typing import List, Sequence

from fretboard import NoteEvent
from processor import (
    align_to_onsets,
    drop_below_noise_floor,
    merge_repeats,
    segment_pitch_track,
)

HOP = 0.01  # 10 ms, the pipeline's default torchcrepe hop


def track(pattern: Sequence[tuple], hop: float = HOP):
    """Build (semitones, confidence, energy) from ``(frames, midi, conf)`` runs.

    A midi of None is silence: no pitch and no confidence.
    """
    semitones: List[float] = []
    confidence: List[float] = []
    energy: List[float] = []
    for frames, midi, conf in pattern:
        for _ in range(frames):
            semitones.append(0.0 if midi is None else float(midi))
            confidence.append(float(conf))
            energy.append(0.0 if midi is None else 1.0)
    return semitones, confidence, energy


def segment(pattern, **kwargs) -> List[NoteEvent]:
    semitones, confidence, energy = track(pattern)
    options = dict(
        hop_sec=HOP,
        start_threshold=0.20,
        keep_threshold=0.12,
        min_note_sec=0.058,
        attack_sec=0.03,
    )
    options.update(kwargs)
    return segment_pitch_track(semitones, confidence, energy, **options)


# --------------------------------------------------------------------------- #
# Segmentation
# --------------------------------------------------------------------------- #

def test_a_steady_pitch_is_one_note():
    notes = segment([(50, 40, 0.9)])
    assert len(notes) == 1, f"expected one note, got {len(notes)}"
    assert notes[0].midi == 40
    assert abs(notes[0].start - 0.0) < 1e-9
    assert abs(notes[0].end - 0.5) < 1e-9


def test_a_pitch_change_starts_a_new_note():
    notes = segment([(20, 40, 0.9), (20, 43, 0.9)])
    assert [n.midi for n in notes] == [40, 43]


def test_repeated_notes_need_the_attacks_to_be_seen():
    """The failure this whole mechanism exists for.

    Four plucks of the same pitch are one unbroken f0. Without the attacks
    there is nothing to cut on and the run comes back as one note lasting the
    whole bar; with them it comes back as four.
    """
    pattern = [(40, 40, 0.9)] * 4
    assert len(segment(pattern)) == 1

    onsets = [0.0, 0.4, 0.8, 1.2]
    notes = segment(pattern, onsets=onsets)
    assert len(notes) == 4, f"expected four plucks, got {len(notes)}"
    assert [n.midi for n in notes] == [40] * 4
    for note, onset in zip(notes, onsets):
        assert abs(note.start - onset) < 1e-9, f"{note.start} != {onset}"


def test_an_attack_inside_the_first_note_is_that_note_s_own():
    """Detection lands a frame or two late; that must not cut a note in two."""
    notes = segment([(40, 40, 0.9)], onsets=[0.02])
    assert len(notes) == 1, "an attack within min_note_sec of the start splits"


def test_voicing_hysteresis_holds_a_note_through_a_wobble():
    # A dip to 0.15: under the 0.20 needed to start, over the 0.12 to continue.
    pattern = [(20, 40, 0.9), (3, 40, 0.15), (20, 40, 0.9)]
    assert len(segment(pattern)) == 1

    # With one threshold for both, the same dip cuts the note in half.
    assert len(segment(pattern, keep_threshold=0.20)) == 2


def test_a_quiet_start_does_not_open_a_note():
    """Bleed sits under the start threshold, and never gets to be a note."""
    assert segment([(40, 40, 0.15)]) == []


def test_short_segments_are_dropped():
    assert segment([(3, 40, 0.9), (40, 43, 0.9)]) == [NoteEvent(0.03, 0.43, 43)]


def test_pitch_is_taken_from_the_sustain():
    """The pluck is inharmonic and the tracker wanders through it.

    Three frames of nonsense at the attack outvote nothing: the note is the
    pitch it settles on, not the average of the two.
    """
    notes = segment([(3, 52, 0.9), (40, 40, 0.9)], onsets=[])
    assert len(notes) == 1
    assert notes[0].midi == 40, f"attack frames leaked into the pitch: {notes[0].midi}"


def test_pitch_is_weighted_by_confidence():
    # Equal numbers of frames, but the tracker is far surer about one of them.
    notes = segment([(20, 40, 0.9), (20, 40.9, 0.15)], pitch_tolerance=2.0)
    assert len(notes) == 1
    assert notes[0].midi == 40


def test_an_empty_track_is_no_notes():
    assert segment_pitch_track(
        [], [], [], hop_sec=HOP, start_threshold=0.2,
        keep_threshold=0.1, min_note_sec=0.05,
    ) == []


# --------------------------------------------------------------------------- #
# Noise floor
# --------------------------------------------------------------------------- #

def _levels(levels: Sequence[float]) -> List[NoteEvent]:
    return [NoteEvent(i * 0.1, i * 0.1 + 0.09, 40, velocity=v)
            for i, v in enumerate(levels)]


def test_the_noise_floor_drops_bleed_and_keeps_dynamics():
    # Ten notes around 1.0, one 40 dB down. A player's own dynamics are a few
    # dB; bleed from the separation is tens.
    events = _levels([1.0, 0.9, 1.1, 0.8, 1.0, 0.01, 1.2, 0.9, 1.0, 1.1])
    kept, dropped = drop_below_noise_floor(events, 24.0)
    assert dropped == 1, f"dropped {dropped}"
    assert all(n.velocity > 0.5 for n in kept)

    kept, dropped = drop_below_noise_floor(_levels([1.0, 0.7] * 5), 24.0)
    assert dropped == 0, "a quiet note is not bleed"


def test_the_noise_floor_needs_enough_notes_to_have_a_median():
    events = _levels([1.0, 0.001])
    assert drop_below_noise_floor(events, 24.0) == (events, 0)


def test_the_noise_floor_can_be_switched_off():
    events = _levels([1.0] * 9 + [0.0001])
    assert drop_below_noise_floor(events, 0.0) == (events, 0)


# --------------------------------------------------------------------------- #
# Merging and alignment
# --------------------------------------------------------------------------- #

def test_fragments_of_one_note_are_rejoined():
    events = [NoteEvent(0.0, 0.20, 40), NoteEvent(0.21, 0.40, 40)]
    merged = merge_repeats(events, 0.030)
    assert len(merged) == 1
    assert abs(merged[0].end - 0.40) < 1e-9


def test_merging_does_not_undo_a_repeated_note():
    """Two plucks of one pitch look exactly like one fragmented note.

    They are contiguous and the same pitch, which is the shape merge_repeats
    looks for — the detected attack is the only thing that tells them apart.
    """
    events = [NoteEvent(0.0, 0.20, 40), NoteEvent(0.20, 0.40, 40)]
    assert len(merge_repeats(list(events), 0.030)) == 1
    assert len(merge_repeats(list(events), 0.030, onsets=[0.0, 0.201])) == 2


def test_note_starts_snap_to_a_nearby_attack():
    events = [NoteEvent(0.512, 0.90, 40)]
    aligned, moved = align_to_onsets(events, [0.500], 0.045)
    assert moved == 1
    assert abs(aligned[0].start - 0.500) < 1e-9


def test_alignment_leaves_a_note_with_no_attack_alone():
    events = [NoteEvent(0.512, 0.90, 40)]
    aligned, moved = align_to_onsets(events, [0.100], 0.045)
    assert moved == 0
    assert aligned[0].start == 0.512


def test_alignment_never_drags_a_note_behind_the_one_before_it():
    events = [NoteEvent(0.500, 0.60, 40), NoteEvent(0.520, 0.70, 43)]
    aligned, _ = align_to_onsets(events, [0.400, 0.499], 0.045)
    assert aligned[0].start <= aligned[1].start
    assert aligned[1].start > events[0].start


# --------------------------------------------------------------------------- #
# The octave check
#
# These need numpy, which arrives with the transcription engines. They are
# skipped rather than failed when it is absent, so the rest of the file still
# runs on a bare Python.
# --------------------------------------------------------------------------- #

def _has_numpy() -> bool:
    """These score a real spectrum, so they are skipped rather than failed."""
    if find_spec("numpy") is not None:
        return True
    print("      (skipped: numpy not installed)")
    return False


def _harmonics(f0: float, weights: Sequence[float], rate: int = 44100,
               seconds: float = 0.25):
    """A note as a harmonic series, which is what a plucked string produces."""
    import numpy as np

    t = np.arange(int(seconds * rate)) / rate
    rng = np.random.default_rng(3)
    signal = sum(
        weight * np.sin(2 * np.pi * f0 * partial * t + rng.uniform(0, 6.28))
        for partial, weight in enumerate(weights, start=1)
    )
    return signal.astype("float32")


def _octave_ratio(signal, reported_midi: int, rate: int = 44100) -> float:
    """How much better the octave below explains the audio than `reported`."""
    from processor import _harmonic_score, _spectrum, midi_to_hz

    mags, freqs = _spectrum(signal, rate)
    here = _harmonic_score(mags, freqs, midi_to_hz(reported_midi))
    below = _harmonic_score(mags, freqs, midi_to_hz(reported_midi - 12))
    return below / here if here else 0.0


# A plucked bass string: fundamental plus a decaying comb.
_BASS_PARTIALS = [1.0, 0.7, 0.5, 0.35, 0.25, 0.2, 0.15, 0.1, 0.08, 0.06]


def test_the_octave_margin_sits_between_the_two_cases():
    """The default margin is measured, not chosen.

    An octave error is a note whose fundamental was too weak for the tracker to
    lock onto, so it took the second harmonic instead. Both cases are
    synthesised here and the comb has to separate them with the default 1.2
    between: below it nothing genuine, above it every error.
    """
    if not _has_numpy():
        return

    from processor import midi_to_hz

    genuine = [
        _octave_ratio(_harmonics(midi_to_hz(midi), _BASS_PARTIALS), midi)
        for midi in (28, 33, 38, 40, 45, 50, 55, 62)
    ]
    errors = [
        _octave_ratio(
            _harmonics(midi_to_hz(midi), [weak] + _BASS_PARTIALS[1:]), midi + 12
        )
        for midi in (28, 31, 35, 40)
        for weak in (0.1, 0.25, 0.5, 0.8)
    ]

    assert max(genuine) < 1.2, f"a genuine note would be moved down: {max(genuine):.2f}"
    assert min(errors) > 1.2, f"an octave error would be left alone: {min(errors):.2f}"


def test_the_comb_survives_bleed_an_octave_below():
    """Separation is not perfect, and what leaks in is often the guitar.

    A tenth of the note's amplitude an octave down is not a fundamental, and
    must not read as one.
    """
    if not _has_numpy():
        return

    from processor import midi_to_hz

    for midi in (40, 47, 55):
        note = _harmonics(midi_to_hz(midi), _BASS_PARTIALS)
        bleed = 0.1 * _harmonics(midi_to_hz(midi - 12), _BASS_PARTIALS)
        ratio = _octave_ratio(note + bleed, midi)
        assert ratio < 1.2, f"midi {midi} moved down on bleed alone ({ratio:.2f})"


def test_a_band_narrower_than_a_bin_still_finds_the_fundamental():
    """41 Hz +/- 3% is 2.5 Hz wide; the FFT bins are 2.7 Hz apart.

    A purely proportional band selects nothing at all down there, which would
    score every low note as silent and hand the octave check garbage.
    """
    if not _has_numpy():
        return

    from processor import _harmonic_score, _spectrum, midi_to_hz

    e1 = midi_to_hz(28)  # 41.2 Hz, the lowest note on a 4-string bass
    mags, freqs = _spectrum(_harmonics(e1, [1.0]), 44100)
    assert _harmonic_score(mags, freqs, e1) > 0.0


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
