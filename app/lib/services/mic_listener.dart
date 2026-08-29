import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'pitch_detector.dart';

/// Captures the default input device and reports what pitch it hears.
///
/// Capture runs at a low rate on purpose: a bass fundamental tops out around
/// 400 Hz, and the pitch detector's cost grows with the longest period it must
/// consider. Asking the device for 11 kHz mono avoids resampling entirely on
/// hardware that will grant it.
class MicListener extends ChangeNotifier {
  MicListener({PitchDetector? detector, this.frameSize = 2048})
      : detector = detector ?? PitchDetector(sampleRate: _captureRate);

  static const int _captureRate = 11025;

  final PitchDetector detector;

  /// Samples per analysis frame. 2048 at 11 kHz is ~186 ms, enough to see
  /// several periods of a low E.
  final int frameSize;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _subscription;

  final List<double> _buffer = [];
  final int _rate = _captureRate;

  bool _running = false;
  String? _error;
  PitchReading? _latest;

  bool get isRunning => _running;
  String? get error => _error;
  PitchReading? get latest => _latest;

  /// How far behind real time a detection is, in seconds.
  ///
  /// A frame cannot be analysed until it is full, so on average a detection
  /// describes sound from half a frame ago, plus whatever the device buffered.
  /// The scorer subtracts this so playing in time does not read as playing
  /// late.
  double get captureLatencySec => frameSize / (2 * _rate);

  final StreamController<PitchReading> _readings =
      StreamController<PitchReading>.broadcast();

  /// Every accepted detection, in order.
  Stream<PitchReading> get readings => _readings.stream;

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<void> start() async {
    if (_running) return;
    _error = null;
    try {
      if (!await _recorder.hasPermission()) {
        _fail('No microphone permission.');
        return;
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _captureRate,
          numChannels: 1,
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ),
      );
      _buffer.clear();
      _running = true;
      notifyListeners();
      _subscription = stream.listen(
        _onChunk,
        onError: (Object e) => _fail('$e'),
        cancelOnError: true,
      );
    } catch (e) {
      _fail('$e');
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    if (_running) {
      try {
        await _recorder.stop();
      } catch (_) {
        // Already stopped, or the device went away.
      }
    }
    _running = false;
    _latest = null;
    _buffer.clear();
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _running = false;
    notifyListeners();
  }

  /// Signed 16-bit little-endian PCM in, analysis frames out.
  void _onChunk(Uint8List chunk) {
    final samples = Int16List.sublistView(chunk);
    for (final sample in samples) {
      _buffer.add(sample / 32768.0);
    }

    while (_buffer.length >= frameSize) {
      final frame = Float64List(frameSize);
      for (var i = 0; i < frameSize; i++) {
        frame[i] = _buffer[i];
      }
      // Half-frame hop: a note lasting ~90 ms still gets looked at twice.
      _buffer.removeRange(0, frameSize ~/ 2);

      final reading = detector.detect(frame);
      if (reading != null) {
        _latest = reading;
        if (!_readings.isClosed) _readings.add(reading);
        notifyListeners();
      } else if (_latest != null) {
        _latest = null;
        notifyListeners();
      }
    }

    // Never let the buffer run away if analysis falls behind.
    final cap = frameSize * 4;
    if (_buffer.length > cap) {
      _buffer.removeRange(0, _buffer.length - cap);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _readings.close();
    _recorder.dispose();
    super.dispose();
  }

  /// Exposed for tests: feed PCM without a device.
  @visibleForTesting
  void debugFeed(Int16List samples) => _onChunk(
        Uint8List.sublistView(samples),
      );

  @visibleForTesting
  static int get captureRate => _captureRate;

  @visibleForTesting
  double get latencyForRate => frameSize / (2 * math.max(1, _rate));
}
