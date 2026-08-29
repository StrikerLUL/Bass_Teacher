import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Builds a metronome click as a WAV file for calibration.
///
/// Synthesised rather than shipped as an asset so the beat times are exactly
/// known — the calibration screen flashes on those same times, and any
/// mismatch the ear notices is real latency rather than a guess about where
/// the click sits inside a sample.
class ClickTrack {
  const ClickTrack({this.bpm = 100, this.beats = 120, this.sampleRate = 44100});

  final int bpm;
  final int beats;
  final int sampleRate;

  double get beatSeconds => 60.0 / bpm;
  double get duration => beats * beatSeconds;

  /// Every fourth beat is accented, so it is obvious the click is a bar and
  /// not a stutter.
  bool isAccent(int beat) => beat % 4 == 0;

  Future<File> write({Directory? directory}) async {
    final dir = directory ?? Directory.systemTemp;
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'bass_trainer_click_$bpm.wav'));
    await file.writeAsBytes(_render(), flush: true);
    return file;
  }

  Uint8List _render() {
    final beatSamples = (sampleRate * beatSeconds).round();
    final total = beatSamples * beats;
    final samples = Int16List(total);

    final clickSamples = (sampleRate * 0.030).round();
    final decay = sampleRate * 0.005;

    for (var beat = 0; beat < beats; beat++) {
      final start = beat * beatSamples;
      final accent = isAccent(beat);
      final frequency = accent ? 1600.0 : 1050.0;
      final gain = accent ? 0.85 : 0.5;
      for (var i = 0; i < clickSamples && start + i < total; i++) {
        final envelope = math.exp(-i / decay);
        final value =
            math.sin(2 * math.pi * frequency * i / sampleRate) * envelope * gain;
        samples[start + i] = (value * 32000).round();
      }
    }
    return _wav(samples, sampleRate);
  }

  static Uint8List _wav(Int16List samples, int rate) {
    const channels = 1;
    const bitsPerSample = 16;
    final dataBytes = samples.lengthInBytes;
    final bytes = BytesBuilder();

    void ascii(String text) => bytes.add(text.codeUnits);
    void uint32(int value) =>
        bytes.add(Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little));
    void uint16(int value) =>
        bytes.add(Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little));

    ascii('RIFF');
    uint32(36 + dataBytes);
    ascii('WAVE');
    ascii('fmt ');
    uint32(16);
    uint16(1); // PCM
    uint16(channels);
    uint32(rate);
    uint32(rate * channels * bitsPerSample ~/ 8); // byte rate
    uint16(channels * bitsPerSample ~/ 8); // block align
    uint16(bitsPerSample);
    ascii('data');
    uint32(dataBytes);
    bytes.add(samples.buffer.asUint8List(0, dataBytes));

    return bytes.toBytes();
  }
}
