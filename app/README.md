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
