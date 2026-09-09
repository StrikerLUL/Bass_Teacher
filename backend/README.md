# Backend

Separates the bass out of a song, transcribes it, and writes the JSON the
Flutter app renders.

## Install

`fretboard.py`, `test_fretboard.py`, `test_transcribe.py` and `make_sample.py`
need **nothing** — standard library only. Run the tests right now:

```powershell
python test_fretboard.py
python test_transcribe.py  # note recognition: segmentation, octaves, bleed
python make_sample.py      # regenerates the app's demo riff
```

`test_transcribe.py` works on plain sequences of numbers, so the stages that
decide where one note ends and the next begins are checked without torch, a
model download or an audio file. A few octave tests want numpy and skip
themselves without it.

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

## How a note is found

The engines report a pitch, not notes. Four stages turn one into the other, and
each exists because the obvious rule gets a bass line wrong in a specific way.

**Attacks are detected separately, and they are what cuts.** A pitch tracker
cannot see a repeated note: eight straight eighths on an open E are one
unbroken f0, so any rule that cuts where the pitch moves reports them as a
single note lasting a bar. `librosa.onset` finds the plucks in the stem, with
backtracking so each one lands at the foot of the attack rather than at the
peak of the envelope, and the segmenter cuts at every one it finds. This is
the single biggest difference on dense repeated-note lines, which is most of
what this tool is for.

The attacks are then used twice more. `merge_repeats` will not join two
fragments across one — without that it would immediately undo every cut, since
two plucks of one pitch look exactly like one fragmented note. And note starts
are snapped to an attack within `--onset-align-ms`, which takes out the small,
systematic lateness of "report the note once the pitch has settled".

`--no-onsets` turns all three off, which is the old behaviour.

**Voicing has two thresholds, not one.** A single threshold has to be strict
enough to reject bleed from the separation and lenient enough not to chop a
note in half wherever the tracker wobbles, and no value is both. A note now
needs `--periodicity` to *start* and only `--keep-periodicity` (default: 60% of
it) to *continue*.

**Pitch comes from the sustain.** The attack of a plucked string is inharmonic
and the tracker wanders through it, so a plain median over the note is dragged
towards whatever the first few frames guessed. The first `--attack-ms` are
dropped from the pitch estimate — never from the note's timing — and the rest
combined as a confidence-weighted median.

**Bleed is recognised by level, not by pitch.** What leaks through separation
sits tens of dB under the notes actually played, so anything more than
`--noise-floor-db` below the median note is dropped. The floor is relative, so
it travels between a quiet recording and a loud one, and it is not applied to a
handful of notes, where a median means nothing.

### The octave check

Both engines sometimes lock onto the second harmonic of a low note. The old
rule only examined notes that looked odd *in context* — ten semitones above the
local median — which misses every octave error that lands inside the part's own
range.

Every note is now scored against the stem as a harmonic comb: the fundamental
plus four partials, weighted down as they climb, compared with the same comb an
octave below. The note moves down only if the lower comb wins by
`--octave-margin`. One bin cannot tell a fundamental from a harmonic — at 41 Hz
the second harmonic is routinely the louder — but the comb can, because a pitch
an octave up has to account for every partial it claims and never does.

The default margin is measured rather than chosen. Over synthesised bass
partials:

| | ratio of octave-below comb to reported comb |
|---|---|
| genuine notes, midi 28-62 | 0.57 – 0.64 |
| genuine note with -20 dB bleed an octave down | 0.63 – 0.64 |
| octave errors (fundamental at 10-80% of the 2nd harmonic) | 1.21 – 1.77 |

1.2 sits in the gap with room on both sides. `test_transcribe.py` asserts that
separation, so a change to the scoring that closes the gap fails the suite.

`--octave-check strays` restores the old context-nominated behaviour, and
`--octave-check off` (or `--no-octave-fix`) skips it. Checking every note costs
one seek and one FFT per note — a second or two on a four-minute song.

Two notes on why context is not trusted on its own: measured against a fast
J-Pop line, the "10 semitones above the local median" rule moved 89 notes and
the stem's spectrum disagreed with 86 of them, because the part genuinely
climbs. Notes that context *does* nominate are still held to a gentler margin,
since two independent signals agree about them.

## When the transcription is wrong

The clean-up stage exists because raw Basic Pitch output on bass has four
characteristic failure modes. Each has a dial:

| Symptom | Cause | Try |
|---|---|---|
| Notes an octave too high | Harmonics beat the fundamental | Lower `--octave-margin` towards 1.0; lower `--max-freq` |
| A note moved down that should not have been | The octave check was too eager | Raise `--octave-margin`, or `--octave-check strays` |
| Repeated notes come out as one long note | Attacks missed | `--onset-sensitivity 1.5` |
| Fast runs come out as one long note | Onsets missed | `--onset-threshold 0.3` (basic-pitch) |
| Machine-gun repeats of one pitch | One note split into fragments | `--merge-gap-ms 60`, or `--onset-sensitivity 0.7` |
| Ghost notes in the gaps | Bleed from the separation | Raise `--periodicity`, lower `--noise-floor-db` to 18, or `--shifts 2` |
| A note cut in half part-way through | Voicing dips mid-note | Lower `--keep-periodicity` |
| Quiet real notes disappear | The noise floor caught them | Raise `--noise-floor-db`, or 0 to disable |
| 32nd notes disappear | Below the length floor | `--min-note-ms 40` |
| Notes all sit slightly late | Attack alignment off, or no attacks found | `--onset-sensitivity 1.5` |
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
