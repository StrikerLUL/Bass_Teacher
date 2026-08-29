import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/tempo_grid.dart';

/// How the loop speeds up as you get a passage clean.
class SpeedRamp {
  const SpeedRamp({
    this.enabled = false,
    this.from = 0.6,
    this.to = 1.0,
    this.steps = 5,
  });

  final bool enabled;
  final double from;
  final double to;

  /// Number of rungs, counting both ends. 5 means 60, 70, 80, 90, 100%.
  final int steps;

  /// Rate for a given pass, holding at [to] once the top is reached.
  double rateForPass(int pass) {
    if (steps <= 1) return to;
    final rung = pass.clamp(0, steps - 1);
    return from + (to - from) * rung / (steps - 1);
  }

  List<double> get rungs =>
      [for (var i = 0; i < math.max(1, steps); i++) rateForPass(i)];

  SpeedRamp copyWith({bool? enabled, double? from, double? to, int? steps}) =>
      SpeedRamp(
        enabled: enabled ?? this.enabled,
        from: from ?? this.from,
        to: to ?? this.to,
        steps: steps ?? this.steps,
      );
}

/// An A–B practice loop: mark two points, play between them, speed up as you
/// get it right.
class LoopController extends ChangeNotifier {
  double? _start;
  double? _end;
  bool _enabled = true;
  int _passes = 0;
  SpeedRamp _ramp = const SpeedRamp();

  double? get start => _start;
  double? get end => _end;
  bool get enabled => _enabled;
  int get passes => _passes;
  SpeedRamp get ramp => _ramp;

  /// Both points set, in order, and long enough to be worth looping.
  bool get isSet =>
      _start != null && _end != null && _end! - _start! > minimumSeconds;

  bool get isActive => isSet && _enabled;

  double get length => isSet ? _end! - _start! : 0;

  /// Below this a "loop" is a stutter, not a practice tool.
  static const double minimumSeconds = 0.25;

  double get currentRate => _ramp.enabled ? _ramp.rateForPass(_passes) : 1.0;

  /// True once the ramp has reached its top rung.
  bool get rampComplete => _ramp.enabled && _passes >= _ramp.steps - 1;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
  }

  set ramp(SpeedRamp value) {
    _ramp = value;
    notifyListeners();
  }

  /// Mark A at [time]. If it lands after B, B is dropped rather than silently
  /// producing an inverted region.
  void markStart(double time, {TempoGrid? grid}) {
    _start = _snap(time, grid);
    if (_end != null && _end! <= _start! + minimumSeconds) _end = null;
    _passes = 0;
    notifyListeners();
  }

  void markEnd(double time, {TempoGrid? grid}) {
    _end = _snap(time, grid);
    if (_start != null && _end! <= _start! + minimumSeconds) _start = null;
    _passes = 0;
    notifyListeners();
  }

  /// Set both ends at once, as a drag across the bar does. Order is sorted, so
  /// dragging right-to-left works.
  void setRegion(double a, double b, {TempoGrid? grid}) {
    final low = _snap(math.min(a, b), grid);
    final high = _snap(math.max(a, b), grid);
    if (high - low <= minimumSeconds) return;
    _start = low;
    _end = high;
    _passes = 0;
    notifyListeners();
  }

  void clear() {
    _start = null;
    _end = null;
    _passes = 0;
    notifyListeners();
  }

  void resetRamp() {
    if (_passes == 0) return;
    _passes = 0;
    notifyListeners();
  }

  /// Called when a pass completes. Returns the rate to play the next one at.
  double completePass() {
    _passes++;
    notifyListeners();
    return currentRate;
  }

  /// Where playback should jump to, given it has run past B.
  ///
  /// The overshoot past B is carried over past A instead of being discarded.
  /// A frame is up to ~16 ms, and throwing that away every pass would walk the
  /// loop steadily out of time with the music.
  double wrapPosition(double position) {
    if (!isSet) return position;
    final overshoot = position - _end!;
    final wrapped = _start! + (overshoot > 0 ? overshoot : 0);
    // Never wrap past B: a huge overshoot means something stalled, so restart
    // cleanly at A.
    return wrapped >= _end! ? _start! : wrapped;
  }

  bool shouldWrap(double position) => isActive && position >= _end!;

  double _snap(double time, TempoGrid? grid) {
    if (grid == null || grid.isEmpty) return math.max(0, time);
    return math.max(0, grid.snapToBar(time));
  }
}
