import 'dart:math' as math;

/// A beat grid with the confidence of the estimate behind it.
///
/// Mirrors `backend/tempo.py` — same bar/beat numbering and snapping, so the
/// app agrees with the JSON whether the grid came from detection or was set by
/// hand here.
class TempoGrid {
  TempoGrid({
    required this.bpm,
    required this.beats,
    this.beatsPerBar = 4,
    this.downbeatIndex = 0,
    this.confidence = 0.0,
    this.manual = false,
  });

  final double bpm;

  /// Absolute times, ascending.
  final List<double> beats;

  final int beatsPerBar;
  final int downbeatIndex;

  /// 0..1. Below about 0.5 the tempo is worth checking by ear.
  final double confidence;

  final bool manual;

  bool get isEmpty => beats.isEmpty || bpm <= 0;

  double get firstDownbeat =>
      beats.isEmpty ? 0 : beats[downbeatIndex % beats.length];

  double get beatSeconds => bpm > 0 ? 60.0 / bpm : 0;

  String get quality {
    if (manual) return 'set by hand';
    if (confidence >= 0.75) return 'strong';
    if (confidence >= 0.5) return 'usable';
    if (confidence >= 0.25) return 'weak — check it by ear';
    return 'unreliable — set the bpm by hand';
  }

  /// Times of every bar line.
  List<double> get barStarts => [
        for (var i = downbeatIndex; i < beats.length; i += beatsPerBar) beats[i]
      ];

  /// Index of the last beat at or before [t], or -1.
  int beatIndexAt(double t) {
    if (beats.isEmpty || t < beats.first) return -1;
    var low = 0;
    var high = beats.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (beats[mid] <= t) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  /// 1-based bar and beat at [t]; `(0, 0)` before the first downbeat.
  ({int bar, int beat}) barAndBeatAt(double t) {
    final index = beatIndexAt(t);
    if (index < 0) return (bar: 0, beat: 0);
    final offset = index - downbeatIndex;
    if (offset < 0) return (bar: 0, beat: 0);
    return (
      bar: offset ~/ beatsPerBar + 1,
      beat: offset % beatsPerBar + 1,
    );
  }

  /// Nearest bar line to [t], or [t] unchanged when there is no grid.
  double snapToBar(double t) {
    final starts = barStarts;
    if (starts.isEmpty) return t;
    var best = starts.first;
    var bestDistance = (starts.first - t).abs();
    // Bars are sorted, so walk from the binary-search neighbourhood.
    var low = 0;
    var high = starts.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (starts[mid] < t) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (final i in [low - 1, low]) {
      if (i < 0 || i >= starts.length) continue;
      final distance = (starts[i] - t).abs();
      if (distance < bestDistance) {
        best = starts[i];
        bestDistance = distance;
      }
    }
    return best;
  }

  /// Beats falling in `[from, to]`, for drawing a window of the ruler.
  List<double> beatsBetween(double from, double to) =>
      [for (final b in beats) if (b >= from && b <= to) b];

  /// A perfectly even grid, for a tempo typed in by hand.
  factory TempoGrid.uniform({
    required double bpm,
    required double duration,
    double firstBeat = 0.0,
    int beatsPerBar = 4,
  }) {
    if (bpm <= 0 || duration <= 0) {
      return TempoGrid(bpm: bpm, beats: const [], manual: true);
    }
    final interval = 60.0 / bpm;
    // Walk back so a downbeat given mid-song still covers the whole track.
    final start = firstBeat - (firstBeat / interval).floor() * interval;
    final count = math.max(0, ((duration - start) / interval).floor() + 1);
    return TempoGrid(
      bpm: bpm,
      beats: [for (var i = 0; i < count; i++) start + i * interval],
      beatsPerBar: beatsPerBar,
      confidence: 1.0,
      manual: true,
    );
  }

  static TempoGrid? fromJson(
    Map<String, dynamic>? tempo,
    List<dynamic>? beatTimes,
  ) {
    if (tempo == null) return null;
    final bpm = (tempo['bpm'] as num?)?.toDouble() ?? 0;
    if (bpm <= 0) return null;

    final beats = (beatTimes ?? const [])
        .whereType<num>()
        .map((n) => n.toDouble())
        .toList();
    final beatsPerBar = (tempo['beats_per_bar'] as num?)?.toInt() ?? 4;

    // The backend stores the first downbeat as a time; find which beat it is.
    var downbeat = 0;
    final firstDownbeat = (tempo['first_downbeat_sec'] as num?)?.toDouble();
    if (firstDownbeat != null && beats.isNotEmpty) {
      var bestDistance = double.infinity;
      for (var i = 0; i < math.min(beats.length, beatsPerBar * 2); i++) {
        final distance = (beats[i] - firstDownbeat).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          downbeat = i;
        }
      }
    }

    return TempoGrid(
      bpm: bpm,
      beats: beats,
      beatsPerBar: beatsPerBar,
      downbeatIndex: downbeat,
      confidence: (tempo['confidence'] as num?)?.toDouble() ?? 0,
      manual: tempo['manual'] as bool? ?? false,
    );
  }
}
