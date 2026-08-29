
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bass_trainer/services/pitch_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const int rate = 11025;

/// A plucked-bass-ish tone: fundamental plus decaying harmonics. A pure sine
/// is not a fair test — the octave errors this detector exists to avoid only
/// appear when harmonics are present.
Float64List tone(double hz, {int samples = 1024, double harmonicGain = 0.6}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    final t = i / rate;
    var value = math.sin(2 * math.pi * hz * t);
    for (var h = 2; h <= 6; h++) {
      value += math.pow(harmonicGain, h - 1) * math.sin(2 * math.pi * hz * h * t);
    }
    out[i] = value * 0.2;
  }
  return out;
}

double hzFor(int midi) => 440.0 * math.pow(2, (midi - 69) / 12).toDouble();

void main() {
  final detector = PitchDetector(sampleRate: rate);

  group('PitchDetector', () {
    test('finds every note on a four-string bass', () {
      // E1 (28) to G4 (67): the full range of a 24-fret bass.
      for (var midi = 28; midi <= 67; midi++) {
        final reading = detector.detect(tone(hzFor(midi), samples: 2048));
        expect(reading, isNotNull, reason: 'no pitch for midi $midi');
        expect(reading!.midi, midi,
            reason: 'midi $midi read as ${reading.midi} '
                '(${reading.hz.toStringAsFixed(1)} Hz)');
      }
    });

    test('does not fall an octave on a harmonic-rich low note', () {
      // The classic failure: E1's second harmonic is strong, and plain
      // autocorrelation reports E2.
      final reading = detector.detect(
          tone(hzFor(28), samples: 2048, harmonicGain: 0.95));
      expect(reading!.midi, 28);
    });

    test('reports how far off pitch a note is', () {
      final sharp = detector.detect(tone(hzFor(40) * 1.0145, samples: 2048));
      expect(sharp!.midi, 40);
      expect(sharp.cents, closeTo(25, 8));

      final flat = detector.detect(tone(hzFor(40) * 0.9857, samples: 2048));
      expect(flat!.midi, 40);
      expect(flat.cents, closeTo(-25, 8));
    });

    test('returns nothing for silence', () {
      expect(detector.detect(Float64List(2048)), isNull);
    });

    test('returns nothing for white noise', () {
      final random = math.Random(4);
      final noise = Float64List(2048);
      for (var i = 0; i < noise.length; i++) {
        noise[i] = (random.nextDouble() - 0.5) * 0.4;
      }
      final reading = detector.detect(noise);
      // Either rejected outright, or reported with low confidence.
      if (reading != null) {
        expect(reading.clarity, lessThan(0.8),
            reason: 'noise should not look periodic');
      }
    });

    test('ignores anything below the level floor', () {
      final quiet = tone(hzFor(40), samples: 2048);
      for (var i = 0; i < quiet.length; i++) {
        quiet[i] *= 0.001;
      }
      expect(detector.detect(quiet), isNull);
    });

    test('a tone above the range aliases down rather than being rejected', () {
      // Documented limit, not a bug: any multiple of a true period is also a
      // true period, and the search is bounded to bass frequencies, so 1200 Hz
      // reads as its third submultiple. Nothing in the time domain can tell
      // them apart — it just means this must not be pointed at a whole mix.
      final reading = detector.detect(tone(1200, samples: 2048));
      expect(reading, isNotNull);
      expect(reading!.hz, closeTo(400, 15));
    });
  });
}
