# Flutter app

Fretboard visualiser synchronised to two-stem playback.

## First run

This folder holds `lib/`, `test/`, `assets/` and `pubspec.yaml`, but no
platform directories — they are machine-generated. Create them without
disturbing the source:

```powershell
# from the repo root: generate a throwaway project, take only its platform dirs
flutter create --project-name bass_trainer --platforms=windows,android _scaffold
Copy-Item _scaffold\windows -Destination app\ -Recurse
Copy-Item _scaffold\android -Destination app\ -Recurse
Remove-Item _scaffold -Recurse -Force

cd app
flutter pub get
flutter run -d windows
```

Do not run `flutter create .` directly in `app/` — depending on the Flutter
version it can overwrite `lib/main.dart`, and there is no git history here yet
to recover it from.

Needs Flutter **3.27+** (the code uses `Color.withValues`).

```powershell
flutter test
```

## Screens

`LibraryScreen` is home: every track in `data/` as a card showing duration, note
count, peak notes/sec, which stems exist, the engine used and the tuning.
Tapping one loads it and pushes `PlayerScreen` on top. The card menu offers
**Re-transcribe** — which passes the cached stems to `processor.py` so Demucs,
the slow stage, is skipped — and **Delete**.

`PlayerScreen` now only plays the transcription it is handed; finding, loading
and processing tracks all belong to the library.

## What talks to what

```
PlayerScreen ── Ticker (vsync)
     │            ├─► PlaybackClock.tick()      position for this frame
     │            └─► FretboardViewModel.advance(dt)
     │                    │   active / upcoming notes, scrolling window
     │                    └─► FretboardPainter  (repaint: viewModel)
     │
     ├─ StemPlayer ──► two media_kit Players (bass, backing)
     │                 └─► PlaybackClock.syncTo(reading)
     └─ Transcription ──► NoteTimeline (binary search over notes)
```

`FretboardViewModel` is the painter's `repaint` listenable, so a frame costs one
repaint and no widget rebuild. The text readout listens to `noteChanges`
instead, which only fires when the current or next note actually changes —
roughly ten rebuilds a second rather than sixty.

**The neck does not scroll.** An earlier version slid a 15-fret window to follow
the hand; the fret numbers moved underneath you, so there was no stable picture
to learn. The span is fixed for the whole song instead, wide enough for every
note in it.

**The marker says which finger, the pill says which string.** The number inside
the note marker is the fretting finger (1 index … 4 pinky); the small coloured
pill beside it names the string. The fret is read off the numbers along the
bottom. The pill flips underneath the marker on the top string, where there is
no room above it.

**Strings are colour-coded** (low to high: red, amber, green, blue) and the
string you need is lit along its entire length. Colour is the fastest answer to
"which string?", but never the only one — every string also carries its name,
and the note is drawn on the string itself.

## Verifying the fretboard

`test/fretboard_render_test.dart` paints the fretboard straight to PNG files:

```powershell
$env:BASS_RENDER_OUT="$PWD\.render"; flutter test test/fretboard_render_test.dart
```

It renders the widget in isolation rather than capturing the screen, so it
cannot pick up anything else on the desktop and produces the same image on any
machine.

## Audio / picture calibration

Bluetooth headsets run 100-250 ms behind, which makes the highlight look wrong
when the transcription is fine. The ⚙ button opens a slider (-300..+300 ms), and
**Calibrate with a click** plays a synthesised metronome and flashes on the beat
so the offset can be set by ear.

The offset lives in `PlaybackClock`, but deliberately does *not* move
`position`: transport, seeking and the end-of-track check all read the audio
position, so a +300 ms setting cannot end a song early or send a seek to the
wrong timestamp. Only `displayPosition` is shifted, and only the fretboard reads
it. Tests cover both rules.

The click is synthesised rather than shipped as an asset so its beat times are
exactly known — verified against the rendered WAV at 500.0000 ms spacing with
accents on beats 1 and 5.

Settings persist to `%APPDATA%ass_trainer\settings.json` (or
`$XDG_CONFIG_HOME`), written directly rather than through a plugin.

## A–B practice loop

Mark A and B with the buttons, or drag across the lane under the seek bar. The
loop region is shaded on the bar; the pass count and current ramp step sit with
the controls. With a beat grid loaded, A and B snap to bar lines.

Two details make repeated passes hold their timing:

**The overshoot is carried, not discarded.** A frame is up to ~16 ms, so the
wrap is always slightly past B. Restarting at A exactly would throw that away
every pass and walk the loop out of time with the music; `wrapPosition` adds it
back past A instead.

