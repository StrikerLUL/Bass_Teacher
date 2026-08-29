# Bass Trainer

Open-source bass practice tool. Feed it a song, get an isolated bass stem, a
backing track, and a fretboard that lights up in time with the music.

Built for fast, dense basslines — J-Pop, Vocaloid, anime soundtracks — which is
what drives most of the design decisions below.

```
song.mp3
   │
   ├─ Demucs ──────────► bass.wav + backing.wav
   │                        │
   │                        └─ torchcrepe ──► note events
   │                                              │
   │                                     clean-up + fingering
   │                                              │
   └──────────────────────────────────► transcription.json
                                                  │
                                          Flutter fretboard
```

## Layout

| Path | What it is |
|---|---|
| `backend/processor.py` | The pipeline: separate → transcribe → clean → finger → JSON |
| `backend/fretboard.py` | Fretboard geometry and the fingering search (no dependencies) |
| `backend/test_fretboard.py` | Tests for the fingering search |
| `backend/make_sample.py` | Builds the demo the app ships with; smoke-tests the clean-up |
| `app/lib/` | Flutter app: fretboard renderer, playback clock, stem player |
| `data/` | Output, one folder per track (git-ignored) |

## Quick start

```powershell
# backend — see backend/README.md for the dependency install
cd backend
python processor.py "C:\Music\song.mp3" --preview 30

# app — see app/README.md for first-time platform scaffolding
cd ..\app
flutter run -d windows
```

The app opens with a built-in demo riff, so it renders before you have
processed anything.

## Two decisions worth knowing about

**Fingering is computed, not looked up.** A MIDI pitch does not identify a place
on a neck: E2 is playable at string 0 fret 12, string 1 fret 7 or string 2
fret 2. Picking the naive one turns every octave leap into a 12-fret slide.
`fretboard.py` runs a Viterbi pass that balances a per-note position cost
against hand travel between neighbours, weighted by the time available to move —
so fast passages are forced into a single hand position while slow ones are free
to relocate. Open strings *inherit* the hand anchor rather than resetting it,
because playing an open D does not move your hand.

**The UI does not trust the audio engine's clock.** Engines report position in
~100-200 ms steps; animating straight off those readings stutters visibly at
10 notes per second. `PlaybackClock` extrapolates from wall time between
readings and treats each reading as a correction — nudged if small, snapped if
large — and refuses to run backwards mid-playback.

## Transcription format

`data/<track>/transcription.json`, `schema_version: 1`. Stem paths are relative
to the JSON so a track folder can be moved.

```jsonc
{
  "schema_version": 1,
  "source":     { "file": "song.mp3", "duration_sec": 214.3, "sample_rate": 44100 },
  "stems":      { "bass": "bass.wav", "backing": "backing.wav" },
  "instrument": { "strings": 4, "tuning": ["E1","A1","D2","G2"],
                  "tuning_midi": [28,33,38,43], "frets": 24,
                  "string_order": "0 = lowest pitched" },
  "stats":      { "notes": 812, "peak_notes_per_sec": 11, "max_fret_jump": 4 },
  "tempo":      { "bpm": 172.3, "beats_per_bar": 4, "first_downbeat_sec": 1.05,
                  "confidence": 0.54, "manual": false,
                  "detail": { "regularity": 0.7, "precision": 0.35, "recall": 0.68 } },
  "beats":      [0.12, 0.47, 0.82, "..."],
  "notes": [
    { "start": 0.512, "end": 0.698, "midi": 40, "name": "E2",
      "velocity": 0.82, "string": 1, "fret": 7, "hand": 7, "finger": 1 }
  ]
}
```

`finger` is the fretting finger, 1 (index) to 4 (pinky); **0 means an open
string**, where no finger is used. Inside the four-fret box it is one finger per
fret counting up from the hand position; one fret past either edge is a stretch
(pinky up, index back) rather than a move, and anything further means the hand
shifted, which lands on the index.

`string` 0 is the **lowest pitched** string throughout. `hand` is the fret the
fretting hand should sit at for the surrounding phrase; the app uses it to draw
the position box and to work out `finger`. `string`/`fret` may be null for a note
outside the instrument's range — render it as a rest rather than failing.

If a file carries only pitches, the app computes positions itself on load using
the same algorithm ported to Dart, so hand-written and third-party JSON work.

## Tempo and bars

`tempo.py` tracks the beat in the *reconstructed mix* — bass plus backing is
the original, and the drums are what carry the beat. It reports a confidence
built from an F-measure between the beats and the onsets actually heard:
precision punishes a grid running too fast into the gaps, recall punishes one
running too slow.

Both halves are needed. Scoring only "how loud is the audio at the beats"
rewards *sparse* grids — measured on a 172 bpm track, a half-time grid scored
3.09 against the truth's 2.56 and won. Recall is what exposes it: the half-time
grid matched 46% of onsets against 68%.

Detection also tries several starting tempos and keeps the most confident grid.
Starting at 120 on that same track returned 112.3 bpm — hearing three eighth
notes as one beat — while starting nearer found 172.3 with higher confidence.
The score already ranked the right answer above the wrong one; only the search
start was at fault.

Override it with `--bpm`, or in the app's tempo dialog, which stores a manual
tempo per track in the settings file rather than rewriting the transcription.

## Status

Done: pipeline with two selectable transcription engines, fingering search and
finger numbering (tested both sides), library screen, fretboard renderer,
transport, mute/solo/gain, speed control, audio-visual calibration.

Not done yet: no A-B practice loop; no bar/beat grid; no microphone input; no
tab export; two-engine stem sync is corrected on a 500 ms timer rather than
sample-locked.

Never verified by ear: every check so far has been a measurement or an offline
render. No one has confirmed the app actually sounds right.
