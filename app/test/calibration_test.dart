import 'dart:io';

import 'package:bass_trainer/models/tempo_grid.dart';
import 'package:bass_trainer/services/app_settings.dart';
import 'package:bass_trainer/services/click_track.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  settingsTests();
  tempoTests();
  group('visual offset', () {
    test('shifts the drawn position but not the audio position', () {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(10);
      clock.visualOffset = 0.12;
      expect(clock.position, 10, reason: 'transport must not move');
      expect(clock.displayPosition, closeTo(10.12, 1e-9));
    });

    test('a negative offset draws the fretboard behind the audio', () {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(10);
      clock.visualOffset = -0.2;
      expect(clock.displayPosition, closeTo(9.8, 1e-9));
    });

    test('is clamped to +/-300 ms', () {
      final clock = PlaybackClock();
      clock.visualOffset = 5.0;
      expect(clock.visualOffset, PlaybackClock.maxVisualOffset);
      clock.visualOffset = -5.0;
      expect(clock.visualOffset, -PlaybackClock.maxVisualOffset);
    });

    test('notifies while paused so the fretboard redraws as you drag', () {
      final clock = PlaybackClock()..duration = 100;
      var notifications = 0;
      clock.addListener(() => notifications++);
      clock.visualOffset = 0.1;
      expect(notifications, greaterThan(0));
    });

    test('setting the same offset twice does not notify', () {
      final clock = PlaybackClock()..visualOffset = 0.1;
      var notifications = 0;
      clock.addListener(() => notifications++);
      clock.visualOffset = 0.1;
      expect(notifications, 0);
    });

    // --- the two rules the offset must not break -------------------------- //

    test('does not break the no-rewind rule during playback', () async {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(5);
      clock.visualOffset = 0.3;
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      clock.tick();

      final audio = clock.position;
      final drawn = clock.displayPosition;
      clock.syncTo(audio - 0.05); // a late reading from the engine
      clock.tick();

      expect(clock.position, greaterThanOrEqualTo(audio));
      expect(clock.displayPosition, greaterThanOrEqualTo(drawn));
    });

    test('changing the offset mid-playback never rewinds the audio', () async {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(20);
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      clock.tick();
      final before = clock.position;

      clock.visualOffset = -PlaybackClock.maxVisualOffset;
      clock.tick();
      expect(clock.position, greaterThanOrEqualTo(before),
          reason: 'calibration must not move the transport backwards');
    });

    test('does not break the end-of-track rule', () {
      // The player pauses on position >= duration. A positive offset must not
      // trip that early, and a negative one must not stop it firing.
      final clock = PlaybackClock()..duration = 30;
      clock.visualOffset = PlaybackClock.maxVisualOffset;
      clock.seekTo(30);
      expect(clock.position, 30, reason: 'audio position still reaches the end');
      expect(clock.displayPosition, greaterThan(30));

      clock.visualOffset = -PlaybackClock.maxVisualOffset;
      expect(clock.position, 30);
    });

    test('seeking is unaffected by the offset', () {
      final clock = PlaybackClock()..duration = 60;
      clock.visualOffset = 0.25;
      clock.seekTo(42);
      expect(clock.position, 42, reason: 'a seek must land where asked');
    });

    test('the audio position still clamps to the track length', () {
      final clock = PlaybackClock()..duration = 12;
      clock.visualOffset = 0.3;
      clock.seekTo(99);
      expect(clock.position, 12);
    });
  });

  group('ClickTrack', () {
    test('beat spacing follows the tempo', () {
      const track = ClickTrack(bpm: 120, beats: 8);
      expect(track.beatSeconds, closeTo(0.5, 1e-9));
      expect(track.duration, closeTo(4.0, 1e-9));
      expect(track.isAccent(0), isTrue);
      expect(track.isAccent(1), isFalse);
      expect(track.isAccent(4), isTrue);
    });

    test('writes a playable WAV of the right length', () async {
      const track = ClickTrack(bpm: 120, beats: 8);
      final dir = await Directory.systemTemp.createTemp('bass_click_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final file = await track.write(directory: dir);
      expect(file.existsSync(), isTrue);

      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

      // 4s, mono, 16-bit at 44.1k, plus the 44-byte header.
      const expected = 44 + 4 * 44100 * 2;
      expect(bytes.length, expected);

      // Silence would mean the click never got rendered.
      final loud = bytes.sublist(44).any((b) => b > 16 && b < 240);
      expect(loud, isTrue, reason: 'the click track is silent');

      // Keep a copy so the beat placement can be checked against the audio.
      final out = Platform.environment['BASS_RENDER_OUT'];
      if (out != null) {
        Directory(out).createSync(recursive: true);
        File('$out/click_120bpm.wav').writeAsBytesSync(bytes);
      }
    });
  });
}

