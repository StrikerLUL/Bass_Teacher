#!/usr/bin/env python3
"""Score transcriptions against the audio they came from.

Two transcribers will disagree about a song and both will look plausible in a
note list. This measures each against the bass stem's own spectrum instead, so
the choice of engine is settled by the audio rather than by preference.

    python compare_engines.py ../data/cagayake_girls/bass.wav \\
        basic-pitch=../data/cmp_basicpitch/transcription.json \\
        torchcrepe=../data/cmp_crepe/transcription.json

Metrics, all computed per note and then aggregated:

  harmonic fit   Share of the segment's 30-1200 Hz energy that lands on the
                 reported pitch's harmonic series. If the note is right, most
                 of the sound is explained by it. Higher is better.

  octave errors  Share of notes where the octave *below* carries more energy
                 than the reported pitch. A real note has no subharmonic; an
                 octave-up mistake does. Lower is better.

  coverage       Share of the stem's audible frames that sit inside some note.
                 Misses show up here. Higher is better.

  spurious       Share of note time where the stem is essentially silent.
                 Invented notes show up here. Lower is better.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

import numpy as np
import soundfile as sf

BAND = 0.035          # +/- 3.5% around a target frequency
ANALYSIS_LOW = 30.0   # Hz
ANALYSIS_HIGH = 1200.0
HARMONICS = 6
FFT_SIZE = 16384
GATE_RATIO = 0.15     # audible == above 15% of the 95th-percentile RMS
HOP_MS = 10.0


def midi_to_hz(midi: float) -> float:
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def load_mono(path: Path) -> Tuple[np.ndarray, int]:
    data, rate = sf.read(str(path), dtype="float32", always_2d=True)
    return data.mean(axis=1), rate


def band_energy(spectrum: np.ndarray, freqs: np.ndarray, centre: float) -> float:
    mask = (freqs > centre * (1 - BAND)) & (freqs < centre * (1 + BAND))
    return float(spectrum[mask].sum())


def score_notes(
    audio: np.ndarray, rate: int, notes: Sequence[dict]
) -> Dict[str, float]:
    harmonic_fits: List[float] = []
    octave_errors = 0
    scored = 0

    window = np.hanning(FFT_SIZE)
    freqs = np.fft.rfftfreq(FFT_SIZE, 1.0 / rate)
    in_band = (freqs >= ANALYSIS_LOW) & (freqs <= ANALYSIS_HIGH)

    for note in notes:
        begin = int(note["start"] * rate)
        finish = int(note["end"] * rate)
        if finish - begin < 512:
            continue
        segment = audio[begin:finish]
        if len(segment) < FFT_SIZE:
            segment = np.pad(segment, (0, FFT_SIZE - len(segment)))
        else:
            segment = segment[:FFT_SIZE]
        spectrum = np.abs(np.fft.rfft(segment * window))

        total = float(spectrum[in_band].sum())
        if total <= 0:
            continue

        f0 = midi_to_hz(note["midi"])
        explained = sum(
            band_energy(spectrum, freqs, f0 * n)
            for n in range(1, HARMONICS + 1)
            if f0 * n <= ANALYSIS_HIGH
        )
        harmonic_fits.append(min(1.0, explained / total))

        at_pitch = band_energy(spectrum, freqs, f0)
        below = band_energy(spectrum, freqs, f0 / 2) if f0 / 2 >= ANALYSIS_LOW else 0.0
        if below > at_pitch:
            octave_errors += 1
        scored += 1

    return {
        "scored": scored,
        "harmonic_fit": float(np.mean(harmonic_fits)) if harmonic_fits else 0.0,
        "octave_error_pct": 100.0 * octave_errors / scored if scored else 0.0,
    }


def score_timing(
    audio: np.ndarray, rate: int, notes: Sequence[dict], duration: float
) -> Dict[str, float]:
    hop = max(1, int(rate * HOP_MS / 1000.0))
    frames = max(1, len(audio) // hop)
    rms = np.sqrt(
        np.array([
            np.mean(audio[i * hop:(i + 1) * hop] ** 2) for i in range(frames)
        ])
    )
    gate = GATE_RATIO * float(np.percentile(rms, 95))
    audible = rms > gate

    covered = np.zeros(frames, dtype=bool)
    for note in notes:
        lo = max(0, int(note["start"] * rate / hop))
        hi = min(frames, int(note["end"] * rate / hop) + 1)
        if hi > lo:
            covered[lo:hi] = True

    audible_total = int(audible.sum())
    covered_total = int(covered.sum())
    return {
        "coverage_pct": 100.0 * float((audible & covered).sum()) / audible_total
        if audible_total else 0.0,
        "spurious_pct": 100.0 * float((covered & ~audible).sum()) / covered_total
        if covered_total else 0.0,
        "note_time_pct": 100.0 * covered_total / frames,
    }


def score_onsets(
    audio: np.ndarray, rate: int, notes: Sequence[dict], tolerance: float = 0.06
) -> Dict[str, float]:
    """Compare note starts against onsets heard in the stem itself.

    Coverage counts frames, so an engine that holds notes longer scores higher
    without finding anything extra. This counts note *events*, which is what
    actually matters for a tab.
    """
    try:
        import librosa
    except ImportError:
        return {"onset_recall_pct": 0.0, "onset_precision_pct": 0.0, "audio_onsets": 0}

    heard = librosa.onset.onset_detect(
        y=audio, sr=rate, units="time", backtrack=True
    )
    played = np.array(sorted(n["start"] for n in notes))
    if len(heard) == 0 or len(played) == 0:
        return {"onset_recall_pct": 0.0, "onset_precision_pct": 0.0,
                "audio_onsets": len(heard)}

    def nearest_within(targets: np.ndarray, probes: np.ndarray) -> int:
        idx = np.searchsorted(targets, probes)
        hits = 0
        for probe, i in zip(probes, idx):
            best = min(
                (abs(targets[j] - probe) for j in (i - 1, i) if 0 <= j < len(targets)),
                default=float("inf"),
            )
            if best <= tolerance:
                hits += 1
        return hits

    return {
        "onset_recall_pct": 100.0 * nearest_within(played, heard) / len(heard),
        "onset_precision_pct": 100.0 * nearest_within(heard, played) / len(played),
        "audio_onsets": len(heard),
    }


def main(argv: Sequence[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2

    stem = Path(argv[1])
    if not stem.exists():
        print(f"error: no such stem: {stem}", file=sys.stderr)
        return 1

    audio, rate = load_mono(stem)
    duration = len(audio) / rate
    print(f"stem: {stem.name}  {duration:.1f}s @ {rate} Hz\n")

    results: Dict[str, Dict[str, float]] = {}
    for entry in argv[2:]:
        label, _, path = entry.partition("=")
        document = json.loads(Path(path).read_text(encoding="utf-8"))
        notes = document["notes"]
        scores = score_notes(audio, rate, notes)
        scores.update(score_timing(audio, rate, notes, duration))
        scores.update(score_onsets(audio, rate, notes))
        scores["notes"] = len(notes)
        stats = document.get("stats", {})
        scores["max_fret_jump"] = stats.get("max_fret_jump", 0)
        scores["mean_fret_jump"] = stats.get("mean_fret_jump", 0.0)
        results[label] = scores

    columns = [
        ("notes", "notes", "{:.0f}", None),
        ("harmonic_fit", "harmonic fit", "{:.3f}", "high"),
        ("octave_error_pct", "octave errors %", "{:.1f}", "low"),
        ("onset_recall_pct", "onset recall %", "{:.1f}", "high"),
        ("onset_precision_pct", "onset precision %", "{:.1f}", "high"),
        ("coverage_pct", "coverage %", "{:.1f}", "high"),
        ("spurious_pct", "spurious %", "{:.1f}", "low"),
        ("note_time_pct", "note time %", "{:.1f}", None),
        ("max_fret_jump", "max fret jump", "{:.0f}", "low"),
        ("mean_fret_jump", "mean fret jump", "{:.2f}", "low"),
    ]

    labels = list(results)
    width = max(len(label) for label in labels) + 2
    print(f"{'metric':>16}  " + "".join(f"{label:>{width}}" for label in labels))
    print("-" * (18 + width * len(labels)))

    wins = {label: 0 for label in labels}
    for key, title, fmt, better in columns:
        row = f"{title:>16}  "
        values = [results[label][key] for label in labels]
        for value in values:
            row += f"{fmt.format(value):>{width}}"
        if better:
            best = min(values) if better == "low" else max(values)
            winners = [labels[i] for i, v in enumerate(values) if v == best]
            if len(winners) == 1:
                wins[winners[0]] += 1
                row += f"   <- {winners[0]}"
        print(row)

    print()
    for label, count in sorted(wins.items(), key=lambda kv: -kv[1]):
        print(f"  {label}: {count} of {sum(1 for c in columns if c[3])} metrics")
    best_label = max(wins, key=lambda k: wins[k])
    print(f"\nwinner on these measurements: {best_label}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
