#!/usr/bin/env python3
"""Bass stem separation + transcription pipeline.

    python processor.py "song.mp3"
    python processor.py "song.mp3" --preview 30          # first 30s, for iterating
    python processor.py "song.mp3" --shifts 2            # slower, cleaner stems
    python processor.py --bass-stem stems/bass.wav       # transcribe only

Stages
    1. Demucs (htdemucs)       -> bass.wav + backing.wav
    2. librosa onsets          -> where the string was actually plucked
    3. torchcrepe (or Basic Pitch, --engine) -> raw note events
    4. Clean-up                -> de-ghosted, monophonic, in-range, on the beat
    5. fretboard.py            -> string/fret per note (minimal hand travel)
    6. JSON                    -> consumed by the Flutter app

Output layout (one directory per track):

    <out>/<track>/
        transcription.json    the document the app loads
        bass.wav              isolated bass stem
        backing.wav           everything except the bass
        bass.mid              raw Basic Pitch transcription, for a DAW
"""

from __future__ import annotations

import argparse
import bisect
import json
import shutil
import statistics
import subprocess
import sys
import time
from importlib.util import find_spec
from pathlib import Path
from typing import Any, Dict, List, NoReturn, Optional, Sequence, Set, Tuple

try:  # works both as `python processor.py` and `python -m backend.processor`
    from .fretboard import (
        FingeringConfig,
        Instrument,
        NoteEvent,
        annotate_hand_positions,
        assign_fingerings,
        assign_fingers,
        fingering_stats,
        midi_to_name,
    )
    from . import tempo as tempo_mod
except ImportError:  # pragma: no cover - script execution
    from fretboard import (
        FingeringConfig,
        Instrument,
        NoteEvent,
        annotate_hand_positions,
        assign_fingerings,
        assign_fingers,
        fingering_stats,
        midi_to_name,
    )
    import tempo as tempo_mod

VERSION = "0.1.0"
SCHEMA_VERSION = 1
DEFAULT_TUNING = "E1,A1,D2,G2"
DEMUCS_BASS_STEM = "bass.wav"
DEMUCS_OTHER_STEM = "no_bass.wav"

_START = time.monotonic()


