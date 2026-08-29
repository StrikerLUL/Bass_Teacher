import 'package:bass_trainer/models/tempo_grid.dart';
import 'package:bass_trainer/services/loop_controller.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SpeedRamp', () {
    test('walks from start to finish in the given number of steps', () {
      const ramp = SpeedRamp(enabled: true, from: 0.6, to: 1.0, steps: 5);
      expect(
        [0, 1, 2, 3, 4].map((p) => (ramp.rateForPass(p) * 100).round()),
        [60, 70, 80, 90, 100],
      );
    });

    test('holds at the top rather than overshooting', () {
      const ramp = SpeedRamp(enabled: true, from: 0.6, to: 1.0, steps: 5);
      expect(ramp.rateForPass(9), 1.0);
      expect(ramp.rateForPass(99), 1.0);
    });

    test('a single step is just the finish rate', () {
      const ramp = SpeedRamp(enabled: true, from: 0.5, to: 0.9, steps: 1);
      expect(ramp.rateForPass(0), 0.9);
    });
  });

  group('LoopController', () {
    test('needs both ends before it is set', () {
      final loop = LoopController();
      expect(loop.isSet, isFalse);
      loop.markStart(4.0);
      expect(loop.isSet, isFalse);
      loop.markEnd(8.0);
      expect(loop.isSet, isTrue);
      expect(loop.length, 4.0);
    });

    test('a drag right-to-left still produces an ordered region', () {
      final loop = LoopController()..setRegion(9.0, 3.0);
      expect(loop.start, 3.0);
      expect(loop.end, 9.0);
    });

    test('refuses a region too short to practise', () {
      final loop = LoopController()..setRegion(4.0, 4.1);
      expect(loop.isSet, isFalse);
    });

    test('marking A past B drops B instead of inverting', () {
      final loop = LoopController()
        ..setRegion(2.0, 6.0)
        ..markStart(9.0);
      expect(loop.start, 9.0);
      expect(loop.end, isNull);
      expect(loop.isSet, isFalse);
    });

    test('snaps to bar lines when a grid is supplied', () {
      final grid = TempoGrid.uniform(bpm: 120, duration: 30); // bars every 2s
      final loop = LoopController()
        ..markStart(2.3, grid: grid)
        ..markEnd(7.6, grid: grid);
      expect(loop.start, 2.0);
      expect(loop.end, 8.0);
    });

    test('counts passes and steps the ramp', () {
      final loop = LoopController()
        ..setRegion(0, 4)
        ..ramp = const SpeedRamp(enabled: true, from: 0.6, to: 1.0, steps: 5);
      expect(loop.currentRate, closeTo(0.6, 1e-9));
      expect(loop.completePass(), closeTo(0.7, 1e-9));
      expect(loop.passes, 1);
      loop.completePass();
      loop.completePass();
      expect(loop.completePass(), closeTo(1.0, 1e-9));
      expect(loop.rampComplete, isTrue);
    });

    test('reset takes the ramp back to the slowest step', () {
      final loop = LoopController()
        ..setRegion(0, 4)
        ..ramp = const SpeedRamp(enabled: true, from: 0.6, to: 1.0, steps: 5);
      loop.completePass();
      loop.completePass();
      loop.resetRamp();
      expect(loop.passes, 0);
      expect(loop.currentRate, closeTo(0.6, 1e-9));
    });

    test('rate stays at 1 while the ramp is off', () {
      final loop = LoopController()..setRegion(0, 4);
      loop.completePass();
      expect(loop.currentRate, 1.0);
    });

    // --- the drift requirement ------------------------------------------- //

    test('carries the overshoot past B over to past A', () {
      // A frame is up to ~16ms. Discarding that every pass would walk the loop
      // steadily out of time with the music.
      final loop = LoopController()..setRegion(10.0, 14.0);
      expect(loop.wrapPosition(14.012), closeTo(10.012, 1e-9));
      expect(loop.wrapPosition(14.0), closeTo(10.0, 1e-9));
    });

    test('a huge overshoot restarts cleanly at A', () {
      final loop = LoopController()..setRegion(10.0, 14.0);
      expect(loop.wrapPosition(30.0), 10.0);
    });

    test('repeated passes do not accumulate drift', () {
      final loop = LoopController()..setRegion(0.0, 2.0);
      const frame = 1 / 60;
      const frames = 1230; // 20.5s: deliberately not on a loop boundary, where
                           // float accumulation makes the wrap count a coin flip
      var position = 0.0;
      var wraps = 0;
      for (var i = 0; i < frames; i++) {
        position += frame;
        if (loop.shouldWrap(position)) {
          position = loop.wrapPosition(position);
          wraps++;
        }
      }
      // 20.5s through a 2s loop is 10 passes, and the phase must still line up
      // with where free-running time would have been.
      expect(wraps, 10);
      expect(position, closeTo((frames * frame) % 2.0, 1e-6));
    });

    test('does not wrap while disarmed', () {
      final loop = LoopController()..setRegion(0.0, 2.0);
      loop.enabled = false;
      expect(loop.shouldWrap(5.0), isFalse);
    });
  });

  group('PlaybackClock seek settling', () {
    test('ignores readings from before a seek', () {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(10);
      expect(clock.isSeeking, isTrue);

      // The engine is still reporting the old position near B.
      clock.syncTo(38.0);
      clock.tick();
      expect(clock.position, closeTo(10, 0.01),
          reason: 'a stale reading must not drag playback back to B');

      // Once it reports near the target, syncing resumes.
      clock.syncTo(10.02);
      expect(clock.isSeeking, isFalse);
    });

    test('a loop jump backwards is allowed despite the no-rewind rule', () async {
      final clock = PlaybackClock()..duration = 100;
      clock.seekTo(14);
      clock.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      clock.tick();
      expect(clock.position, greaterThan(14));

      clock.seekTo(10); // the loop wrap
      clock.tick();
      expect(clock.position, lessThan(11),
          reason: 'seeking must override the no-rewind guard');
    });
  });
}