void settingsTests() {
  group('AppSettings', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bass_settings_test');
      AppSettings.overrideFile = File('${dir.path}/settings.json');
      AppSettings.instance.resetForTest();
    });

    tearDown(() {
      AppSettings.overrideFile = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('survives a restart', () async {
      await AppSettings.instance.setVisualOffset(-0.145);
      await AppSettings.instance.setLowStringOnTop(true);

      AppSettings.instance.resetForTest();
      expect(AppSettings.instance.visualOffset, 0.0);

      await AppSettings.instance.load();
      expect(AppSettings.instance.visualOffset, closeTo(-0.145, 1e-6));
      expect(AppSettings.instance.lowStringOnTop, isTrue);
    });

    test('starts from defaults when nothing has been saved', () async {
      await AppSettings.instance.load();
      expect(AppSettings.instance.visualOffset, 0.0);
      expect(AppSettings.instance.lowStringOnTop, isFalse);
    });

    test('a corrupt file does not stop the app starting', () async {
      AppSettings.overrideFile!.parent.createSync(recursive: true);
      AppSettings.overrideFile!.writeAsStringSync('{ this is not json');
      await AppSettings.instance.load();
      expect(AppSettings.instance.visualOffset, 0.0);
      expect(AppSettings.instance.isLoaded, isTrue);
    });
  });
}

void tempoTests() {
  group('TempoGrid', () {
    TempoGrid grid({double bpm = 120, double duration = 8, double first = 0}) =>
        TempoGrid.uniform(bpm: bpm, duration: duration, firstBeat: first);

    test('uniform spacing matches the tempo', () {
      final g = grid(bpm: 120, duration: 4);
      expect(g.beats.take(5), [0.0, 0.5, 1.0, 1.5, 2.0]);
      expect(g.beats.length, 9);
      expect(g.manual, isTrue);
    });

    test('bars and beats count from one', () {
      final g = grid();
      expect(g.barAndBeatAt(0.0), (bar: 1, beat: 1));
      expect(g.barAndBeatAt(0.5), (bar: 1, beat: 2));
      expect(g.barAndBeatAt(2.0), (bar: 2, beat: 1));
      expect(g.barAndBeatAt(4.0), (bar: 3, beat: 1));
    });

    test('before the first beat there is no bar', () {
      final g = TempoGrid(bpm: 120, beats: const [1.0, 1.5, 2.0]);
      expect(g.barAndBeatAt(0.4), (bar: 0, beat: 0));
    });

    test('snapping takes the nearest bar line', () {
      final g = grid(); // bars at 0, 2, 4, 6, 8
      expect(g.snapToBar(2.1), 2.0);
      expect(g.snapToBar(3.4), 4.0);
      expect(g.snapToBar(2.9), 2.0);
      expect(g.snapToBar(99), 8.0);
    });

    test('snapping is a no-op without a grid', () {
      final empty = TempoGrid(bpm: 0, beats: const []);
      expect(empty.isEmpty, isTrue);
      expect(empty.snapToBar(12.3), 12.3);
      expect(empty.barAndBeatAt(12.3), (bar: 0, beat: 0));
    });

    test('a downbeat given mid-song still covers the track', () {
      final g = grid(bpm: 120, duration: 4, first: 2.25);
      expect(g.beats.first, closeTo(0.25, 1e-9));
    });

    test('metre other than four works', () {
      final g = TempoGrid.uniform(
          bpm: 120, duration: 8, firstBeat: 0, beatsPerBar: 3);
      expect(g.barStarts.take(4), [0.0, 1.5, 3.0, 4.5]);
    });

    test('parses the backend document, locating the downbeat', () {
      final g = TempoGrid.fromJson(
        {
          'bpm': 172.3,
          'beats_per_bar': 4,
          'first_downbeat_sec': 1.05,
          'confidence': 0.54,
          'manual': false,
        },
        [0.0, 0.35, 0.7, 1.05, 1.4, 1.75, 2.1, 2.45],
      );
      expect(g, isNotNull);
      expect(g!.bpm, closeTo(172.3, 1e-9));
      expect(g.downbeatIndex, 3, reason: 'downbeat is the fourth beat');
      expect(g.firstDownbeat, closeTo(1.05, 1e-9));
      expect(g.barAndBeatAt(1.05), (bar: 1, beat: 1));
      expect(g.quality, 'usable');
    });

    test('a missing or zero tempo yields no grid', () {
      expect(TempoGrid.fromJson(null, null), isNull);
      expect(TempoGrid.fromJson({'bpm': 0}, const []), isNull);
    });

    test('confidence wording flags a weak estimate', () {
      expect(TempoGrid(bpm: 120, beats: const [0], confidence: 0.9).quality,
          'strong');
      expect(
          TempoGrid(bpm: 120, beats: const [0], confidence: 0.3).quality,
          contains('check it'));
      expect(
          TempoGrid(bpm: 120, beats: const [0], confidence: 0.1).quality,
          contains('by hand'));
    });
  });
}
