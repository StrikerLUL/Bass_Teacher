import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/instrument.dart';
import '../models/note_event.dart';
import '../services/note_timeline.dart';
import '../services/playback_clock.dart';

/// Frets that carry position markers on a bass neck.
const Set<int> _inlayFrets = {3, 5, 7, 9, 15, 17, 19, 21};
const Set<int> _doubleInlayFrets = {12, 24};

/// Per-frame state for the fretboard: what is sounding, what is coming, and
/// which stretch of neck to show.
///
/// It drives the painter directly (as its `repaint` listenable) so a frame
/// costs one repaint instead of a widget rebuild.
class FretboardViewModel extends ChangeNotifier {
  FretboardViewModel({
    required this.timeline,
    required this.instrument,
    required this.clock,
    this.visibleFrets = 15,
    this.lookaheadSec = 1.2,
  }) {
    _windowStart = 0;
    advance(0);
  }

  final NoteTimeline timeline;
  final Instrument instrument;
  final PlaybackClock clock;

  /// How much of the neck fits on screen. A 24-fret neck drawn whole leaves the
  /// upper frets too narrow to read, so the view scrolls instead.
  final int visibleFrets;

  /// How far ahead to show notes the player should be preparing for.
  final double lookaheadSec;

  /// Seconds for the scrolling neck to settle on a new hand position.
  static const double _windowSettleSec = 0.18;

  double _time = 0;
  double _windowStart = 0;
  int _lastHand = 0;
  List<NoteEvent> _active = const [];
  List<NoteEvent> _upcoming = const [];
  NoteEvent? _lastCurrent;
  NoteEvent? _lastNext;

  /// Bumps only when the current or next note actually changes.
  ///
  /// The painter wants every frame; a text readout wants roughly ten a second,
  /// so it listens to this instead and skips ~50 rebuilds a second.
  final ValueNotifier<int> noteChanges = ValueNotifier<int>(0);

  double get time => _time;
  double get windowStart => _windowStart;
  List<NoteEvent> get active => _active;
  List<NoteEvent> get upcoming => _upcoming;
  NoteEvent? get current => _active.isEmpty ? null : _active.first;
  NoteEvent? get next => _upcoming.isEmpty ? null : _upcoming.first;
  int get handFret => _lastHand;

  bool _lowStringOnTop = false;

  /// False (the default) puts the G string on top, matching written tab.
  bool get lowStringOnTop => _lowStringOnTop;
  set lowStringOnTop(bool value) {
    if (value == _lowStringOnTop) return;
    _lowStringOnTop = value;
    notifyListeners();
  }

  /// Advance by [dt] seconds of wall time. Called once per vsync.
  void advance(double dt) {
    _time = clock.position;
    _active = timeline.activeAt(_time);
    _upcoming = timeline.between(_time, _time + lookaheadSec, limit: 8);

    final anchor = _resolveHandFret();
    if (anchor > 0) _lastHand = anchor;

    // Exponential ease, expressed against elapsed time so the scroll takes the
    // same wall-clock duration regardless of frame rate.
    final maxStart = math.max(0, instrument.frets - visibleFrets).toDouble();
    final target = (_lastHand - 2).toDouble().clamp(0.0, maxStart);
    final k = dt <= 0 ? 1.0 : 1 - math.exp(-dt / _windowSettleSec);
    _windowStart += (target - _windowStart) * k;
    if ((target - _windowStart).abs() < 0.01) _windowStart = target;

    if (!identical(current, _lastCurrent) || !identical(next, _lastNext)) {
      _lastCurrent = current;
      _lastNext = next;
      noteChanges.value++;
    }

    notifyListeners();
  }

  @override
  void dispose() {
    noteChanges.dispose();
    super.dispose();
  }

  int _resolveHandFret() {
    for (final note in _active) {
      if ((note.hand ?? 0) > 0) return note.hand!;
      if ((note.fret ?? 0) > 0) return note.fret!;
    }
    final ahead = next;
    if (ahead != null) {
      if ((ahead.hand ?? 0) > 0) return ahead.hand!;
      if ((ahead.fret ?? 0) > 0) return ahead.fret!;
    }
    return _lastHand;
  }
}

