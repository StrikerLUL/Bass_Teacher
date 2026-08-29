#!/usr/bin/env python3
"""Generate the demo transcription the Flutter app ships with, and smoke-test
the clean-up stage.

Needs nothing but the standard library, so the app has something to render
before Demucs or Basic Pitch are installed:

    python make_sample.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from fretboard import (
    Instrument,
    NoteEvent,
    annotate_hand_positions,
    assign_fingerings,
    fingering_stats,
)
from processor import (
    build_document,
    drop_short,
    dump_json,
    make_monophonic,
    merge_repeats,
    remove_octave_ghosts,
    to_events,
)

BPM = 150.0
SIXTEENTH = 60.0 / BPM / 4.0          # 0.1s
GATE = 0.85                           # note length as a fraction of the step
ROOTS = [40, 38, 36, 35]              # E2 D2 C2 B1 — a vi-V-IV-III minor loop
# Sixteenth-note offsets from the root.  The 0/12 alternation is the point of
# the demo: a naive mapper turns every octave leap into a 12-fret slide.
RIFF = [0, 0, 12, 0, 7, 0, 12, 0, 0, 0, 12, 0, 7, 12, 10, 7]
REPEATS = 2


def build_riff() -> list[NoteEvent]:
    notes: list[NoteEvent] = []
    time = 0.0
    for _ in range(REPEATS):
        for root in ROOTS:
            for step, offset in enumerate(RIFF):
                notes.append(
                    NoteEvent(
                        start=round(time, 4),
                        end=round(time + SIXTEENTH * GATE, 4),
                        midi=root + offset,
                        velocity=0.95 if step % 4 == 0 else 0.62,
                    )
                )
                time += SIXTEENTH
    return notes


def smoke_test_cleanup() -> None:
    """Feed the clean-up stage the failure modes it exists to handle."""
    raw = [
        (0.00, 0.40, 40, 0.90, None),   # a real note
        (0.01, 0.38, 52, 0.30, None),   # octave-up ghost, overlapping + quieter
        (0.42, 0.60, 43, 0.80, None),   # fragment 1 of a sustained note
        (0.61, 0.90, 43, 0.70, None),   # fragment 2, 10ms gap -> merge
        (0.95, 0.99, 45, 0.50, None),   # 40ms -> shorter than min_note, dropped
        (1.00, 1.60, 47, 0.80, None),   # still ringing when...
        (1.30, 1.70, 48, 0.85, None),   # ...this one starts -> truncates it
    ]
    events = to_events(raw)
    events = drop_short(events, 0.058)
    events = remove_octave_ghosts(events, 0.050, 1.0)
    events = merge_repeats(events, 0.030)
    events = make_monophonic(events, 0.030)

    pitches = [n.midi for n in events]
    assert 52 not in pitches, f"octave ghost survived: {pitches}"
    assert 45 not in pitches, f"too-short note survived: {pitches}"
    assert pitches == [40, 43, 47, 48], f"unexpected result: {pitches}"

    g_string = next(n for n in events if n.midi == 43)
    assert abs(g_string.end - 0.90) < 1e-6, f"fragments not merged: {g_string}"
    truncated = next(n for n in events if n.midi == 47)
    assert abs(truncated.end - 1.30) < 1e-6, f"overlap not trimmed: {truncated}"
    print("clean-up smoke test OK")


def main() -> int:
    smoke_test_cleanup()

    bass = Instrument.from_names(["E1", "A1", "D2", "G2"], frets=24)
    notes = build_riff()
    assign_fingerings(notes, bass)
    annotate_hand_positions(notes)

    document = build_document(
        notes,
        instrument=bass,
        source=Path("demo_riff.wav"),
        duration=round(notes[-1].end + 0.5, 3),
        sample_rate=44100,
        bass_rel=None,      # no audio: the app falls back to its internal clock
        backing_rel=None,
        settings={
            "model": "hand-written demo riff",
            "bpm": BPM,
            "note": "Em progression, sixteenth-note octave riff at 10 notes/sec",
        },
    )

    target = Path(__file__).resolve().parents[1] / "app/assets/sample/demo_transcription.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(dump_json(document), encoding="utf-8")

    stats = fingering_stats(notes)
    print(f"wrote {target} ({len(notes)} notes)")
    for key, value in stats.items():
        print(f"  {key:>20}: {value}")

    assert stats["max_fret_jump"] <= 5, "demo riff should stay in one hand position"
    return 0


if __name__ == "__main__":
    sys.exit(main())
