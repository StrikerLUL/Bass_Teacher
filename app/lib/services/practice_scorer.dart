import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/note_event.dart';
import 'note_timeline.dart';
import 'pitch_detector.dart';

enum NoteVerdict { pending, hit, missed }

/// Score for one stretch of the track.
class SectionScore {
  const SectionScore({
    required this.hits,
    required this.total,
    required this.from,
    required this.to,
  });

  final int hits;
  final int total;
  final double from;
  final double to;

  double get accuracy => total == 0 ? 0 : hits / total;
  int get percent => (accuracy * 100).round();
  bool get isEmpty => total == 0;
}

/// Judges what was played against what the transcription expects.
///
/// A note counts as hit when a detection of the right pitch lands inside a
/// window around it. Both halves have to be forgiving: a bassist is not a
/// sequencer, and the detector needs a few frames to settle on a pitch after
/// the attack.
class PracticeScorer extends ChangeNotifier {
  PracticeScorer({
    required this.timeline,
    this.timingToleranceSec = 0.18,
    this.centsTolerance = 60,
    this.minClarity = 0.55,
    this.allowOctaveErrors = true,
  });

  final NoteTimeline timeline;

  /// How far from a note's own span a detection may land and still count.
  final double timingToleranceSec;

  /// How far off pitch a detection may be within its semitone.
  final double centsTolerance;

  /// Detections less periodic than this are ignored rather than judged.
  final double minClarity;

  /// Count the right pitch class in the wrong octave as a hit. A separated
  /// stem and a real bass often differ by an octave, and the note being
  /// *learned* is the same either way.
  final bool allowOctaveErrors;

  final Map<NoteEvent, NoteVerdict> _verdicts = {};

  /// Notes already judged, for the section score.
  int _hits = 0;
  int _judged = 0;

  /// The most recent detection, for the tuner-style readout.
  PitchReading? _lastReading;
  PitchReading? get lastReading => _lastReading;

  bool _listening = false;
  bool get listening => _listening;
  set listening(bool value) {
    if (value == _listening) return;
    _listening = value;
    if (!value) _lastReading = null;
    notifyListeners();
  }

  NoteVerdict verdictFor(NoteEvent note) =>
      _verdicts[note] ?? NoteVerdict.pending;

  /// Feed a detection, tagged with the song position it corresponds to.
  ///
  /// [songTime] must already have input latency taken off it — the sound
  /// reaching Dart describes a moment that has passed.
  void offer(PitchReading reading, double songTime) {
    _lastReading = reading;
    if (reading.clarity < minClarity) {
      notifyListeners();
      return;
    }
    if (reading.cents.abs() > centsTolerance) {
      notifyListeners();
      return;
    }

    for (final note in timeline.between(
      songTime - timingToleranceSec - _longestConsidered,
      songTime + timingToleranceSec,
      limit: 12,
    )) {
      if (_verdicts[note] == NoteVerdict.hit) continue;
      if (!_overlaps(note, songTime)) continue;
      if (!_pitchMatches(note, reading)) continue;
      _record(note, NoteVerdict.hit);
      break;
    }
    notifyListeners();
  }

  /// Mark everything that has gone past without being hit.
  void expireBefore(double songTime) {
    var changed = false;
    for (final note in timeline.notes) {
      if (note.end + timingToleranceSec >= songTime) break;
      if (_verdicts.containsKey(note)) continue;
      _record(note, NoteVerdict.missed);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Accuracy over a stretch of the track, for a loop pass.
  SectionScore scoreBetween(double from, double to) {
    var hits = 0;
    var total = 0;
    for (final note in timeline.notes) {
      if (note.start < from) continue;
      if (note.start > to) break;
      total++;
      if (_verdicts[note] == NoteVerdict.hit) hits++;
    }
    return SectionScore(hits: hits, total: total, from: from, to: to);
  }

  /// Forget the verdicts in a stretch, so the next loop pass starts clean.
  void resetBetween(double from, double to) {
    for (final note in timeline.notes) {
      if (note.start < from) continue;
      if (note.start > to) break;
      final previous = _verdicts.remove(note);
      if (previous == NoteVerdict.hit) _hits--;
      if (previous != null) _judged--;
    }
    notifyListeners();
  }

  void resetAll() {
    _verdicts.clear();
    _hits = 0;
    _judged = 0;
    notifyListeners();
  }

  int get hits => _hits;
  int get judged => _judged;

  void _record(NoteEvent note, NoteVerdict verdict) {
    final previous = _verdicts[note];
    if (previous == verdict) return;
    if (previous == NoteVerdict.hit) _hits--;
    if (previous == null) _judged++;
    _verdicts[note] = verdict;
    if (verdict == NoteVerdict.hit) _hits++;
  }

  /// Longest note worth reaching back for when matching a detection.
  static const double _longestConsidered = 2.0;

  bool _overlaps(NoteEvent note, double songTime) =>
      songTime >= note.start - timingToleranceSec &&
      songTime <= note.end + timingToleranceSec;

  bool _pitchMatches(NoteEvent note, PitchReading reading) {
    if (reading.midi == note.midi) return true;
    if (!allowOctaveErrors) return false;
    final gap = (reading.midi - note.midi).abs();
    return gap % 12 == 0 && gap <= 24;
  }

  /// Where a detection heard *now* actually sits in the song.
  ///
  /// Capture is not instantaneous: the frame handed to the detector describes
  /// sound that arrived a buffer ago, so the comparison has to look back by
  /// that much or every note reads as late.
  static double songTimeFor(double clockPosition, double inputLatencySec) =>
      math.max(0, clockPosition - inputLatencySec);
}