/// Colours pulled once per build so the painter stays theme-agnostic.
class FretboardPalette {
  const FretboardPalette({
    required this.neck,
    required this.neckEdge,
    required this.fretWire,
    required this.nut,
    required this.inlay,
    required this.stringColor,
    required this.label,
    required this.labelDim,
    required this.active,
    required this.upcoming,
    required this.handBox,
  });

  final Color neck;
  final Color neckEdge;
  final Color fretWire;
  final Color nut;
  final Color inlay;
  final Color stringColor;
  final Color label;
  final Color labelDim;
  final Color active;
  final Color upcoming;
  final Color handBox;

  factory FretboardPalette.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FretboardPalette(
      neck: const Color(0xFF241C17),
      neckEdge: const Color(0xFF3B2E25),
      fretWire: const Color(0xFF6E6357),
      nut: const Color(0xFFD9CFC0),
      inlay: const Color(0x33FFFFFF),
      stringColor: const Color(0xFFB9AE9C),
      label: scheme.onSurface,
      labelDim: scheme.onSurface.withValues(alpha: 0.45),
      active: scheme.primary,
      upcoming: scheme.tertiary,
      handBox: scheme.primary.withValues(alpha: 0.07),
    );
  }
}

class FretboardView extends StatelessWidget {
  const FretboardView({super.key, required this.viewModel});

  final FretboardViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: FretboardPainter(
        vm: viewModel,
        palette: FretboardPalette.of(context),
      ),
    );
  }
}

class FretboardPainter extends CustomPainter {
  FretboardPainter({required this.vm, required this.palette})
      : super(repaint: vm);

  final FretboardViewModel vm;
  final FretboardPalette palette;

  static const double _gutterLeft = 46;
  static const double _gutterBottom = 22;
  static const double _gutterTop = 10;
  static const double _gutterRight = 10;

  @override
  void paint(Canvas canvas, Size size) {
    final neck = Rect.fromLTRB(
      _gutterLeft,
      _gutterTop,
      size.width - _gutterRight,
      size.height - _gutterBottom,
    );
    if (neck.width < 40 || neck.height < 40) return;

    final instrument = vm.instrument;
    final rows = instrument.stringCount;
    final start = vm.windowStart;
    final span = vm.visibleFrets;

    double xForFret(double fret) =>
        neck.left + (fret - start) * neck.width / span;

    // Centre of a fretted note: midway between its wire and the one before it.
    double xForMarker(int fret) => xForFret(fret - 0.5);

    double yForString(int string) {
      final row = vm.lowStringOnTop ? string : rows - 1 - string;
      return neck.top + (row + 0.5) * neck.height / rows;
    }

    final radius = math.min(neck.width / span, neck.height / rows) * 0.36;

    _paintNeck(canvas, neck);

    canvas.save();
    canvas.clipRect(neck);
    _paintHandBox(canvas, neck, xForFret);
    _paintInlays(canvas, neck, rows, start, span, xForMarker);
    _paintFretWires(canvas, neck, start, span, xForFret);
    _paintStrings(canvas, neck, rows, yForString);
    _paintUpcoming(canvas, radius, xForMarker, yForString);
    _paintActive(canvas, radius, xForMarker, yForString);
    canvas.restore();

    _paintFretNumbers(canvas, neck, start, span, xForMarker);
    _paintOpenStrings(canvas, neck, rows, yForString);
  }

  // ------------------------------------------------------------------ neck --

