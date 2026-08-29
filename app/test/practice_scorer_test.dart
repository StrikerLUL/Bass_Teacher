import 'package:bass_trainer/models/note_event.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/pitch_detector.dart';
import 'package:bass_trainer/services/practice_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

PitchReading heard(int midi, {double cents = 0, double clarity = 0.9}) =>
    PitchReading(
      hz: 440 * 1.0, // unused by the scorer
      midi: midi,
      cents: cents,
      clarity: clarity,
      level: 0.2,
    );

/// Four quarter notes: E2 F#2 G2 A2, one per second.
List<NoteEvent> _line() => [
      NoteEvent(start: 1.0, end: 1.8, midi: 40, string: 1, fret: 7),
      NoteEvent(start: 2.0, end: 2.8, midi: 42, string: 1, fret: 9),
      NoteEvent(start: 3.0, end: 3.8, midi: 43, string: 2, fret: 5),
      NoteEvent(start: 4.0, end: 4.8, midi: 45, string: 2, fret: 7),
    ];

void main() {
  late PracticeScorer scorer;
  late List<NoteEvent> notes;

  setUp(() {
    notes = _line();
    scorer = PracticeScorer(timeline: NoteTimeline(notes));
  });

  group('judging', () {
    test('the right note at the right time is a hit', () {
      scorer.offer(heard(40), 1.3);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.hit);
    });

    test('the wrong note leaves it unjudged', () {
      scorer.offer(heard(41), 1.3);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.pending);
    });

    test('the right note at the wrong time does not count', () {
      scorer.offer(heard(40), 3.4); // during G2
      expect(scorer.verdictFor(notes[0]), NoteVerdict.pending);
    });

    test('slightly early or late still counts', () {
      scorer.offer(heard(40), 0.88); // 120ms before the note starts
      expect(scorer.verdictFor(notes[0]), NoteVerdict.hit);

      scorer.offer(heard(42), 2.92); // 120ms after F#2 ends
      expect(scorer.verdictFor(notes[1]), NoteVerdict.hit);
    });

    test('badly out of tune does not count', () {
      scorer.offer(heard(40, cents: 80), 1.3);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.pending);
    });

    test('a weak, unpitched frame is ignored rather than judged', () {
      scorer.offer(heard(40, clarity: 0.2), 1.3);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.pending);
    });

    test('the right pitch class an octave out still counts', () {
      // A bass DI and a separated stem often differ by an octave, and the note
      // being learned is the same either way.
      scorer.offer(heard(52), 1.3);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.hit);
    });

    test('octave tolerance can be turned off', () {
      final strict = PracticeScorer(
        timeline: NoteTimeline(notes),
        allowOctaveErrors: false,
      );
      strict.offer(heard(52), 1.3);
      expect(strict.verdictFor(notes[0]), NoteVerdict.pending);
    });

    test('notes that go by unplayed are marked missed', () {
      scorer.expireBefore(3.5);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.missed);
      expect(scorer.verdictFor(notes[1]), NoteVerdict.missed);
      expect(scorer.verdictFor(notes[2]), NoteVerdict.pending);
    });

    test('a hit is not overwritten by expiry', () {
      scorer.offer(heard(40), 1.3);
      scorer.expireBefore(3.5);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.hit);
    });
  });

  group('input latency', () {
    test('looks back by the capture delay', () {
      // Sound reaching the app describes a moment that has passed; without
      // this every note would read as played late.
      expect(PracticeScorer.songTimeFor(1.4, 0.093), closeTo(1.307, 1e-9));
      expect(PracticeScorer.songTimeFor(0.05, 0.2), 0.0);
    });

    test('a note played in time scores once latency is accounted for', () {
      // The player hits E2 exactly at 1.2s. The frame arrives 93ms later.
      const latency = 0.093;
      final arrivedAt = 1.2 + latency;
      scorer.offer(heard(40), PracticeScorer.songTimeFor(arrivedAt, latency));
      expect(scorer.verdictFor(notes[0]), NoteVerdict.hit);
    });
  });

  group('section score', () {
    test('counts hits over a stretch', () {
      scorer.offer(heard(40), 1.3);
      scorer.offer(heard(43), 3.3);
      final score = scorer.scoreBetween(0.5, 4.5);
      expect(score.total, 4);
      expect(score.hits, 2);
      expect(score.percent, 50);
    });

    test('only counts notes inside the region', () {
      scorer.offer(heard(40), 1.3);
      final score = scorer.scoreBetween(2.5, 4.5);
      expect(score.total, 2);
      expect(score.hits, 0);
    });

    test('resetting a region clears it for the next pass', () {
      scorer.offer(heard(40), 1.3);
      expect(scorer.scoreBetween(0.5, 4.5).hits, 1);
      scorer.resetBetween(0.5, 4.5);
      expect(scorer.scoreBetween(0.5, 4.5).hits, 0);
      expect(scorer.verdictFor(notes[0]), NoteVerdict.pending);
      expect(scorer.hits, 0);
      expect(scorer.judged, 0);
    });

    test('an empty region reports empty rather than dividing by zero', () {
      final score = scorer.scoreBetween(10, 20);
      expect(score.isEmpty, isTrue);
      expect(score.accuracy, 0);
    });
  });
}