def use_utf8_output() -> None:
    """Make stdout able to carry non-Latin track names.

    Windows consoles default to cp1252, so printing a Japanese title raises
    UnicodeEncodeError and takes the whole run down with it — and anime and
    J-Pop filenames are the common case here, not an edge case. Anything the
    terminal still cannot draw is replaced rather than fatal.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass


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


def _stem_receipt(source: Path, model: str, preview: Optional[float]) -> Dict[str, Any]:
    """Identity of the audio a set of stems was made from."""
    try:
        size = source.stat().st_size
    except OSError:
        size = None
    return {
        "source": source.name,
        "source_bytes": size,
        "model": model,
        "preview_seconds": preview,
    }


def separate(
    source: Path,
    out_dir: Path,
    *,
    model: str,
    device: str,
    shifts: int,
    jobs: int,
    force: bool,
    preview: Optional[float] = None,
) -> Tuple[Path, Optional[Path]]:
    """Split ``source`` into a bass stem and a backing stem via Demucs."""
    bass_path = out_dir / "bass.wav"
    backing_path = out_dir / "backing.wav"
    receipt_path = out_dir / "stems.json"
    receipt = _stem_receipt(source, model, preview)

    if bass_path.exists() and backing_path.exists() and not force:
        # Reuse only stems made from *this* audio. Without the receipt, a 30s
        # --preview run left short stems behind and every later full run
        # silently reused them, so the song stayed 30 seconds long.
        try:
            previous = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous = None
        if previous == receipt:
            log(f"stems already present, reusing (--force to redo): {bass_path.name}")
            return bass_path, backing_path
        if previous is None:
            log("stems present but unlabelled — re-separating to be sure")
        else:
            was = previous.get("preview_seconds")
            log(f"stems were made from a different run "
                f"({'preview ' + str(was) + 's' if was else 'full song'}"
                f"{', model ' + str(previous.get('model'))}) — re-separating")

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
    receipt_path.write_text(json.dumps(receipt, indent=1), encoding="utf-8")
    log(f"stems: {bass_path.name}" + (f" + {backing_path.name}" if backing_path else ""))
    return bass_path, backing_path


# --------------------------------------------------------------------------- #
# Stage 2 — Attacks, and Stage 3 — Transcription
# --------------------------------------------------------------------------- #

ENGINES = ("basic-pitch", "torchcrepe")


def _pitch_window(
    instrument: Instrument, min_freq: Optional[float], max_freq: Optional[float]
) -> Tuple[float, float]:
    """Bound the search to what the instrument can actually produce.

    This is the single most effective guard against octave-up ghosts on low,
    harmonically rich bass notes.
    """
    low = min_freq if min_freq is not None else midi_to_hz(instrument.lowest_midi) * 0.97
    high = max_freq if max_freq is not None else midi_to_hz(instrument.highest_midi) * 1.03
    return low, high


def detect_onsets(path: Path, *, sensitivity: float, hop_ms: float = 5.0) -> List[float]:
    """Note attacks in the bass stem, in seconds.

    A pitch tracker cannot see a repeated note. Eight straight eighths on an
    open E are one unbroken f0, so any rule that cuts where the pitch moves
    reports them as a single note lasting a bar — and dense repeated notes are
    most of what this tool exists for. The attacks are plainly there in the
    waveform, so they are found separately and handed on: the segmenter cuts at
    them, `merge_repeats` refuses to undo those cuts, and `align_to_onsets`
    trusts them over the tracker's own timing.
    """
    if find_spec("librosa") is None or find_spec("numpy") is None:
        log("onsets: librosa not available, skipping")
        return []

    import librosa
    import numpy as np

    try:
        audio, rate = librosa.load(str(path), sr=22050, mono=True)
    except Exception as exc:
        log(f"onsets: could not load audio ({exc})")
        return []
    if audio.size == 0:
        return []

    hop = max(1, int(round(rate * hop_ms / 1000.0)))
    envelope = librosa.onset.onset_strength(y=audio, sr=rate, hop_length=hop)
    times = librosa.onset.onset_detect(
        onset_envelope=envelope,
        sr=rate,
        hop_length=hop,
        units="time",
        # The peak of the onset envelope sits part-way *into* the attack. The
        # note starts at the foot of the rise, which is what backtracking finds,
        # and a note drawn late is exactly what a play-along trainer must not do.
        backtrack=True,
        delta=0.07 / max(sensitivity, 0.05),
        wait=int(round(0.03 * rate / hop)),
    )
    onsets = sorted(float(t) for t in np.asarray(times).ravel().tolist())
    log(f"onsets: {len(onsets)} attacks in the bass stem "
        f"(sensitivity {sensitivity:g})")
    return onsets


def transcribe_basic_pitch(
    bass_path: Path,
    *,
    instrument: Instrument,
    onset_threshold: float,
    frame_threshold: float,
    min_note_ms: float,
    min_freq: Optional[float],
    max_freq: Optional[float],
) -> List[NoteEvent]:
    if find_spec("basic_pitch") is None:
        fail(
            "basic-pitch is not installed.",
            "pip install \"basic-pitch[onnx]\"   (onnxruntime backend, no TensorFlow)",
        )

    from basic_pitch import ICASSP_2022_MODEL_PATH
    from basic_pitch.inference import predict

    low, high = _pitch_window(instrument, min_freq, max_freq)
    log(f"basic-pitch: {low:.1f}–{high:.1f} Hz, onset={onset_threshold}, "
        f"frame={frame_threshold}, min_note={min_note_ms:g}ms")

    _model_output, _midi, note_events = predict(
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
    return to_events(note_events)


def crepe_floor_hz() -> float:
    """The lowest fmin torchcrepe can be given safely.

    CREPE's bin 0 sits at about 31.7 Hz. Ask for anything below it and
    ``frequency_to_bins`` returns a *negative* index, which torchcrepe then uses
    as ``probabilities[:, :minidx]`` — a negative slice that blanks almost every
    bin instead of none. The result is not an error: every frame comes back with
    -inf periodicity and a pitch pinned to the bottom of the range.
    """
    import torch
    import torchcrepe

    low, high = 10.0, 80.0
    for _ in range(50):
        mid = 0.5 * (low + high)
        if int(torchcrepe.convert.frequency_to_bins(torch.tensor(mid))) < 0:
            low = mid
        else:
            high = mid
    return high


def transcribe_torchcrepe(
    bass_path: Path,
    *,
    instrument: Instrument,
    min_note_ms: float,
    min_freq: Optional[float],
    max_freq: Optional[float],
    periodicity: float,
    keep_periodicity: Optional[float],
    hop_ms: float,
    model: str,
    device: str,
    onsets: Sequence[float] = (),
    attack_ms: float = 30.0,
    noise_floor_db: float = 24.0,
) -> List[NoteEvent]:
    """Monophonic pitch tracking, which is what an isolated bass stem is.

    Basic Pitch is a general polyphonic transcriber; CREPE only ever reports one
    f0 per frame. That is a better match for a separated bass, but it means this
    path cannot represent a double-stop at all.

    What comes back from the tracker is a pitch per frame, not notes. Turning
    one into the other is `segment_pitch_track`, and it is the stage that
    decides whether a repeated note is heard as one note or eight.
    """
    for module in ("torchcrepe", "librosa", "numpy"):
        if find_spec(module) is None:
            fail(
                f"{module} is not installed.",
                "pip install torchcrepe   (or run with --engine basic-pitch)",
            )

    import librosa
    import numpy as np
    import torch
    import torchcrepe

    low, high = _pitch_window(instrument, min_freq, max_freq)
    floor = crepe_floor_hz()
    if low < floor:
        log(f"torchcrepe: raising fmin {low:.1f} -> {floor * 1.02:.1f} Hz "
            f"(CREPE's lowest bin; below it the whole spectrum is masked out)")
        low = floor * 1.02
    high = min(high, float(torchcrepe.MAX_FMAX))

    rate = torchcrepe.SAMPLE_RATE
    audio, _ = librosa.load(str(bass_path), sr=rate, mono=True)
    hop = max(1, int(round(rate * hop_ms / 1000.0)))
    keep = periodicity * 0.6 if keep_periodicity is None else keep_periodicity
    keep = min(keep, periodicity)

    log(f"torchcrepe: {model} model on {device}, {low:.1f}–{high:.1f} Hz, "
        f"hop={hop_ms:g}ms, periodicity {keep:.2f}→{periodicity:.2f}")

    pitch, confidence = torchcrepe.predict(
        torch.from_numpy(audio).unsqueeze(0),
        rate,
        hop_length=hop,
        fmin=low,
        fmax=high,
        model=model,
        return_periodicity=True,
        batch_size=1024,
        device=device,
    )
    # A single dropped frame is analysis noise, not phrasing.
    confidence = torchcrepe.filter.median(confidence, 3)
    pitch = torchcrepe.filter.mean(pitch, 3)

    f0 = pitch.squeeze(0).cpu().numpy()
    conf = confidence.squeeze(0).cpu().numpy()
    semitones = librosa.hz_to_midi(np.clip(f0, 1e-6, None))
    # -inf periodicity is how torchcrepe says "nothing here". It has to read as
    # unvoiced rather than reach the segmenter as a NaN and compare false
    # against every threshold it meets.
    usable = np.isfinite(conf) & np.isfinite(semitones)
    conf = np.where(usable, conf, 0.0)
    semitones = np.where(usable, semitones, 0.0)
    log(f"torchcrepe: {int((conf >= periodicity).sum())}/{len(f0)} voiced frames")

    energy = librosa.feature.rms(y=audio, frame_length=2048, hop_length=hop)[0]

    events = segment_pitch_track(
        semitones.tolist(),
        conf.tolist(),
        energy.tolist(),
        hop_sec=hop / rate,
        onsets=onsets,
        start_threshold=periodicity,
        keep_threshold=keep,
        min_note_sec=min_note_ms / 1000.0,
        attack_sec=attack_ms / 1000.0,
    )

    events, quiet = drop_below_noise_floor(events, noise_floor_db)
    if quiet:
        log(f"torchcrepe: {quiet} note(s) more than {noise_floor_db:g} dB under "
            f"the median note dropped as separation bleed")

    peak = max((n.velocity for n in events), default=0.0)
    if peak > 0:
        for note in events:
            note.velocity = min(1.0, note.velocity / peak)

    log(f"torchcrepe: {len(events)} raw note events")
    return events


def segment_pitch_track(
    semitones: Sequence[float],
    confidence: Sequence[float],
    energy: Sequence[float],
    *,
    hop_sec: float,
    start_threshold: float,
    keep_threshold: float,
    min_note_sec: float,
    onsets: Sequence[float] = (),
    pitch_tolerance: float = 0.6,
    attack_sec: float = 0.03,
) -> List[NoteEvent]:
    """Turn a frame-wise pitch track into notes.

    Three rules, and each one is here because the obvious single rule — cut
    wherever the pitch moves — gets a bass line wrong in a particular way.

    **Attacks cut.** A repeated note has no pitch change to cut on, so a
    pitch-only rule reports eight eighths on an open E as one note lasting a
    bar. `onsets` are the attacks heard in the stem, and a note is cut at every
    one it contains. An attack inside the first `min_note_sec` of a note is that
    note's own attack, and is ignored.

    **Voicing is hysteretic.** One threshold would have to be strict enough to
    reject bleed from the separation and lenient enough not to chop a note in
    half wherever the tracker wobbles, and no single value is both. Two do not
    conflict: a note needs `start_threshold` to begin and only `keep_threshold`
    to carry on.

    **Pitch comes from the sustain.** The attack of a plucked string is
    inharmonic and the tracker wanders through it, so a plain median over the
    whole note is dragged towards whatever the first few frames guessed. The
    first `attack_sec` are dropped from the *pitch* estimate — never from the
    note's timing — and the rest combined as a confidence-weighted median.

    Pure Python over plain sequences, so it is testable without torch, librosa
    or an audio file. `velocity` comes back as the segment's peak level, on
    whatever scale `energy` uses; the caller normalises.
    """
    frames = min(len(semitones), len(confidence))
    if frames == 0 or hop_sec <= 0:
        return []

    keep_threshold = min(keep_threshold, start_threshold)
    attack_frames = max(0, int(round(attack_sec / hop_sec)))
    min_note_frames = min_note_sec / hop_sec
    cuts = {int(round(t / hop_sec)) for t in onsets}

    events: List[NoteEvent] = []
    seg_start = -1
    seg_ref = 0.0

    def flush(end: int) -> None:
        nonlocal seg_start
        if seg_start < 0:
            return
        if (end - seg_start) * hop_sec >= min_note_sec:
            span = energy[seg_start:max(seg_start + 1, min(end, len(energy)))]
            events.append(NoteEvent(
                start=seg_start * hop_sec,
                end=end * hop_sec,
                midi=_sustained_pitch(
                    semitones, confidence, seg_start, end, attack_frames
                ),
                velocity=max(span) if len(span) else 0.0,
            ))
        seg_start = -1

    for i in range(frames + 1):
        conf = confidence[i] if i < frames else 0.0
        pitch = semitones[i] if i < frames else 0.0
        continuing = seg_start >= 0

        if continuing:
            steady = (conf >= keep_threshold
                      and abs(pitch - seg_ref) < pitch_tolerance)
            replucked = i in cuts and (i - seg_start) >= min_note_frames
            if steady and not replucked:
                continue
            flush(i)

        # Straight out of a note the tracker is already committed, so the next
        # one needs only `keep_threshold`; starting from silence needs the
        # stricter value, which is what keeps bleed from becoming a note.
        floor = keep_threshold if continuing else start_threshold
        if i < frames and conf >= floor:
            seg_start = i
            seg_ref = round(pitch)

    return events


def _sustained_pitch(
    semitones: Sequence[float],
    confidence: Sequence[float],
    start: int,
    end: int,
    attack_frames: int,
) -> int:
    """Confidence-weighted median semitone over a note's sustain."""
    first = start + attack_frames if end - start > attack_frames + 2 else start
    pairs = sorted(
        (semitones[i], max(confidence[i], 0.0))
        for i in range(first, min(end, len(semitones)))
    )
    if not pairs:
        return int(round(semitones[min(start, len(semitones) - 1)]))

    total = sum(weight for _, weight in pairs)
    if total <= 0:
        return int(round(sum(value for value, _ in pairs) / len(pairs)))
    seen = 0.0
    for value, weight in pairs:
        seen += weight
        if seen >= total / 2:
            return int(round(value))
    return int(round(pairs[-1][0]))


