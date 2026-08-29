import 'package:bass_trainer/models/note_event.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/services/stem_player.dart';
import 'package:flutter_test/flutter_test.dart';

List<NoteEvent> _notes() => [
      NoteEvent(start: 0.0, end: 0.5, midi: 40),
      NoteEvent(start: 0.5, end: 1.0, midi: 42),
      NoteEvent(start: 1.0, end: 3.0, midi: 43), // long, still ringing later
      NoteEvent(start: 2.0, end: 2.2, midi: 45), // overlaps the long one
      NoteEvent(start: 4.0, end: 4.5, midi: 47),
    ];

void main() {
  mixerTests();
  group('NoteTimeline', () {
    final timeline = NoteTimeline(_notes());

    test('finds the note sounding at a moment', () {
      expect(timeline.activeAt(0.1).single.midi, 40);
      expect(timeline.activeAt(0.7).single.midi, 42);
    });

    test('finds every overlapping note, in start order', () {
      expect(timeline.activeAt(2.1).map((n) => n.midi), [43, 45]);
    });

    test('a note is inclusive at its start and exclusive at its end', () {
      expect(timeline.activeAt(0.5).single.midi, 42);
    });

    test('returns nothing in a rest', () {
      expect(timeline.activeAt(3.5), isEmpty);
    });

    test('nextAfter skips notes already started', () {
      expect(timeline.nextAfter(0.1)!.midi, 42);
      expect(timeline.nextAfter(3.5)!.midi, 47);
      expect(timeline.nextAfter(9.0), isNull);
    });

    test('between is exclusive at the start and inclusive at the end', () {
      expect(timeline.between(0.0, 1.0).map((n) => n.midi), [42, 43]);
    });

    test('between honours its limit', () {
      expect(timeline.between(-1.0, 10.0, limit: 2).length, 2);
    });

    test('an empty timeline does not throw', () {
      final empty = NoteTimeline([]);
      expect(empty.activeAt(1.0), isEmpty);
      expect(empty.nextAfter(1.0), isNull);
    });
  });

  group('PlaybackClock', () {
    test('starts stopped at zero', () {
      final clock = PlaybackClock();
      expect(clock.position, 0);
      expect(clock.isPlaying, isFalse);
    });

    test('does not advance while paused', () async {
      final clock = PlaybackClock()..duration = 10;
      clock.seekTo(3);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      clock.tick();
      expect(clock.position, 3);
    });

    test('extrapolates between engine readings', () async {
      final clock = PlaybackClock()..duration = 10;
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      clock.tick();
      // No reading has arrived; the clock must have moved on its own.
      expect(clock.position, greaterThan(0.05));
      expect(clock.position, lessThan(0.4));
    });

    test('scales extrapolation by the playback rate', () async {
      final clock = PlaybackClock()..duration = 10;
      clock.setRate(0.5);
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      clock.tick();
      expect(clock.position, lessThan(0.2)); // half of ~0.2s of wall time
    });

    test('absorbs a small reading error without jumping', () {
      final clock = PlaybackClock()..duration = 10;
      clock.seekTo(5);
      clock.syncTo(5.02);
      clock.tick();
      expect(clock.position, closeTo(5.0, 0.01)); // nudged, not snapped
    });

    test('snaps on a large reading error', () {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(5);
      clock.syncTo(42.0); // the engine seeked out from under us
      clock.tick();
      expect(clock.position, closeTo(42.0, 0.01));
    });

    test('never rewinds during playback', () async {
      final clock = PlaybackClock()..duration = 10;
      clock.seekTo(5);
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      clock.tick();
      final advanced = clock.position;
      clock.syncTo(advanced - 0.05); // a late reading from the engine
      clock.tick();
      expect(clock.position, greaterThanOrEqualTo(advanced));
    });

    test('an explicit seek may go backwards', () {
      final clock = PlaybackClock()..duration = 10;
      clock.seekTo(5);
      clock.setPlaying(true);
      clock.seekTo(1);
      expect(clock.position, 1);
    });

    test('clamps to the track length', () {
      final clock = PlaybackClock()..duration = 4;
      clock.seekTo(99);
      expect(clock.position, 4);
    });

    test('rate changes bank the time already elapsed', () async {
      final clock = PlaybackClock()..duration = 10;
      clock.seekTo(2);
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      clock.setRate(0.5);
      clock.tick();
      // Changing rate must not retroactively rescale the first 100ms.
      expect(clock.position, greaterThanOrEqualTo(2.0));
      expect(clock.position, lessThan(2.3));
    });
  });
}

void mixerTests() {
  group('StemPlayer mix', () {
    test('plays both stems by default', () {
      final m = StemPlayer.mixLevels(soloBass: false, bassMuted: false);
      expect(m.bass, 1.0);
      expect(m.backing, 1.0);
    });

    test('muting the bass leaves the backing audible', () {
      final m = StemPlayer.mixLevels(soloBass: false, bassMuted: true);
      expect(m.bass, 0.0);
      expect(m.backing, 1.0);
    });

    test('soloing the bass silences the backing', () {
      final m = StemPlayer.mixLevels(soloBass: true, bassMuted: false);
      expect(m.bass, 1.0);
      expect(m.backing, 0.0);
    });

    test('solo overrides mute instead of silencing everything', () {
      // The regression: mute the bass, then hit solo, and both stems were
      // muted at once — the player went silent with no obvious way back.
      final m = StemPlayer.mixLevels(soloBass: true, bassMuted: true);
      expect(m.bass, 1.0, reason: 'solo must un-mute the bass');
      expect(m.backing, 0.0);
      expect(m.bass + m.backing, greaterThan(0.0),
          reason: 'no combination of toggles may produce total silence');
    });

    test('no toggle combination is ever fully silent', () {
      for (final solo in [true, false]) {
        for (final muted in [true, false]) {
          final m = StemPlayer.mixLevels(soloBass: solo, bassMuted: muted);
          if (solo || !muted) {
            expect(m.bass + m.backing, greaterThan(0.0),
                reason: 'solo=$solo muted=$muted produced silence');
          }
        }
      }
    });
  });
}
