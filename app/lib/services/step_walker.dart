import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/note_event.dart';
import 'note_timeline.dart';

/// Walks a transcription one grip at a time, with the music stopped.
///
/// Playing along teaches timing. It does not teach a shape you cannot play yet:
/// at ten notes a second the fretboard has already moved on by the time you
/// have found the string. This is the other half of the same picture — one note
/// held still for as long as you want to look at it, then the next.
///
/// It owns nothing but an index. The fretboard reads the note out of it each
/// frame instead of off the clock, which is what makes stepping and playing the
/// same view rather than two.
class StepWalker extends ChangeNotifier {
  StepWalker(this.timeline);

  final NoteTimeline timeline;

  bool _active = false;
  int _index = 0;

  bool get isActive => _active && !timeline.isEmpty;
  bool get isEmpty => timeline.isEmpty;

  /// Zero-based position in the part.
  int get index => _index;

  int get length => timeline.length;

  /// 1-based, which is how the panel counts.
  int get step => _index + 1;

  NoteEvent? get note =>
      timeline.isEmpty ? null : timeline.notes[_index.clamp(0, length - 1)];

  bool get hasPrevious => _index > 0;
  bool get hasNext => _index + 1 < length;

  /// The grips after this one, so the next shape can be read before arriving at
  /// it. Counted by index rather than by time: a bar's rest would otherwise
  /// empty the strip exactly where looking ahead matters most.
  List<NoteEvent> lookahead(int count) {
    final from = _index + 1;
    final to = math.min(from + count, length);
    return from >= to ? const [] : timeline.notes.sublist(from, to);
  }

  /// Enter at whatever is playing now, so stepping carries on from the music
  /// rather than from the top of the song.
  void start(double atTime) {
    if (timeline.isEmpty) return;
    _index = indexAt(atTime);
    _active = true;
    notifyListeners();
  }

  void stop() {
    if (!_active) return;
    _active = false;
    notifyListeners();
  }

  /// The note sounding at [t], or the next one to come.
  int indexAt(double t) {
    if (timeline.isEmpty) return 0;
    final after = timeline.firstIndexAfter(t);
    if (after > 0 && timeline.notes[after - 1].end > t) return after - 1;
    return after.clamp(0, length - 1);
  }

  bool next() => jumpTo(_index + 1);

  bool previous() => jumpTo(_index - 1);

  bool jumpTo(int index) {
    if (timeline.isEmpty) return false;
    final target = index.clamp(0, length - 1);
    if (target == _index) return false;
    _index = target;
    notifyListeners();
    return true;
  }

  /// Forward to the next note the fretting hand actually has to move for.
  ///
  /// Stepping note by note through a bar that never leaves one position is
  /// time spent on nothing; the shifts are the part that has to be learned.
  bool nextShift() {
    if (timeline.isEmpty) return false;
    final notes = timeline.notes;
    final here = _handOf(notes[_index]);
    for (var i = _index + 1; i < notes.length; i++) {
      final there = _handOf(notes[i]);
      if (there > 0 && there != here) return jumpTo(i);
    }
    return jumpTo(length - 1);
  }

  /// True when no hand movement is left to skip to.
  bool get hasShiftAhead {
    if (timeline.isEmpty) return false;
    final notes = timeline.notes;
    final here = _handOf(notes[_index]);
    for (var i = _index + 1; i < notes.length; i++) {
      final there = _handOf(notes[i]);
      if (there > 0 && there != here) return true;
    }
    return false;
  }

  /// Where the hand sits for a note: its annotated position, or the fret it
  /// stops if the phrase never established one.
  static int _handOf(NoteEvent note) {
    final hand = note.hand ?? 0;
    return hand > 0 ? hand : (note.fret ?? 0);
  }
}
