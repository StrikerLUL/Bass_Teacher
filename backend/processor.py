#!/usr/bin/env python3
"""Bass stem separation + transcription pipeline.

    python processor.py "song.mp3"
    python processor.py "song.mp3" --preview 30          # first 30s, for iterating
    python processor.py "song.mp3" --shifts 2            # slower, cleaner stems
    python processor.py --bass-stem stems/bass.wav       # transcribe only

Stages
    1. Demucs (htdemucs)       -> bass.wav + backing.wav
    2. Basic Pitch (ICASSP22)  -> raw note events
    3. Clean-up                -> de-ghosted, monophonic, in-range notes
    4. fretboard.py            -> string/fret per note (minimal hand travel)
    5. JSON                    -> consumed by the Flutter app

Output layout (one directory per track):

    <out>/<track>/
        transcription.json    the document the app loads
        bass.wav              isolated bass stem
        backing.wav           everything except the bass
        bass.mid              raw Basic Pitch transcription, for a DAW
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from importlib.util import find_spec
from pathlib import Path
from typing import Any, Dict, List, NoReturn, Optional, Sequence, Tuple

try:  # works both as `python processor.py` and `python -m backend.processor`
    from .fretboard import (
        FingeringConfig,
        Instrument,
        NoteEvent,
        annotate_hand_positions,
        assign_fingerings,
        fingering_stats,
        midi_to_name,
    )
except ImportError:  # pragma: no cover - script execution
    from fretboard import (
        FingeringConfig,
        Instrument,
        NoteEvent,
        annotate_hand_positions,
        assign_fingerings,
        fingering_stats,
        midi_to_name,
    )

VERSION = "0.1.0"
SCHEMA_VERSION = 1
DEFAULT_TUNING = "E1,A1,D2,G2"
DEMUCS_BASS_STEM = "bass.wav"
DEMUCS_OTHER_STEM = "no_bass.wav"

_START = time.monotonic()


def log(message: str) -> None:
    print(f"[{time.monotonic() - _START:6.1f}s] {message}", flush=True)


def fail(message: str, hint: str = "") -> NoReturn:
    print(f"\nerror: {message}", file=sys.stderr)
    if hint:
        print(f"       {hint}", file=sys.stderr)
    raise SystemExit(1)


def midi_to_hz(midi: float) -> float:
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def slugify(text: str) -> str:
    cleaned = "".join(c if c.isalnum() or c in "-_" else "_" for c in text).strip("_")
    while "__" in cleaned:
        cleaned = cleaned.replace("__", "_")
    return cleaned or "track"


# --------------------------------------------------------------------------- #
# Audio helpers
# --------------------------------------------------------------------------- #

def audio_info(path: Path) -> Tuple[Optional[float], Optional[int]]:
    """``(duration_seconds, sample_rate)``, or ``(None, None)`` if unreadable."""
    try:
        import soundfile as sf

        info = sf.info(str(path))
        return float(info.duration), int(info.samplerate)
    except Exception:
        pass
    try:
        import librosa

        return float(librosa.get_duration(path=str(path))), None
    except Exception:
        return None, None


def make_preview(source: Path, seconds: float, work_dir: Path) -> Path:
    """Trim the head of a file so the pipeline can be iterated on quickly."""
    import soundfile as sf

    work_dir.mkdir(parents=True, exist_ok=True)
    target = work_dir / f"{source.stem}__preview{int(seconds)}s.wav"
    with sf.SoundFile(str(source)) as handle:
        frames = handle.read(int(seconds * handle.samplerate), dtype="float32")
        sf.write(str(target), frames, handle.samplerate)
    log(f"preview: first {seconds:g}s -> {target.name}")
    return target


# --------------------------------------------------------------------------- #
# Stage 1 — Demucs
# --------------------------------------------------------------------------- #

def pick_device(requested: str) -> str:
    if requested != "auto":
        return requested
    try:
        import torch

        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def separate(
    source: Path,
    out_dir: Path,
    *,
    model: str,
    device: str,
    shifts: int,
    jobs: int,
    force: bool,
) -> Tuple[Path, Optional[Path]]:
    """Split ``source`` into a bass stem and a backing stem via Demucs."""
    bass_path = out_dir / "bass.wav"
    backing_path = out_dir / "backing.wav"
    if bass_path.exists() and backing_path.exists() and not force:
        log(f"stems already present, reusing (--force to redo): {bass_path.name}")
        return bass_path, backing_path

    if find_spec("demucs") is None:
        fail(
            "demucs is not installed.",
            "pip install demucs   (needs torch; see backend/requirements.txt)",
        )

    work_dir = out_dir / "_demucs"
    if work_dir.exists():
        shutil.rmtree(work_dir, ignore_errors=True)

    command = [
        sys.executable, "-m", "demucs",
        "--two-stems", "bass",
        "-n", model,
        "-d", device,
        "--shifts", str(shifts),
        "-j", str(jobs),
        "-o", str(work_dir),
        str(source),
    ]
    log(f"demucs: {model} on {device} (shifts={shifts}) — this is the slow part")
    result = subprocess.run(command)
    if result.returncode != 0:
        fail(f"demucs exited with code {result.returncode}")

    produced = sorted(work_dir.rglob(DEMUCS_BASS_STEM))
    if not produced:
        fail(f"demucs produced no {DEMUCS_BASS_STEM} under {work_dir}")
    stem_dir = produced[0].parent

    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.move(str(stem_dir / DEMUCS_BASS_STEM), str(bass_path))

    other = stem_dir / DEMUCS_OTHER_STEM
    if other.exists():
        shutil.move(str(other), str(backing_path))
    else:
        backing_path = None  # type: ignore[assignment]

    shutil.rmtree(work_dir, ignore_errors=True)
    log(f"stems: {bass_path.name}" + (f" + {backing_path.name}" if backing_path else ""))
    return bass_path, backing_path


# --------------------------------------------------------------------------- #
# Stage 2 — Basic Pitch
# --------------------------------------------------------------------------- #

def transcribe(
    bass_path: Path,
    *,
    instrument: Instrument,
    onset_threshold: float,
    frame_threshold: float,
    min_note_ms: float,
    min_freq: Optional[float],
    max_freq: Optional[float],
) -> Tuple[List[Tuple[Any, ...]], Any]:
    if find_spec("basic_pitch") is None:
        fail(
            "basic-pitch is not installed.",
            "pip install \"basic-pitch[onnx]\"   (onnxruntime backend, no TensorFlow)",
        )

    from basic_pitch import ICASSP_2022_MODEL_PATH
    from basic_pitch.inference import predict

    # Bound the search to what the instrument can actually produce.  This is
    # the single most effective guard against Basic Pitch's octave-up ghosts on
    # low, harmonically rich bass notes.
    low = min_freq if min_freq is not None else midi_to_hz(instrument.lowest_midi) * 0.97
    high = max_freq if max_freq is not None else midi_to_hz(instrument.highest_midi) * 1.03

    log(f"basic-pitch: {low:.1f}–{high:.1f} Hz, onset={onset_threshold}, "
        f"frame={frame_threshold}, min_note={min_note_ms:g}ms")

    _model_output, midi_data, note_events = predict(
        str(bass_path),
        ICASSP_2022_MODEL_PATH,
        onset_threshold=onset_threshold,
        frame_threshold=frame_threshold,
        minimum_note_length=min_note_ms,
        minimum_frequency=low,
        maximum_frequency=high,
        multiple_pitch_bends=False,
        melodia_trick=True,
    )
    log(f"basic-pitch: {len(note_events)} raw note events")
    return list(note_events), midi_data


# --------------------------------------------------------------------------- #
# Stage 3 — Clean-up
# --------------------------------------------------------------------------- #

def to_events(raw: Sequence[Tuple[Any, ...]]) -> List[NoteEvent]:
    """Basic Pitch yields ``(start, end, pitch, amplitude, pitch_bends)``."""
    events = [
        NoteEvent(
            start=float(item[0]),
            end=float(item[1]),
            midi=int(item[2]),
            velocity=float(item[3]) if len(item) > 3 else 1.0,
        )
        for item in raw
    ]
    events.sort(key=lambda n: (n.start, n.midi))
    return events


def drop_short(events: List[NoteEvent], min_duration: float) -> List[NoteEvent]:
    return [n for n in events if n.duration >= min_duration]


def remove_octave_ghosts(
    events: List[NoteEvent], window: float, amp_ratio: float
) -> List[NoteEvent]:
    """Drop notes that are an octave-up echo of a louder simultaneous note.

    A genuine octave leap in a bass line is *sequential*; a ghost overlaps its
    fundamental. Both conditions are required, so fast octave riffs survive.
    """
    keep = [True] * len(events)
    for i, note in enumerate(events):
        if not keep[i]:
            continue
        for j in range(i + 1, len(events)):
            other = events[j]
            if other.start - note.start > window:
                break
            if not keep[j] or other.midi != note.midi + 12:
                continue
            overlap = min(note.end, other.end) - max(note.start, other.start)
            if overlap <= 0.5 * min(note.duration, other.duration):
                continue
            if other.velocity <= note.velocity * amp_ratio:
                keep[j] = False
    return [n for n, ok in zip(events, keep) if ok]


def merge_repeats(events: List[NoteEvent], max_gap: float) -> List[NoteEvent]:
    """Rejoin one sustained note that the model split into fragments."""
    merged: List[NoteEvent] = []
    for note in events:
        for prev in reversed(merged[-4:]):
            if prev.midi == note.midi and note.start - prev.end <= max_gap:
                prev.end = max(prev.end, note.end)
                prev.velocity = max(prev.velocity, note.velocity)
                break
        else:
            merged.append(note)
    return merged


def make_monophonic(events: List[NoteEvent], simultaneity: float) -> List[NoteEvent]:
    """Collapse to one note at a time — a bass line almost always is.

    Same-instant collisions keep the louder note (tie-break: the lower pitch,
    since the stray is usually a harmonic).  A later note simply truncates the
    one still ringing.
    """
    out: List[NoteEvent] = []
    for note in events:
        if not out:
            out.append(note)
            continue
        prev = out[-1]
        if note.start < prev.end - 1e-6:
            if note.start - prev.start <= simultaneity:
                if (note.velocity, -note.midi) > (prev.velocity, -prev.midi):
                    out[-1] = note
                continue
            prev.end = note.start
        out.append(note)
    return out


def fit_to_instrument(events: List[NoteEvent], instrument: Instrument) -> List[NoteEvent]:
    """Octave-shift stragglers into range rather than dropping them."""
    for note in events:
        fitted, shift = instrument.fit_pitch(note.midi)
        note.midi = fitted
        note.octave_shift = shift
    return [n for n in events if instrument.lowest_midi <= n.midi <= instrument.highest_midi]


# --------------------------------------------------------------------------- #
# Stage 5 — Document
# --------------------------------------------------------------------------- #

def build_document(
    events: Sequence[NoteEvent],
    *,
    instrument: Instrument,
    source: Path,
    duration: Optional[float],
    sample_rate: Optional[int],
    bass_rel: Optional[str],
    backing_rel: Optional[str],
    settings: Dict[str, Any],
) -> Dict[str, Any]:
    notes = [
        {
            "start": round(n.start, 4),
            "end": round(n.end, 4),
            "midi": n.midi,
            "name": midi_to_name(n.midi),
            "velocity": round(n.velocity, 3),
            "string": n.string,
            "fret": n.fret,
            "hand": n.hand,
            **({"octave_shift": n.octave_shift} if n.octave_shift else {}),
        }
        for n in events
        if n.string is not None
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "generator": f"bass-trainer processor.py {VERSION}",
        "source": {
            "file": source.name,
            "duration_sec": round(duration, 3) if duration else None,
            "sample_rate": sample_rate,
        },
        # Relative to this JSON file, so the folder can be moved or synced.
        "stems": {"bass": bass_rel, "backing": backing_rel},
        "instrument": {
            "strings": instrument.string_count,
            "tuning": instrument.tuning_names,
            "tuning_midi": list(instrument.tuning),
            "frets": instrument.frets,
            "string_order": "0 = lowest pitched",
        },
        "transcription": settings,
        "stats": fingering_stats(events),
        "notes": notes,
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="processor.py",
        description="Isolate a bass stem and transcribe it to a fretboard JSON.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("input", nargs="?", type=Path, help="audio file to process")
    parser.add_argument("-o", "--out", type=Path, default=Path("../data"),
                        help="directory that receives one folder per track")
    parser.add_argument("--name", help="track folder name (default: input file stem)")

    group = parser.add_argument_group("separation")
    group.add_argument("--bass-stem", type=Path,
                       help="skip Demucs and transcribe this file directly")
    group.add_argument("--backing-stem", type=Path, help="backing track to pair with it")
    group.add_argument("--model", default="htdemucs", help="Demucs model name")
    group.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu", "mps"])
    group.add_argument("--shifts", type=int, default=1,
                       help="Demucs shift-trick passes; 2-4 is cleaner but N times slower")
    group.add_argument("--jobs", type=int, default=1, help="Demucs worker processes")
    group.add_argument("--force", action="store_true", help="re-separate even if stems exist")
    group.add_argument("--preview", type=float, metavar="SECONDS",
                       help="only process the first N seconds")

    group = parser.add_argument_group("transcription")
    group.add_argument("--onset-threshold", type=float, default=0.5,
                       help="lower finds more note starts (and more false ones)")
    group.add_argument("--frame-threshold", type=float, default=0.3,
                       help="lower sustains notes longer")
    group.add_argument("--min-note-ms", type=float, default=58.0,
                       help="shortest note to keep; 58ms clears 16ths at 250bpm")
    group.add_argument("--min-freq", type=float, help="default: lowest note of the tuning")
    group.add_argument("--max-freq", type=float, help="default: highest fretted note")
    group.add_argument("--merge-gap-ms", type=float, default=30.0,
                       help="rejoin same-pitch fragments closer than this")
    group.add_argument("--ghost-window-ms", type=float, default=50.0,
                       help="onset window for octave-ghost detection")
    group.add_argument("--ghost-ratio", type=float, default=1.0,
                       help="drop an octave-up note quieter than fundamental * ratio")
    group.add_argument("--simultaneity-ms", type=float, default=30.0,
                       help="notes this close together count as one attack")
    group.add_argument("--polyphonic", action="store_true",
                       help="keep overlapping notes instead of collapsing to one voice")

    group = parser.add_argument_group("instrument")
    group.add_argument("--tuning", default=DEFAULT_TUNING,
                       help="open strings, low to high")
    group.add_argument("--frets", type=int, default=24)
    group.add_argument("--max-fret", type=int,
                       help="restrict fingerings to this fret and below")

    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    if args.input is None and args.bass_stem is None:
        fail("give an input audio file, or --bass-stem to skip separation.")

    try:
        instrument = Instrument.from_names(
            [t.strip() for t in args.tuning.split(",") if t.strip()], frets=args.frets
        )
    except ValueError as exc:
        fail(f"bad --tuning {args.tuning!r}: {exc}")

    source = args.input or args.bass_stem
    if not source.exists():
        fail(f"no such file: {source}")

    track = slugify(args.name or source.stem)
    out_dir = (args.out / track).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"track '{track}' -> {out_dir}")
    log(f"instrument: {'-'.join(instrument.tuning_names)}, {instrument.frets} frets")

    # ---- stage 1: separation ------------------------------------------------
    if args.bass_stem:
        bass_path = args.bass_stem.resolve()
        backing_path = args.backing_stem.resolve() if args.backing_stem else None
        log(f"separation skipped, using {bass_path.name}")
    else:
        audio = args.input.resolve()
        if args.preview:
            audio = make_preview(audio, args.preview, out_dir / "_preview")
        bass_path, backing_path = separate(
            audio, out_dir,
            model=args.model, device=pick_device(args.device),
            shifts=args.shifts, jobs=args.jobs, force=args.force,
        )

    # ---- stage 2: transcription --------------------------------------------
    raw, midi_data = transcribe(
        bass_path,
        instrument=instrument,
        onset_threshold=args.onset_threshold,
        frame_threshold=args.frame_threshold,
        min_note_ms=args.min_note_ms,
        min_freq=args.min_freq,
        max_freq=args.max_freq,
    )
    if midi_data is not None:
        try:
            midi_data.write(str(out_dir / "bass.mid"))
        except Exception as exc:  # non-fatal: the JSON is the real output
            log(f"warning: could not write bass.mid ({exc})")

    # ---- stage 3: clean-up --------------------------------------------------
    events = to_events(raw)
    before = len(events)
    events = drop_short(events, args.min_note_ms / 1000.0)
    events = remove_octave_ghosts(
        events, args.ghost_window_ms / 1000.0, args.ghost_ratio
    )
    events = merge_repeats(events, args.merge_gap_ms / 1000.0)
    if not args.polyphonic:
        events = make_monophonic(events, args.simultaneity_ms / 1000.0)
    events = fit_to_instrument(events, instrument)
    log(f"clean-up: {before} -> {len(events)} notes")
    if not events:
        fail("no notes survived clean-up.",
             "try --onset-threshold 0.3 --frame-threshold 0.2")

    # ---- stage 4: fingering -------------------------------------------------
    assign_fingerings(
        events, instrument, FingeringConfig(max_fret=args.max_fret)
    )
    annotate_hand_positions(events)

    # ---- stage 5: document --------------------------------------------------
    duration, sample_rate = audio_info(bass_path)
    document = build_document(
        events,
        instrument=instrument,
        source=source,
        duration=duration,
        sample_rate=sample_rate,
        bass_rel=_relative(bass_path, out_dir),
        backing_rel=_relative(backing_path, out_dir) if backing_path else None,
        settings={
            "model": "basic-pitch ICASSP 2022",
            "onset_threshold": args.onset_threshold,
            "frame_threshold": args.frame_threshold,
            "min_note_ms": args.min_note_ms,
            "monophonic": not args.polyphonic,
            "separator": None if args.bass_stem else f"demucs {args.model}",
        },
    )

    json_path = out_dir / "transcription.json"
    json_path.write_text(dump_json(document), encoding="utf-8")

    log(f"wrote {json_path}")
    print("\nstats")
    for key, value in document["stats"].items():
        print(f"  {key:>20}: {value}")
    print(f"\nOpen {json_path} in the Flutter app.")
    return 0


def dump_json(document: Dict[str, Any]) -> str:
    """Serialise with the header indented and one note per line.

    A four-minute song is a few thousand notes; fully indenting them turns the
    file into 40k lines of noise, while a single compact line is unreadable.
    One note per line stays greppable and diffs sanely.
    """
    head = {k: v for k, v in document.items() if k != "notes"}
    text = json.dumps(head, indent=2, ensure_ascii=False)
    body = ",\n".join(
        "    " + json.dumps(note, ensure_ascii=False) for note in document["notes"]
    )
    return f'{text[:-2]},\n  "notes": [\n{body}\n  ]\n}}\n'


def _relative(path: Optional[Path], base: Path) -> Optional[str]:
    if path is None:
        return None
    try:
        return path.resolve().relative_to(base).as_posix()
    except ValueError:
        return path.resolve().as_posix()


if __name__ == "__main__":
    raise SystemExit(main())
