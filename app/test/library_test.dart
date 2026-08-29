import 'dart:convert';
import 'dart:io';

import 'package:bass_trainer/services/library.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryEntry summarise(String json, {bool bass = true, bool backing = true}) =>
    Library.summarise(
      Directory('data/some_track'),
      File('data/some_track/transcription.json'),
      jsonDecode(json) as Map<String, dynamic>,
      modified: DateTime(2026, 1, 1),
      hasBass: bass,
      hasBacking: backing,
    );

void main() {
  group('Library.summarise', () {
    test('reads the stats block a processed track carries', () {
      final entry = summarise('''
      {
        "source": {"file": "song.mp3", "duration_sec": 246.79},
        "stats": {"notes": 904, "peak_notes_per_sec": 9, "max_fret_jump": 9},
        "transcription": {"engine": "torchcrepe"},
        "instrument": {"tuning": ["E1","A1","D2","G2"]},
        "notes": []
      }''');

      expect(entry.title, 'song.mp3');
      expect(entry.duration, closeTo(246.79, 0.01));
      expect(entry.noteCount, 904);
      expect(entry.peakNotesPerSec, 9);
      expect(entry.maxFretJump, 9);
      expect(entry.engine, 'torchcrepe');
      expect(entry.tuning, 'E1-A1-D2-G2');
      expect(entry.hasAudio, isTrue);
      expect(entry.canRetranscribe, isTrue);
    });

    test('falls back to counting notes when stats are absent', () {
      final entry = summarise('''
      {
        "source": {"file": "x.wav"},
        "notes": [
          {"start": 0, "end": 1, "midi": 40},
          {"start": 1, "end": 2, "midi": 42}
        ]
      }''');
      expect(entry.noteCount, 2);
      expect(entry.duration, 0);
      expect(entry.engine, isNull);
    });

    test('names the track after its folder when the source is missing', () {
      final entry = summarise('{"notes": []}');
      expect(entry.title, 'some_track');
    });

    test('a track without stems cannot be re-transcribed', () {
      // Re-transcribing reuses the cached stems; without them it would have to
      // run Demucs again, so the action must not be offered.
      final entry = summarise('{"notes": []}', bass: false, backing: false);
      expect(entry.hasAudio, isFalse);
      expect(entry.canRetranscribe, isFalse);
    });

    test('backing alone is still not enough to re-transcribe', () {
      final entry = summarise('{"notes": []}', bass: false, backing: true);
      expect(entry.hasAudio, isTrue);
      expect(entry.canRetranscribe, isFalse);
    });
  });
}
