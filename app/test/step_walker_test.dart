import 'package:bass_trainer/models/instrument.dart';
import 'package:bass_trainer/models/note_event.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/services/step_walker.dart';
import 'package:bass_trainer/widgets/fretboard_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// Four notes a second apart, at frets 5, 5, 7 and 12 — one hand position, then
/// a shift up the neck.
List<NoteEvent> _part() => [
      NoteEvent(start: 0.0, end: 0.8, midi: 33, string: 0, fret: 5, hand: 5, finger: 1),
      NoteEvent(start: 1.0, end: 1.8, midi: 33, string: 0, fret: 5, hand: 5, finger: 1),
      NoteEvent(start: 2.0, end: 2.8, midi: 35, string: 0, fret: 7, hand: 5, finger: 3),
      NoteEvent(start: 3.0, end: 3.8, midi: 40, string: 0, fret: 12, hand: 12, finger: 1),
    ];

StepWalker _walker() => StepWalker(NoteTimeline(_part()));

void main() {
  group('StepWalker', () {
    test('is inert until it is started', () {
      final walker = _walker();
      expect(walker.isActive, isFalse);
      walker.start(0);
      expect(walker.isActive, isTrue);
      walker.stop();
      expect(walker.isActive, isFalse);
    });

    test('enters at the note that is playing, not at the top of the song', () {
      final walker = _walker()..start(2.4);
      expect(walker.index, 2);
      expect(walker.step, 3);
    });

    test('enters at the next note when it starts in a gap', () {
      final walker = _walker()..start(1.9);
      expect(walker.index, 2);
    });

    test('walks forwards and back, and stops at both ends', () {
      final walker = _walker()..start(0);
      expect(walker.hasPrevious, isFalse);
      expect(walker.previous(), isFalse, reason: 'nothing before the first note');

      expect(walker.next(), isTrue);
      expect(walker.next(), isTrue);
      expect(walker.next(), isTrue);
      expect(walker.hasNext, isFalse);
      expect(walker.next(), isFalse, reason: 'nothing after the last note');
      expect(walker.step, 4);
    });

    test('looks ahead by position, so a rest cannot empty the strip', () {
      // The gap to the next note is a whole second — far past any lookahead
      // measured in time, and exactly when you most want to see what is coming.
      final walker = _walker()..start(0);
      expect(walker.lookahead(4).map((n) => n.fret), [5, 7, 12]);
      walker.jumpTo(3);
      expect(walker.lookahead(4), isEmpty);
    });

    test('skips to where the hand actually moves', () {
      final walker = _walker()..start(0);
      expect(walker.hasShiftAhead, isTrue);
      expect(walker.nextShift(), isTrue);
      // Notes 2 and 3 are both played with the hand at fret 5; the shift is the
      // move to fret 12, and stepping one at a time through the rest is time
      // spent on nothing.
      expect(walker.index, 3);
      expect(walker.note!.fret, 12);
      expect(walker.hasShiftAhead, isFalse);
    });

    test('an empty transcription is never active', () {
      final walker = StepWalker(NoteTimeline(const []));
      expect(walker.isEmpty, isTrue);
      walker.start(0);
      expect(walker.isActive, isFalse);
      expect(walker.note, isNull);
      expect(walker.next(), isFalse);
    });

    test('notifies only when it actually moves', () {
      final walker = _walker()..start(0);
      var moves = 0;
      walker.addListener(() => moves++);
      walker.jumpTo(0);
      expect(moves, 0, reason: 'jumping where it already stands is not a move');
      walker.jumpTo(2);
      walker.jumpTo(99); // clamped to the last note
      expect(moves, 2);
      expect(walker.index, 3);
    });
  });

  group('FretboardViewModel with a walker', () {
    late PlaybackClock clock;
    late FretboardViewModel vm;
    late StepWalker walker;

    setUp(() {
      final timeline = NoteTimeline(_part());
      clock = PlaybackClock()..duration = 5;
      walker = StepWalker(timeline);
      vm = FretboardViewModel(
        timeline: timeline,
        instrument: Instrument.bassStandard,
        clock: clock,
      )..walker = walker;
    });

    tearDown(() {
      vm.dispose();
      clock.dispose();
      walker.dispose();
    });

    test('follows the clock while the walker is idle', () {
      clock.seekTo(2.2);
      vm.advance(0);
      expect(vm.stepping, isFalse);
      expect(vm.current?.fret, 7);
    });

    test('shows the grip the walker stands on, whatever the clock says', () {
      clock.seekTo(2.2);
      walker.start(0);
      vm.advance(0);

      expect(vm.stepping, isTrue);
      expect(vm.current?.fret, 5, reason: 'the walker wins, not the clock');
      expect(vm.time, 0.0);
      expect(vm.upcoming.map((n) => n.fret), [5, 7, 12]);
    });

    test('the hand box follows the walker', () {
      walker.start(0);
      vm.advance(0);
      expect(vm.handFret, 5);
      walker.jumpTo(3);
      vm.advance(0);
      expect(vm.handFret, 12);
    });

    test('hands the view back to the clock when stepping ends', () {
      clock.seekTo(3.2);
      walker.start(0);
      vm.advance(0);
      expect(vm.current?.fret, 5);

      walker.stop();
      vm.advance(0);
      expect(vm.stepping, isFalse);
      expect(vm.current?.fret, 12);
    });
  });
}
