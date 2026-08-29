# Backend

Separates the bass out of a song, transcribes it, and writes the JSON the
Flutter app renders.

## Install

`fretboard.py`, `test_fretboard.py` and `make_sample.py` need **nothing** —
standard library only. Run the tests right now:

```powershell
python test_fretboard.py
python make_sample.py      # regenerates the app's demo riff
```

The pipeline itself needs two models:

```powershell
pip install -r requirements.txt
```

- **Demucs** pulls PyTorch (~2.5 GB with CUDA wheels). If you want a specific
  CUDA build, install torch *first* so pip does not resolve the CPU-only wheel.
- **Basic Pitch** is installed with the `[onnx]` extra, which runs on
  onnxruntime instead of TensorFlow: ~600 MB smaller and faster on CPU for a
  network this size.
- **ffmpeg** on PATH lets Demucs read mp3/m4a/flac directly.

## Use

```powershell
# full pipeline
python processor.py "C:\Music\song.mp3"

# iterate on transcription settings without re-running separation each time
python processor.py "C:\Music\song.mp3" --preview 30
python processor.py "C:\Music\song.mp3" --onset-threshold 0.4

# cleaner stems, N times slower
python processor.py "C:\Music\song.mp3" --shifts 2

# you already have a bass stem
python processor.py --bass-stem stems/bass.wav --backing-stem stems/backing.wav

# five-string, or drop-D
python processor.py song.mp3 --tuning B0,E1,A1,D2,G2
python processor.py song.mp3 --tuning D1,A1,D2,G2
```

Output lands in `../data/<track>/`: `transcription.json`, `bass.wav`,
`backing.wav`, and `bass.mid` for a DAW. Separation is skipped if the stems are
already there — pass `--force` to redo it.

`--help` lists every knob.

## When the transcription is wrong

The clean-up stage exists because raw Basic Pitch output on bass has four
characteristic failure modes. Each has a dial:

| Symptom | Cause | Try |
|---|---|---|
| Notes an octave too high | Harmonics beat the fundamental | Lower `--max-freq`; raise `--ghost-ratio` |
| Fast runs come out as one long note | Onsets missed | `--onset-threshold 0.3` |
| Machine-gun repeats of one pitch | One note split into fragments | `--merge-gap-ms 60` |
| Ghost notes in the gaps | Bleed from the separation | `--onset-threshold 0.6`, or `--shifts 2` |
| 32nd notes disappear | Below the length floor | `--min-note-ms 40` |
| Chords flattened to one note | Monophonic collapse, which is on by default | `--polyphonic` |

Two settings are derived from `--tuning` rather than fixed: the frequency
window handed to Basic Pitch is the instrument's actual range, which is the
single most effective guard against octave-up ghosts on low notes.

`stats` in the output JSON is the quickest sanity check. `peak_notes_per_sec`
far above what the song plays means false positives; a `max_fret_jump` above
about 7 means the fingering search was handed pitches no hand would play, which
usually means the transcription is wrong rather than the fingering.

## Speed

Separation dominates the wall clock; everything after it is seconds. Demucs
picks CUDA automatically when torch reports it — check the log line reads
`demucs: htdemucs on cuda`, because falling back to `cpu` is roughly an order of
magnitude slower and is easy not to notice.

`--shifts N` multiplies separation time by N. Use `--preview 30` while tuning
transcription settings, then run the full song once you are happy; the second
run reuses the stems already on disk, so only the transcription repeats.
