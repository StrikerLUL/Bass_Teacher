import 'dart:math' as math;
import 'dart:typed_data';

/// One pitch estimate from one analysis frame.
class PitchReading {
  const PitchReading({
    required this.hz,
    required this.midi,
    required this.cents,
    required this.clarity,
    required this.level,
  });

  final double hz;

  /// Nearest semitone.
  final int midi;

  /// Signed distance from that semitone, -50..+50.
  final double cents;

  /// 0..1. How periodic the frame was; low means noise or silence.
  final double clarity;

  /// RMS of the frame, 0..1.
  final double level;

  @override
  String toString() =>
      '${hz.toStringAsFixed(1)}Hz midi $midi ${cents >= 0 ? '+' : ''}'
      '${cents.toStringAsFixed(0)}c clarity ${clarity.toStringAsFixed(2)}';
}

/// Monophonic pitch detection by the YIN method.
///
/// Autocorrelation alone is prone to reporting an octave too low on a bass,
/// where the second harmonic often outweighs the fundamental. YIN's cumulative
/// mean normalised difference suppresses that: it divides each candidate period
/// by the running mean of the shorter ones, so a period that is merely a
/// multiple of the true one no longer wins.
///
/// Analysis runs at a low sample rate on purpose. A bass fundamental tops out
/// around 400 Hz, so 11 kHz is ample, and the cost of YIN grows with the
/// longest period it must consider.
///
/// Known limit: a tone *above* [maxHz] is not rejected, it aliases down to a
/// submultiple that falls inside the search range — 1200 Hz reads as 400. The
/// search is bounded to bass frequencies, and any multiple of a true period is
/// also a true period, so nothing in the time domain can tell them apart. It
/// does not matter for a bass DI or a mic in front of a cab; it does mean the
/// detector should not be pointed at a whole mix.
class PitchDetector {
  PitchDetector({
    this.sampleRate = 11025,
    this.threshold = 0.15,
    this.minHz = 38.0,
    this.maxHz = 520.0,
    this.minLevel = 0.008,
  });

  final int sampleRate;

  /// Below this, a candidate period is accepted as the answer. Higher accepts
  /// noisier input at the cost of more octave errors.
  final double threshold;

  final double minHz;
  final double maxHz;

  /// RMS floor. Quieter than this is treated as silence rather than pitch.
  final double minLevel;

  int get _minTau => math.max(2, (sampleRate / maxHz).floor());
  int get _maxTau => math.min(
        (sampleRate / minHz).ceil(),
        1 << 30,
      );

  /// Analyse one frame. Returns null for silence or anything unpitched.
  PitchReading? detect(Float64List frame) {
    final level = _rms(frame);
    if (level < minLevel) return null;

    final maxTau = math.min(_maxTau, frame.length ~/ 2);
    if (maxTau <= _minTau) return null;

    // Difference function, over a window that is the *same length* for every
    // candidate period. Summing over `frame.length - tau` instead would give
    // long periods fewer terms and so a smaller sum, biasing the result
    // downward — measured against librosa.pyin on a real bass stem, that cost
    // about 20 points of accuracy and showed up as octave-down errors.
    final window = frame.length - maxTau;
    if (window < maxTau) return null;

    final diff = Float64List(maxTau + 1);
    for (var tau = 1; tau <= maxTau; tau++) {
      var sum = 0.0;
      for (var i = 0; i < window; i++) {
        final delta = frame[i] - frame[i + tau];
        sum += delta * delta;
      }
      diff[tau] = sum;
    }

    // Cumulative mean normalisation: this is the step that kills the octave
    // errors plain autocorrelation makes on a bass.
    final normalised = Float64List(maxTau + 1);
    normalised[0] = 1.0;
    var running = 0.0;
    for (var tau = 1; tau <= maxTau; tau++) {
      running += diff[tau];
      normalised[tau] = running == 0 ? 1.0 : diff[tau] * tau / running;
    }

    // First dip below the threshold, preferring the shortest period so a
    // harmonic multiple cannot win.
    var best = -1;
    for (var tau = _minTau; tau <= maxTau; tau++) {
      if (normalised[tau] < threshold) {
        while (tau + 1 <= maxTau && normalised[tau + 1] < normalised[tau]) {
          tau++;
        }
        best = tau;
        break;
      }
    }
    if (best < 0) {
      // Nothing convincing: fall back to the global minimum, and let clarity
      // report how weak it was.
      var lowest = double.infinity;
      for (var tau = _minTau; tau <= maxTau; tau++) {
        if (normalised[tau] < lowest) {
          lowest = normalised[tau];
          best = tau;
        }
      }
      if (best < 0 || lowest > 0.6) return null;
    }

    final period = _refine(normalised, best, maxTau);
    if (period <= 0) return null;
    final hz = sampleRate / period;
    if (hz < minHz || hz > maxHz) return null;

    final exact = 69 + 12 * (math.log(hz / 440.0) / math.ln2);
    final midi = exact.round();
    return PitchReading(
      hz: hz,
      midi: midi,
      cents: (exact - midi) * 100,
      clarity: (1.0 - normalised[best]).clamp(0.0, 1.0),
      level: level,
    );
  }

  /// Parabolic interpolation around the chosen dip, for sub-sample precision.
  double _refine(Float64List values, int tau, int maxTau) {
    if (tau <= 0 || tau >= maxTau) return tau.toDouble();
    final before = values[tau - 1];
    final at = values[tau];
    final after = values[tau + 1];
    final divisor = 2 * (2 * at - after - before);
    if (divisor == 0) return tau.toDouble();
    return tau + (after - before) / divisor;
  }

  static double _rms(Float64List frame) {
    if (frame.isEmpty) return 0;
    var sum = 0.0;
    for (final sample in frame) {
      sum += sample * sample;
    }
    return math.sqrt(sum / frame.length);
  }
}
