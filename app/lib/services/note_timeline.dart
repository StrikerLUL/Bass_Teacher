import 'dart:math' as math;

import '../models/note_event.dart';

/// Time-indexed view over a transcription.
///
/// Every lookup is a binary search rather than a running cursor, so seeking and
/// scrubbing cost the same as ordinary playback — no state to invalidate.
class NoteTimeline {
  NoteTimeline(this.notes)
      : _longestNote = notes.fold<double>(
          0.0,
          (longest, note) => math.max(longest, note.duration),
        );

  /// Sorted by [NoteEvent.start].
  final List<NoteEvent> notes;

  /// Bounds how far back [activeAt] has to look for a note still ringing.
  final double _longestNote;

  bool get isEmpty => notes.isEmpty;

  int get length => notes.length;

  /// Index of the first note that starts strictly after [t].
  int firstIndexAfter(double t) {
    var low = 0;
    var high = notes.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (notes[mid].start <= t) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// Notes sounding at [t], in start order. Usually one — bass lines are
  /// collapsed to a single voice by the backend.
  List<NoteEvent> activeAt(double t) {
    final found = <NoteEvent>[];
    final earliest = t - _longestNote;
    for (var i = firstIndexAfter(t) - 1; i >= 0; i--) {
      final note = notes[i];
      if (note.start < earliest) break;
      if (note.end > t) found.add(note);
    }
    return found.reversed.toList(growable: false);
  }

  /// The next note to prepare for, or null at the end of the track.
  NoteEvent? nextAfter(double t) {
    final index = firstIndexAfter(t);
    return index < notes.length ? notes[index] : null;
  }

  /// Notes starting in `(from, to]`, capped at [limit] entries.
  List<NoteEvent> between(double from, double to, {int limit = 16}) {
    final found = <NoteEvent>[];
    for (var i = firstIndexAfter(from); i < notes.length; i++) {
      if (notes[i].start > to || found.length >= limit) break;
      found.add(notes[i]);
    }
    return found;
  }
}