  void _paintNeck(Canvas canvas, Rect neck) {
    final rounded = RRect.fromRectAndRadius(neck, const Radius.circular(6));
    canvas.drawRRect(
      rounded,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.neckEdge, palette.neck, palette.neckEdge],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(neck),
    );
    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = palette.neckEdge,
    );
  }

  void _paintHandBox(Canvas canvas, Rect neck, double Function(double) xForFret) {
    final hand = vm.handFret;
    if (hand <= 0) return;
    final box = Rect.fromLTRB(
      xForFret(hand - 1.0),
      neck.top,
      xForFret(hand + 3.0),
      neck.bottom,
    );
    canvas.drawRect(box, Paint()..color = palette.handBox);
  }

  void _paintInlays(
    Canvas canvas,
    Rect neck,
    int rows,
    double start,
    int span,
    double Function(int) xForMarker,
  ) {
    final paint = Paint()..color = palette.inlay;
    final radius = math.min(neck.width / span, neck.height / rows) * 0.16;
    for (var fret = start.floor(); fret <= start + span + 1; fret++) {
      if (fret < 1 || fret > vm.instrument.frets) continue;
      final x = xForMarker(fret);
      if (_doubleInlayFrets.contains(fret)) {
        canvas.drawCircle(Offset(x, neck.top + neck.height * 0.28), radius, paint);
        canvas.drawCircle(Offset(x, neck.top + neck.height * 0.72), radius, paint);
      } else if (_inlayFrets.contains(fret)) {
        canvas.drawCircle(Offset(x, neck.center.dy), radius, paint);
      }
    }
  }

  void _paintFretWires(
    Canvas canvas,
    Rect neck,
    double start,
    int span,
    double Function(double) xForFret,
  ) {
    final wire = Paint()
      ..color = palette.fretWire
      ..strokeWidth = 1.6;
    final nut = Paint()
      ..color = palette.nut
      ..strokeWidth = 5;

    for (var fret = start.floor(); fret <= start + span + 1; fret++) {
      if (fret < 0 || fret > vm.instrument.frets) continue;
      final x = xForFret(fret.toDouble());
      canvas.drawLine(
        Offset(x, neck.top),
        Offset(x, neck.bottom),
        fret == 0 ? nut : wire,
      );
    }
  }

  void _paintStrings(
    Canvas canvas,
    Rect neck,
    int rows,
    double Function(int) yForString,
  ) {
    for (var string = 0; string < rows; string++) {
      final y = yForString(string);
      // Lower strings are visibly fatter, which is how you find them by eye.
      final thickness = 1.2 + (rows - 1 - string) * 0.8;
      canvas.drawLine(
        Offset(neck.left, y),
        Offset(neck.right, y),
        Paint()
          ..color = palette.stringColor
          ..strokeWidth = thickness,
      );
    }
  }

  // ----------------------------------------------------------------- notes --

  void _paintUpcoming(
    Canvas canvas,
    double radius,
    double Function(int) xForMarker,
    double Function(int) yForString,
  ) {
    for (final note in vm.upcoming) {
      final string = note.string;
      final fret = note.fret;
      if (string == null || fret == null || fret == 0) continue;

      // Fade in as the note approaches, so the eye tracks what is next without
      // the ghosts competing with the note actually sounding.
      final lead = (note.start - vm.time) / vm.lookaheadSec;
      final opacity = (1.0 - lead).clamp(0.0, 1.0) * 0.5;
      if (opacity < 0.02) continue;

      canvas.drawCircle(
        Offset(xForMarker(fret), yForString(string)),
        radius * (0.6 + 0.25 * (1 - lead)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = palette.upcoming.withValues(alpha: opacity),
      );
    }

    _paintShiftHint(canvas, xForMarker, yForString);
  }

  /// A dashed line to the next note when it is out of reach of the current hand
  /// position — the moment a learner needs warning that a shift is coming.
  void _paintShiftHint(
    Canvas canvas,
    double Function(int) xForMarker,
    double Function(int) yForString,
  ) {
    final from = vm.current;
    final to = vm.next;
    if (from == null || to == null) return;
    if (from.fret == null || to.fret == null) return;
    if (from.fret == 0 || to.fret == 0) return;
    if ((to.fret! - from.fret!).abs() < 5) return;

    _dashedLine(
      canvas,
      Offset(xForMarker(from.fret!), yForString(from.string!)),
      Offset(xForMarker(to.fret!), yForString(to.string!)),
      Paint()
        ..color = palette.upcoming.withValues(alpha: 0.55)
        ..strokeWidth = 1.6,
    );
  }

  void _paintActive(
    Canvas canvas,
    double radius,
    double Function(int) xForMarker,
    double Function(int) yForString,
  ) {
    for (final note in vm.active) {
      final string = note.string;
      final fret = note.fret;
      if (string == null || fret == null) continue;
      if (fret == 0) continue; // open strings light up their gutter badge

      // Attack reads as a brief swell that decays over the note.
      final progress = note.progressAt(vm.time);
      final swell = 1.0 + 0.22 * (1 - progress) * (1 - progress);
      final alpha = (0.55 + 0.45 * (1 - progress)).clamp(0.0, 1.0);
      final centre = Offset(xForMarker(fret), yForString(string));

      canvas.drawCircle(
        centre,
        radius * swell * 1.5,
        Paint()
          ..color = palette.active.withValues(alpha: alpha * 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      canvas.drawCircle(
        centre,
        radius * swell,
        Paint()..color = palette.active.withValues(alpha: alpha),
      );
      _drawText(
        canvas,
        note.name,
        centre,
        TextStyle(
          color: Colors.black.withValues(alpha: 0.85),
          fontSize: math.min(13, radius * 0.75),
          fontWeight: FontWeight.w700,
        ),
      );
    }
  }

  // ---------------------------------------------------------------- labels --

  void _paintFretNumbers(
    Canvas canvas,
    Rect neck,
    double start,
    int span,
    double Function(int) xForMarker,
  ) {
    for (var fret = start.floor(); fret <= start + span + 1; fret++) {
      if (fret < 1 || fret > vm.instrument.frets) continue;
      final x = xForMarker(fret);
      if (x < neck.left - 4 || x > neck.right + 4) continue;
      final marked =
          _inlayFrets.contains(fret) || _doubleInlayFrets.contains(fret);
      _drawText(
        canvas,
        '$fret',
        Offset(x, neck.bottom + _gutterBottom / 2),
        TextStyle(
          color: marked ? palette.label : palette.labelDim,
          fontSize: 11,
          fontWeight: marked ? FontWeight.w600 : FontWeight.w400,
        ),
      );
    }
  }

  /// Open-string badges live in the left gutter and light up in place of a
  /// marker on the neck, since fret 0 has no space between wires to sit in.
  void _paintOpenStrings(
    Canvas canvas,
    Rect neck,
    int rows,
    double Function(int) yForString,
  ) {
    final radius = math.min(14.0, neck.height / rows * 0.34);
    final ringing = {
      for (final note in vm.active)
        if (note.fret == 0 && note.string != null) note.string!
    };

    for (var string = 0; string < rows; string++) {
      final centre = Offset(_gutterLeft / 2, yForString(string));
      final lit = ringing.contains(string);
      if (lit) {
        canvas.drawCircle(
          centre,
          radius * 1.5,
          Paint()
            ..color = palette.active.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
        );
      }
      canvas.drawCircle(
        centre,
        radius,
        lit
            ? (Paint()..color = palette.active)
            : (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = palette.labelDim),
      );
      _drawText(
        canvas,
        midiToName(vm.instrument.tuningMidi[string]),
        centre,
        TextStyle(
          color: lit ? Colors.black.withValues(alpha: 0.85) : palette.labelDim,
          fontSize: 11,
          fontWeight: lit ? FontWeight.w700 : FontWeight.w500,
        ),
      );
    }
  }

  // --------------------------------------------------------------- helpers --

  void _drawText(Canvas canvas, String text, Offset centre, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _dashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    double dash = 6,
    double gap = 5,
  }) {
    final delta = to - from;
    final length = delta.distance;
    if (length < 1) return;
    final step = delta / length;
    for (var travelled = 0.0; travelled < length; travelled += dash + gap) {
      final end = math.min(travelled + dash, length);
      canvas.drawLine(
        from + step * travelled,
        from + step * end,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant FretboardPainter old) =>
      old.vm != vm || old.palette != palette;
}
