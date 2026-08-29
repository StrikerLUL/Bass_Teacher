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

## Which engine

`--engine torchcrepe` (default) or `--engine basic-pitch`.

CREPE tracks a single f0 per frame; Basic Pitch is a general polyphonic
transcriber. A separated bass stem is monophonic, so CREPE is the better fit —
and `compare_engines.py` measures that rather than assuming it:

```powershell
python compare_engines.py ../data/<track>/bass.wav `
  basic-pitch=../data/a/transcription.json torchcrepe=../data/b/transcription.json
```

Measured on a 4-minute J-Pop track, scoring each transcription against the bass
stem's own spectrum:

| metric | basic-pitch | torchcrepe |
|---|---|---|
| harmonic fit (higher better) | 0.309 | **0.370** |
| octave errors (lower better) | 0.8% | **0.0%** |
| onset recall (higher better) | 56.4% | **57.9%** |
| onset precision (higher better) | **71.1%** | 68.0% |
| frame coverage (higher better) | **77.2%** | 72.0% |
| spurious notes (lower better) | 6.0% | **5.0%** |
| max fret jump (lower better) | 19 | **9** |
| mean fret jump (lower better) | 1.59 | **1.18** |

Basic Pitch wins frame coverage, but that is sustain length rather than extra
detections — its notes occupy 66% of the track against CREPE's 61%, while CREPE
finds *more* actual note onsets. The 19-fret hand jump it produced came from
isolated stray notes that CREPE does not emit at all.

Caveats worth knowing: torchcrepe takes ~45 s for a 4-minute song against ~7 s
for Basic Pitch, it cannot represent a double-stop, and `--periodicity 0.20` was
tuned on a single track. Use `--engine basic-pitch` for polyphonic bass parts.

**A trap if you change the frequency range:** CREPE's lowest bin is 31.7 Hz. Ask
torchcrepe for anything below it and the internal mask uses a negative index,
blanking nearly every bin — every frame comes back with `-inf` periodicity and
no error. `processor.py` raises `fmin` to that floor and logs when it does, which
matters for 5-string tunings (B0 is 30.9 Hz, below what CREPE can see).

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
