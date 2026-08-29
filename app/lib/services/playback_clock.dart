import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The single source of truth for "where are we in the track", in seconds.
///
/// Audio engines report their position in coarse steps — media_kit emits one
/// every ~100-200ms — and animating a fretboard straight off those readings
/// visibly stutters. So this class runs its own wall-clock extrapolation from
/// the last known anchor and treats engine readings as *corrections*:
///
///   * a small error nudges the anchor by a fraction, invisibly absorbing it;
///   * an error past [_hardResyncSec] (a seek, a stall, a loop) snaps outright.
///
/// It also refuses to run backwards during playback, because a late reading
/// arriving after an extrapolated frame would otherwise flick the highlight
/// back onto the previous note.
class PlaybackClock extends ChangeNotifier {
  static const double _hardResyncSec = 0.25;
  static const double _nudgeFactor = 0.12;

  final Stopwatch _wall = Stopwatch()..start();

  double _anchorPosition = 0.0;
  double _anchorWall = 0.0;
  double _position = 0.0;
  bool _playing = false;
  double _rate = 1.0;
  double _duration = 0.0;

  double get position => _position;
  bool get isPlaying => _playing;
  double get rate => _rate;
  double get duration => _duration;

  double get _wallSeconds => _wall.elapsedMicroseconds / 1e6;

  double get _predicted => _playing
      ? _anchorPosition + (_wallSeconds - _anchorWall) * _rate
      : _anchorPosition;

  void _reanchor() {
    _anchorPosition = _predicted;
    _anchorWall = _wallSeconds;
  }

  set duration(double value) {
    if (value == _duration) return;
    _duration = value;
    notifyListeners();
  }

  void setPlaying(bool value) {
    if (value == _playing) return;
    _reanchor(); // freeze at, or resume from, the current extrapolated position
    _playing = value;
    notifyListeners();
  }

  void setRate(double value) {
    if (value == _rate) return;
    _reanchor(); // bank the time already elapsed at the old rate
    _rate = value;
    notifyListeners();
  }

  void seekTo(double seconds) {
    final target =
        _duration > 0 ? seconds.clamp(0.0, _duration) : math.max(0.0, seconds);
    _anchorPosition = target;
    _anchorWall = _wallSeconds;
    _position = target;
    notifyListeners();
  }

  /// Feed a real reading from the audio engine.
  void syncTo(double reported) {
    final error = reported - _predicted;
    if (error.abs() > _hardResyncSec) {
      _anchorPosition = reported;
      _anchorWall = _wallSeconds;
    } else {
      _anchorPosition += error * _nudgeFactor;
    }
  }

  /// Advance to the current frame. Called once per vsync by the screen.
  void tick() {
    var next = _predicted;
    if (_duration > 0) next = next.clamp(0.0, _duration);
    if (_playing && next < _position) return; // never rewind mid-playback
    if ((next - _position).abs() < 1e-6) return;
    _position = next;
    notifyListeners();
  }
}
