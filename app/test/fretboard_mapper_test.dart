import 'package:bass_trainer/models/instrument.dart';
import 'package:bass_trainer/models/note_event.dart';
import 'package:bass_trainer/services/fretboard_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The riff `backend/make_sample.py` generates, so the Dart port and the Python
/// implementation can be checked against the same expected fingering.
const List<int> _roots = [40, 38, 36, 35]; // E2 D2 C2 B1
const List<int> _riff = [0, 0, 12, 0, 7, 0, 12, 0, 0, 0, 12, 0, 7, 12, 10, 7];
const double _step = 0.1; // sixteenths at 150 bpm

List<NoteEvent> buildRiff() {
  final notes = <NoteEvent>[];
  var time = 0.0;
  for (final root in _roots) {
    for (final offset in _riff) {
      notes.add(NoteEvent(
        start: time,
        end: time + _step * 0.85,
        midi: root + offset,
      ));
      time += _step;
    }
  }
  return notes;
}

void main() {
  const bass = Instrument.bassStandard;

  group('positionsFor', () {
    test('finds every playable place for a pitch', () {
      // E2 sits on three strings of a 24-fret bass.
      final positions = bass.positionsFor(40);
      expect(
        positions.map((p) => '${p.string}:${p.fret}'),
        ['2:2', '1:7', '0:12'],
      );
    });

    test('respects maxFret', () {
      expect(bass.positionsFor(40, maxFret: 5).length, 1);
    });
  });

  group('assign', () {
    test('keeps a fast octave riff inside one hand position', () {
      final notes = buildRiff();
      FretboardMapper(bass).assign(notes);

      // Matches backend/make_sample.py exactly: the octave leaps cross strings
      // rather than turning into 12-fret slides.
      expect(
        notes.take(6).map((n) => '${n.string}:${n.fret}').toList(),
        ['1:7', '1:7', '3:9', '1:7', '2:9', '1:7'],
      );

      final fretted = notes.where((n) => n.fret! > 0).map((n) => n.fret!).toList();
      var maxJump = 0;
      for (var i = 1; i < fretted.length; i++) {
        final jump = (fretted[i] - fretted[i - 1]).abs();
        if (jump > maxJump) maxJump = jump;
      }
      expect(maxJump, lessThanOrEqualTo(3));
    });

    test('an open string does not reset the hand anchor', () {
      // D3 parks the hand at fret 7. A2 is playable at fret 2 (G string) or
      // fret 7 (D string); with the hand already at 7 the D string is correct,
      // and the open D in between must not talk the search out of it.
      final notes = [
        NoteEvent(start: 0.0, end: 0.08, midi: 50), // D3
        NoteEvent(start: 0.1, end: 0.18, midi: 38), // D2, open D string
        NoteEvent(start: 0.2, end: 0.28, midi: 45), // A2
      ];
      FretboardMapper(bass).assign(notes);

      expect(notes[0].fret, 7);
      expect(notes[1].fret, 0);
      expect(notes[2].string, 2, reason: 'A2 should stay on the D string');
      expect(notes[2].fret, 7, reason: 'the hand never left fret 7');
    });

    test('relocates a phrase when it pays to', () {
      // One high note, then a long phrase that lives low on the neck. A
      // per-note rule would strand the phrase up at fret 21; the Viterbi pass
      // walks the hand down because the accumulated position costs outweigh
      // the single shift. Mirrors test_phrase_relocates_when_it_pays_to.
      final notes = [NoteEvent(start: 0.0, end: 0.5, midi: 64)]; // E4
      var time = 2.0;
      for (var cycle = 0; cycle < 4; cycle++) {
        for (final pitch in [40, 42, 43, 45]) {
          notes.add(NoteEvent(start: time, end: time + 0.09, midi: pitch));
          time += 0.12;
        }
      }
      FretboardMapper(bass).assign(notes);

      expect(notes.first.fret, 21);
      final settled = notes.sublist(notes.length - 8).map((n) => n.fret!);
      expect(settled.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(4));
    });

    test('leaves out-of-range notes unassigned instead of throwing', () {
      final notes = [
        NoteEvent(start: 0.0, end: 0.2, midi: 20), // below open E
        NoteEvent(start: 0.3, end: 0.5, midi: 40),
      ];
      FretboardMapper(bass).assign(notes);
      expect(notes[0].fret, isNull);
      expect(notes[1].fret, isNotNull);
    });

    test('handles an empty list', () {
      expect(() => FretboardMapper(bass).assign([]), returnsNormally);
    });
  });

  group('assignFingers', () {
    NoteEvent fingered(int fret, int hand) {
      final note =
          NoteEvent(start: 0, end: 0.2, midi: 40, string: 1, fret: fret, hand: hand);
      FretboardMapper(bass).assignFingers([note]);
      return note;
    }

    test('the box is one finger per fret', () {
      // Hand at 7: index on 7, middle on 8, ring on 9, pinky on 10.
      expect([7, 8, 9, 10].map((f) => fingered(f, 7).finger), [1, 2, 3, 4]);
    });

    test('a stretch reaches with the pinky', () {
      expect(fingered(11, 7).finger, 4);
    });

    test('a shift lands on the index', () {
      expect(fingered(14, 7).finger, 1);
      expect(fingered(2, 9).finger, 1);
    });

    test('an open string uses no finger', () {
      expect(fingered(0, 7).finger, 0);
    });

    test('an unplayable note gets none', () {
      final note = NoteEvent(start: 0, end: 0.2, midi: 20);
      FretboardMapper(bass).assignFingers([note]);
      expect(note.finger, isNull);
    });

    test('matches the Python backend on the demo riff', () {
      // Same expectations as test_fingers_on_a_real_phrase in
      // backend/test_fretboard.py.
      final notes = buildRiff();
      final mapper = FretboardMapper(bass);
      mapper.assign(notes);
      mapper.annotateHandPositions(notes);
      mapper.assignFingers(notes);

      expect(notes[0].fret, 7);
      expect(notes[0].finger, 1);
      expect(notes[2].fret, 9);
      expect(notes[2].finger, 3);
      for (final note in notes) {
        if (note.fret == 0) {
          expect(note.finger, 0);
        } else {
          expect(note.finger, inInclusiveRange(1, 4));
        }
      }
    });
  });

  group('annotateHandPositions', () {
    test('ignores open strings when placing the hand', () {
      final notes = [
        NoteEvent(start: 0.0, end: 0.1, midi: 47, string: 2, fret: 9),
        NoteEvent(start: 0.1, end: 0.2, midi: 38, string: 2, fret: 0), // ignored
        NoteEvent(start: 0.2, end: 0.3, midi: 45, string: 2, fret: 7),
      ];
      FretboardMapper(bass).annotateHandPositions(notes);
      expect(notes.map((n) => n.hand), everyElement(7));
    });
  });
}