**Readings from before a seek are ignored.** The engine keeps reporting the old
position for a moment after a jump, and `syncTo` would treat that as a large
error and snap straight back to B. `PlaybackClock` ignores readings until one
lands near the target — bounded to eight, so an engine that genuinely went
elsewhere still wins rather than wedging the clock. `StemPlayer` also pauses
drift correction for 400 ms after a seek, since mid-seek one engine has moved
and the other has not.

## Listening and scoring

The 🎤 button captures the default input, runs YIN pitch detection on it and
colours each note green when you hit it and red when you miss. At the end of a
loop pass it reports the section score. Off by default; nothing is captured
until it is switched on.

**Pitch detection is YIN, not autocorrelation.** Autocorrelation reports an
octave too low on a bass, where the second harmonic often outweighs the
fundamental; YIN's cumulative mean normalisation suppresses that.

The bar for "good enough" came from a reference rather than a guess: over a real
separated bass stem, `librosa.pyin` agrees with the transcription 88% of the
time, and this detector reaches the same figure, disagreeing on the same handful
of very low notes. `test/pitch_on_real_bass_test.dart` asserts it, and skips
when there is no processed track to hand.

Known limit: a tone *above* the search range aliases down to a submultiple
rather than being rejected — any multiple of a true period is also a true
period. Fine for a bass DI or a mic on a cab; do not point it at a whole mix.

**Input latency is handled separately from output latency.** The A/V offset
aligns what you see with what you hear; capture has its own delay on the way in.
The listener reports its own buffer delay and the scorer subtracts it, with a
manual nudge in settings for whatever the driver adds.

## Why the app and a tutorial disagree

They usually both right. A pitch does not have one home on a bass: E2 sits at
string 2 fret 2, string 1 fret 7 or string 0 fret 12. Which one you use is a
preference.

The default optimises for least hand movement and takes open strings when they
are free, which spreads a part across strings. Most teachers keep a riff on one
string instead — even tone, one shape to memorise. On the Seven Nation Army riff
the two differ completely:

| | E2 | E2 | G2 | E2 | D2 | C2 | B1 |
|---|---|---|---|---|---|---|---|
| least movement | D2 | D2 | G0 | D2 | D0 | A3 | A2 |
| one string | A7 | A7 | A10 | A7 | A5 | A3 | A2 |

The second row is what tutorials teach, and the hand icon in the player switches
between them, optionally pinned near a chosen fret. The choice is remembered per
track. A test asserts the one-string style reproduces that exact tab.

## Reference files

The same dialog keeps a tab with the track — PDF, image, Guitar Pro, MIDI. Files
are copied into `data/<track>/reference/` so a track stays self-contained, and
open in the system viewer rather than in-app: rendering a PDF would mean another
native plugin, and the tab is wanted on a second screen anyway.

## Choices

**media_kit, not just_audio.** Two stems play as independent voices so either
can be muted or soloed without re-rendering audio. media_kit (libmpv) handles
multiple simultaneous players and pitch-corrected rate control identically on
desktop and mobile; just_audio's desktop support is federated out to community
packages with uneven rate handling.

**Mute is volume, never pause.** Pausing one engine to silence it would
desynchronise it from the other.

**The backing track leads.** It drives the clock; the bass stem is nudged back
whenever it drifts more than 80 ms, checked twice a second. Two engines playing
one song will drift, and this is a correction rather than a cure — sample-locked
sync would need a single mixer graph.

**No audio still runs.** With no stems the clock free-runs and the fretboard
animates anyway, which is what lets the bundled demo work before the backend has
processed anything.

**Strings are indexed low to high** (0 = E), matching the JSON, and *named* in
the UI ("D string, fret 7") — bassists number the G string as the 1st, which is
the reverse, so numbers would be ambiguous. The neck draws G on top to match
written tab; the toolbar toggles it.

## Files

| Path | |
|---|---|
| `models/instrument.dart` | Tuning, note names, position lookup |
| `models/note_event.dart` | One note |
| `models/transcription.dart` | JSON parsing, stem path resolution |
| `services/fretboard_mapper.dart` | Fingering search — Dart port of `fretboard.py`, used when a JSON has no positions |
| `services/note_timeline.dart` | Binary-search time index |
| `services/playback_clock.dart` | Frame-rate position extrapolation |
| `services/stem_player.dart` | Two-player transport, mix, drift correction |
| `widgets/fretboard_view.dart` | View model + `CustomPainter` |
| `widgets/transport_controls.dart` | Seek, speed, mute/solo |