def drop_below_noise_floor(
    events: List[NoteEvent], floor_db: float
) -> Tuple[List[NoteEvent], int]:
    """Drop notes far quieter than the part around them.

    Separation leaves a little of the rest of the mix in the bass stem, and a
    pitch tracker will happily follow it. What marks those out is not their
    pitch but their level: bleed sits tens of dB under the notes actually
    played. The floor is relative to the median note rather than absolute, so it
    carries between a quiet recording and a loud one, and it is not applied at
    all to a handful of notes, where a median means nothing.
    """
    if floor_db <= 0 or len(events) < 8:
        return events, 0
    levels = sorted(note.velocity for note in events)
    median = levels[len(levels) // 2]
    if median <= 0:
        return events, 0
    floor = median * (10.0 ** (-floor_db / 20.0))
    kept = [note for note in events if note.velocity >= floor]
    return kept, len(events) - len(kept)


def write_midi(events: Sequence[NoteEvent], path: Path) -> None:
    """Write the transcription as MIDI, matching the JSON exactly."""
    if find_spec("pretty_midi") is None:
        return
    import pretty_midi

    midi = pretty_midi.PrettyMIDI()
    track = pretty_midi.Instrument(
        program=pretty_midi.instrument_name_to_program("Electric Bass (finger)")
    )
    for note in events:
        track.notes.append(pretty_midi.Note(
            velocity=int(max(1, min(127, round(note.velocity * 127)))),
            pitch=note.midi,
            start=note.start,
            end=max(note.end, note.start + 0.01),
        ))
    midi.instruments.append(track)
    midi.write(str(path))


# --------------------------------------------------------------------------- #
# Stage 4 — Clean-up
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


def merge_repeats(
    events: List[NoteEvent], max_gap: float, onsets: Sequence[float] = ()
) -> List[NoteEvent]:
    """Rejoin one sustained note that the model split into fragments.

    A detected attack between two fragments makes them two notes however small
    the gap. Without that check this stage would undo every repeated-note cut
    the segmenter just made: the two halves of a re-plucked open E are the same
    pitch, end to end, which is exactly the shape a fragment has.
    """
    ordered = sorted(onsets)
    merged: List[NoteEvent] = []
    for note in events:
        target = None
        for prev in reversed(merged[-4:]):
            if prev.midi != note.midi or note.start - prev.end > max_gap:
                continue
            if not _onset_within(ordered, min(prev.end, note.start), note.start):
                target = prev
            break
        if target is None:
            merged.append(note)
        else:
            target.end = max(target.end, note.end)
            target.velocity = max(target.velocity, note.velocity)
    return merged


def _onset_within(
    onsets: Sequence[float], low: float, high: float, tolerance: float = 0.015
) -> bool:
    """Is there a detected attack in ``[low, high]``, give or take a frame?"""
    if not onsets:
        return False
    index = bisect.bisect_left(onsets, low - tolerance)
    return index < len(onsets) and onsets[index] <= high + tolerance


def align_to_onsets(
    events: List[NoteEvent], onsets: Sequence[float], tolerance: float
) -> Tuple[List[NoteEvent], int]:
    """Move each note start onto the attack the audio actually has.

    A pitch tracker reports a note once its pitch has settled, which is a little
    after the string was plucked. The error is small, but it is systematic and
    in one direction, and a play-along trainer draws it: every note sits a
    fraction late against the beat. Snapping to an attack within `tolerance`
    takes it out without inventing timing where no attack was found.
    """
    if not events or not onsets:
        return events, 0

    ordered = sorted(onsets)
    moved = 0
    for index, note in enumerate(events):
        target = _nearest(ordered, note.start)
        if target is None or abs(target - note.start) > tolerance:
            continue
        # Never behind the note before it, and never past its own end.
        floor = events[index - 1].start + 1e-3 if index else 0.0
        ceiling = note.end - 1e-3
        if ceiling <= floor:
            continue
        snapped = min(max(target, floor), ceiling)
        if abs(snapped - note.start) > 1e-6:
            note.start = snapped
            moved += 1
    events.sort(key=lambda n: (n.start, n.midi))
    return events, moved


def _nearest(values: Sequence[float], target: float) -> Optional[float]:
    """Closest entry of a sorted sequence, or None when it is empty."""
    if not values:
        return None
    index = bisect.bisect_left(values, target)
    best: Optional[float] = None
    for candidate in (index - 1, index):
        if 0 <= candidate < len(values):
            value = values[candidate]
            if best is None or abs(value - target) < abs(best - target):
                best = value
    return best


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


def _spectrum(samples, sample_rate: int, size: int = 16384):
    """Magnitude spectrum of one window, with the frequency of every bin."""
    import numpy as np

    length = max(size, len(samples))
    window = np.hanning(len(samples))
    return (
        np.abs(np.fft.rfft(samples * window, n=length)),
        np.fft.rfftfreq(length, 1.0 / sample_rate),
    )


def _harmonic_score(mags, freqs, freq: float, partials: int = 5) -> float:
    """How much of the spectrum a fundamental at `freq` would account for.

    One bin cannot tell a fundamental from a harmonic: at 41 Hz the second
    harmonic is routinely the louder of the two, which is why octave errors
    happen at all. The comb can — a pitch an octave up has to explain every
    partial it claims, and it never does, because the true fundamental's odd
    harmonics fall in the gaps between its own.

    Partials are weighted down as they climb, and every band is at least two
    bins wide: a percentage-width band around a 41 Hz fundamental is narrower
    than the bin spacing, so a proportional width on its own can select nothing.
    """
    if len(freqs) < 2:
        return 0.0
    bin_hz = float(freqs[1] - freqs[0])
    total = 0.0
    for partial in range(1, partials + 1):
        centre = freq * partial
        if centre >= float(freqs[-1]):
            break
        half = max(centre * 0.03, 2.0 * bin_hz)
        band = (freqs >= centre - half) & (freqs <= centre + half)
        if not band.any():
            continue
        total += float(mags[band].max()) * (0.9 ** (partial - 1))
    return total


OCTAVE_SCOPES = ("all", "strays", "off")

# Long enough to resolve a 41 Hz fundamental, short enough that only the note's
# own sustain is in the window.
_ANALYSIS_SEC = 0.25


def _note_window(handle, note: NoteEvent, rate: int):
    """Samples from the steady part of a note, mono; None if there are too few."""
    skip = min(0.02, max(note.duration, 0.0) * 0.2)
    handle.seek(max(0, int((note.start + skip) * rate)))
    count = int(min(max(note.duration, 0.05), _ANALYSIS_SEC) * rate)
    frames = handle.read(max(count, 1024), dtype="float32")
    if len(frames) < 1024:
        return None
    if getattr(frames, "ndim", 1) > 1:
        frames = frames.mean(axis=1)
    return frames


def _stray_notes(
    events: Sequence[NoteEvent], window: float, threshold: int
) -> Set[int]:
    """Notes sitting far above their own neighbourhood, as a set of ``id()``."""
    starts = [n.start for n in events]
    lo = hi = 0
    strays: Set[int] = set()
    for i, note in enumerate(events):
        while lo < len(starts) and starts[lo] < note.start - window:
            lo += 1
        while hi < len(starts) and starts[hi] <= note.start + window:
            hi += 1
        neighbours = [events[j].midi for j in range(lo, hi) if j != i]
        if len(neighbours) < 4:
            continue
        if note.midi - statistics.median(neighbours) >= threshold:
            strays.add(id(note))
    return strays


def fix_octave_errors(
    events: List[NoteEvent],
    instrument: Instrument,
    bass_path: Optional[Path],
    *,
    window: float,
    threshold: int,
    scope: str = "all",
    margin: float = 1.2,
    stray_margin: float = 1.0,
) -> Tuple[List[NoteEvent], int]:
    """Pull a note down an octave when the stem says its fundamental is lower.

    Both engines sometimes lock onto the second harmonic of a low bass note, and
    one such note is enough to send the fingering search to the 24th fret and
    back. Context cannot identify them, though: measured against a fast J-Pop
    line, a "10 semitones above the local median" rule moved 89 notes and the
    bass stem's own spectrum disagreed with 86 of them — the part genuinely
    climbs.

    So the audio decides, and with `scope="all"` it is asked about every note
    rather than only the ones that look odd out of context. An octave error in
    the middle of the part's own range is invisible to a median and plain in the
    spectrum, and those are the ones that were being missed. Each note is scored
    as a harmonic comb against the same comb an octave down and moves only if
    the lower one wins by `margin`; notes that context *does* nominate as strays
    are held to the gentler `stray_margin`, since two independent signals
    already agree about them.

    The default margin comes from measurement rather than taste: over synthesised
    bass partials, a genuine note scores 0.57-0.64 against the octave below it
    and an octave error scores 1.17-1.77, so 1.2 sits in the gap with room on
    both sides. `test_transcribe.py` asserts that separation.
    """
    if not events or bass_path is None or not bass_path.exists():
        return events, 0
    if scope == "off":
        return events, 0
    if find_spec("numpy") is None or find_spec("soundfile") is None:
        return events, 0

    import soundfile as sf

    strays = _stray_notes(events, window, threshold)
    checked = events if scope == "all" else [n for n in events if id(n) in strays]
    if not checked:
        return events, 0

    shifted = 0
    with sf.SoundFile(str(bass_path)) as handle:
        rate = handle.samplerate
        for note in checked:
            required = stray_margin if id(note) in strays else margin
            while note.midi - 12 >= instrument.lowest_midi:
                frames = _note_window(handle, note, rate)
                if frames is None:
                    break
                mags, freqs = _spectrum(frames, rate)
                here = _harmonic_score(mags, freqs, midi_to_hz(note.midi))
                below = _harmonic_score(mags, freqs, midi_to_hz(note.midi - 12))
                if below < here * required:
                    break  # the audio backs the higher pitch: leave it alone
                note.midi -= 12
                note.octave_shift -= 1
                shifted += 1
    return events, shifted


def fit_to_instrument(events: List[NoteEvent], instrument: Instrument) -> List[NoteEvent]:
    """Octave-shift stragglers into range rather than dropping them."""
    for note in events:
        fitted, shift = instrument.fit_pitch(note.midi)
        note.midi = fitted
        note.octave_shift += shift
    return [n for n in events if instrument.lowest_midi <= n.midi <= instrument.highest_midi]


# --------------------------------------------------------------------------- #
# Stage 5b — Tempo
# --------------------------------------------------------------------------- #

def detect_tempo(
    bass_path: Path,
    backing_path: Optional[Path],
    *,
    beats_per_bar: int,
    start_bpm: Optional[float],
) -> Optional["tempo_mod.TempoGrid"]:
    """Find the beat in the *mix*, not the bass alone.

    Demucs splits into bass + everything-else, so adding the stems back together
    reconstructs the original. The drums are in there, and they are what carries
    the beat — tracking tempo from an isolated bass line is far harder.
    """
    if find_spec("librosa") is None or find_spec("numpy") is None:
        log("tempo: librosa not available, skipping")
        return None

    import librosa
    import numpy as np

    try:
        audio, rate = librosa.load(str(bass_path), sr=22050, mono=True)
        if backing_path is not None and backing_path.exists():
            backing, _ = librosa.load(str(backing_path), sr=22050, mono=True)
            width = min(len(audio), len(backing))
            audio = audio[:width] + backing[:width]
            source = "bass + backing (reconstructed mix)"
        else:
            source = "bass stem only"
        peak = float(np.abs(audio).max()) or 1.0
        audio = audio / peak
    except Exception as exc:
        log(f"tempo: could not load audio ({exc})")
        return None

    grid = tempo_mod.detect(
        audio, rate, beats_per_bar=beats_per_bar, start_bpm=start_bpm
    )
    if grid is None:
        log("tempo: no beat found")
        return None

    log(f"tempo: {grid.bpm:.1f} bpm, {len(grid.beats)} beats from {source}, "
        f"confidence {grid.confidence:.2f} "
        f"({tempo_mod.describe_confidence(grid.confidence)})")
    return grid


# --------------------------------------------------------------------------- #
# Stage 6 — Document
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
    grid: Optional[Any] = None,
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
            "finger": n.finger,
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
        # Beat grid: musicians count in bars, and the app snaps seeking to them.
        "tempo": grid.to_dict() if grid is not None else None,
        "beats": [round(b, 4) for b in grid.beats] if grid is not None else [],
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
    group.add_argument("--engine", choices=ENGINES, default="torchcrepe",
                       help="basic-pitch is polyphonic and general; torchcrepe "
                            "tracks a single f0, which is what a bass stem is")
    group.add_argument("--crepe-model", default="full", choices=["tiny", "full"],
                       help="torchcrepe network size")
    group.add_argument("--periodicity", type=float, default=0.20,
                       help="torchcrepe voicing threshold to *start* a note; "
                            "lower keeps more notes. 0.20 measured best on the "
                            "one song this was tuned on")
    group.add_argument("--keep-periodicity", type=float,
                       help="voicing threshold to *continue* a note; the "
                            "hysteresis that stops a wobble cutting a note in "
                            "half (default: 60%% of --periodicity)")
    group.add_argument("--attack-ms", type=float, default=30.0,
                       help="ignore this much of each attack when deciding the "
                            "note's pitch; the pluck itself is inharmonic")
    group.add_argument("--noise-floor-db", type=float, default=24.0,
                       help="drop notes this far below the median note level, "
                            "which is where separation bleed sits; 0 disables")
    group.add_argument("--crepe-hop-ms", type=float, default=10.0,
                       help="torchcrepe analysis hop")
    group.add_argument("--onset-threshold", type=float, default=0.5,
                       help="lower finds more note starts (and more false ones)")
    group.add_argument("--frame-threshold", type=float, default=0.3,
                       help="lower sustains notes longer")
    group.add_argument("--min-note-ms", type=float, default=58.0,
                       help="shortest note to keep; 58ms clears 16ths at 250bpm")
    group.add_argument("--min-freq", type=float, help="default: lowest note of the tuning")
    group.add_argument("--max-freq", type=float, help="default: highest fretted note")
    group.add_argument("--merge-gap-ms", type=float, default=30.0,
                       help="rejoin same-pitch fragments closer than this, "
                            "unless an attack was detected between them")
    group.add_argument("--ghost-window-ms", type=float, default=50.0,
                       help="onset window for octave-ghost detection")
    group.add_argument("--ghost-ratio", type=float, default=1.0,
                       help="drop an octave-up note quieter than fundamental * ratio")
    group.add_argument("--simultaneity-ms", type=float, default=30.0,
                       help="notes this close together count as one attack")
    group.add_argument("--polyphonic", action="store_true",
                       help="keep overlapping notes instead of collapsing to one voice")
    group.add_argument("--no-octave-fix", action="store_true",
                       help="skip the octave check entirely (same as "
                            "--octave-check off)")
    group.add_argument("--octave-check", choices=OCTAVE_SCOPES, default="all",
                       help="which notes to check against the stem's spectrum: "
                            "every one, or only those that look odd in context")
    group.add_argument("--octave-margin", type=float, default=1.2,
                       help="how much better the octave below has to fit before "
                            "an ordinary note is moved down to it")
    group.add_argument("--octave-threshold", type=int, default=10,
                       help="semitones above the local median that counts as a stray")
    group.add_argument("--octave-window", type=float, default=2.0,
                       help="seconds of context used to judge a stray note")

    group = parser.add_argument_group("attacks")
    group.add_argument("--no-onsets", action="store_true",
                       help="do not detect attacks; repeated notes then come "
                            "back as one long note, since their pitch never "
                            "changes")
    group.add_argument("--onset-sensitivity", type=float, default=1.0,
                       help="higher finds more attacks (and more false ones)")
    group.add_argument("--onset-align-ms", type=float, default=45.0,
                       help="snap a note start to an attack this close to it; "
                            "0 leaves the tracker's own timing alone")

    group = parser.add_argument_group("tempo")
    group.add_argument("--bpm", type=float,
                       help="skip detection and use this tempo")
    group.add_argument("--first-beat", type=float, default=0.0,
                       help="seconds to the first downbeat, with --bpm")
    group.add_argument("--beats-per-bar", type=int, default=4)
    group.add_argument("--start-bpm", type=float,
                       help="force a single starting tempo for the search; by "
                            "default several are tried and the most confident "
                            "grid wins")
    group.add_argument("--no-tempo", action="store_true",
                       help="skip beat detection entirely")

    group = parser.add_argument_group("instrument")
    group.add_argument("--tuning", default=DEFAULT_TUNING,
                       help="open strings, low to high")
    group.add_argument("--frets", type=int, default=24)
    group.add_argument("--max-fret", type=int,
                       help="restrict fingerings to this fret and below")

    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    use_utf8_output()
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
            preview=args.preview,
        )

    # ---- stage 2: attacks ---------------------------------------------------
    # Found once, from the stem, and used by three stages after it: the
    # segmenter cuts on them, merge_repeats refuses to undo those cuts, and note
    # starts are snapped to them. Neither engine can find a repeated note on its
    # own, because a repeated note has no pitch change to find.
    onsets: List[float] = []
    if not args.no_onsets:
        onsets = detect_onsets(bass_path, sensitivity=args.onset_sensitivity)

    # ---- stage 3: transcription ---------------------------------------------
    if args.engine == "torchcrepe":
        events = transcribe_torchcrepe(
            bass_path,
            instrument=instrument,
            min_note_ms=args.min_note_ms,
            min_freq=args.min_freq,
            max_freq=args.max_freq,
            periodicity=args.periodicity,
            keep_periodicity=args.keep_periodicity,
            hop_ms=args.crepe_hop_ms,
            model=args.crepe_model,
            device=pick_device(args.device),
            onsets=onsets,
            attack_ms=args.attack_ms,
            noise_floor_db=args.noise_floor_db,
        )
    else:
        events = transcribe_basic_pitch(
            bass_path,
            instrument=instrument,
            onset_threshold=args.onset_threshold,
            frame_threshold=args.frame_threshold,
            min_note_ms=args.min_note_ms,
            min_freq=args.min_freq,
            max_freq=args.max_freq,
        )

    # ---- stage 4: clean-up --------------------------------------------------
    events.sort(key=lambda n: (n.start, n.midi))
    before = len(events)
    events = drop_short(events, args.min_note_ms / 1000.0)
    events = remove_octave_ghosts(
        events, args.ghost_window_ms / 1000.0, args.ghost_ratio
    )
    events = merge_repeats(events, args.merge_gap_ms / 1000.0, onsets)
    if onsets and args.onset_align_ms > 0:
        events, moved = align_to_onsets(
            events, onsets, args.onset_align_ms / 1000.0
        )
        log(f"onsets: {moved}/{len(events)} note start(s) snapped to a "
            f"detected attack")
    if not args.polyphonic:
        events = make_monophonic(events, args.simultaneity_ms / 1000.0)
    octave_scope = "off" if args.no_octave_fix else args.octave_check
    if octave_scope != "off":
        events, shifted = fix_octave_errors(
            events, instrument, bass_path,
            window=args.octave_window,
            threshold=args.octave_threshold,
            scope=octave_scope,
            margin=args.octave_margin,
        )
        log(f"octave fix: {shifted} note(s) contradicted by the stem's own "
            f"spectrum and pulled down an octave (checked: {octave_scope})")
    events = fit_to_instrument(events, instrument)
    log(f"clean-up: {before} -> {len(events)} notes")
    if not events:
        fail("no notes survived clean-up.",
             "torchcrepe: try --periodicity 0.10 --noise-floor-db 0; "
             "basic-pitch: try --onset-threshold 0.3 --frame-threshold 0.2")

    # ---- stage 5: fingering -------------------------------------------------
    assign_fingerings(
        events, instrument, FingeringConfig(max_fret=args.max_fret)
    )
    annotate_hand_positions(events)
    assign_fingers(events)

    # ---- stage 5b: tempo ----------------------------------------------------
    duration, sample_rate = audio_info(bass_path)
    grid = None
    if args.bpm:
        grid = tempo_mod.uniform_grid(
            args.bpm, duration or 0.0, args.first_beat, args.beats_per_bar
        )
        log(f"tempo: {args.bpm:g} bpm set by hand, first beat {args.first_beat:g}s")
    elif not args.no_tempo:
        grid = detect_tempo(
            bass_path, backing_path,
            beats_per_bar=args.beats_per_bar, start_bpm=args.start_bpm,
        )

    # ---- stage 6: document --------------------------------------------------

    # Transcribing from a stem means `source` is "bass.wav", which is not the
    # song's name. Keep whatever a previous run in this folder recorded, and
    # fall back to the track name rather than labelling the track after a stem.
    display_name = source.name
    if args.bass_stem:
        previous = out_dir / "transcription.json"
        prior_name = None
        if previous.exists():
            try:
                prior = json.loads(previous.read_text(encoding="utf-8"))
                prior_name = (prior.get("source") or {}).get("file")
            except (OSError, ValueError):
                prior_name = None
        # Never inherit a stem filename as the song's title.
        if prior_name in (DEMUCS_BASS_STEM, "backing.wav", DEMUCS_OTHER_STEM):
            prior_name = None
        display_name = prior_name or track

    document = build_document(
        events,
        instrument=instrument,
        source=Path(display_name),
        duration=duration,
        sample_rate=sample_rate,
        bass_rel=_relative(bass_path, out_dir),
        backing_rel=_relative(backing_path, out_dir) if backing_path else None,
        grid=grid,
        settings={
            "model": args.engine,
            "onset_threshold": args.onset_threshold,
            "frame_threshold": args.frame_threshold,
            "min_note_ms": args.min_note_ms,
            "monophonic": not args.polyphonic,
            "engine": args.engine,
            "separator": None if args.bass_stem else f"demucs {args.model}",
            # Recognition settings, so a track can be compared with one
            # processed before these existed.
            "attacks_detected": len(onsets),
            "onset_align_ms": args.onset_align_ms if onsets else 0.0,
            "noise_floor_db": args.noise_floor_db,
            "octave_check": octave_scope,
        },
    )

    json_path = out_dir / "transcription.json"
    json_path.write_text(dump_json(document), encoding="utf-8")
    try:
        write_midi(events, out_dir / "bass.mid")
    except Exception as exc:  # non-fatal: the JSON is the real output
        log(f"warning: could not write bass.mid ({exc})")

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
