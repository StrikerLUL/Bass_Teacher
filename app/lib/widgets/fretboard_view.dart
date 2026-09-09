import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/instrument.dart';
import '../models/note_event.dart';
import '../services/note_timeline.dart';
import '../services/playback_clock.dart';
import '../services/practice_scorer.dart';
import '../services/step_walker.dart';

/// Frets carrying position markers on a bass neck.
const Set<int> _inlayFrets = {3, 5, 7, 9, 15, 17, 19, 21};
const Set<int> _doubleInlayFrets = {12, 24};

/// One colour per string, low to high.
///
/// Colour answers "which string?" faster than reading a label or counting rows,
/// but it is never the only channel: every string also carries its name, and
/// the note is drawn on the string itself.
/// Verdict colours, deliberately not from the string palette: green and red
/// have to mean "right" and "wrong", not "which string".
const Color kHitColour = Color(0xFF3FBF7F);
const Color kMissColour = Color(0xFFEF4A54);

const List<Color> _stringPalette = [
  Color(0xFFEF4A54), // low  - red
  Color(0xFFF29A2E), //      - amber
  Color(0xFF3FBF7F), //      - green
  Color(0xFF3E9BF0), //      - blue
  Color(0xFF9B6BF0), //      - violet
  Color(0xFFE85BB0), // high - pink
];

Color stringColour(int index) => _stringPalette[index % _stringPalette.length];

/// "E", "A", "D", "G" — the string's name without its octave number. It names
/// the string to play, not a pitch to read.
String stringLetter(Instrument instrument, int string) =>
    midiToName(instrument.tuningMidi[string]).replaceAll(RegExp(r'\d'), '');

/// Per-frame state for the fretboard: what is sounding and what is coming.
///
/// The neck does not scroll. An earlier version slid a 15-fret window to follow
/// the hand, which meant the fret numbers moved underneath you and there was no
/// stable picture to learn. The span is instead fixed for the whole song, wide
/// enough for every note in it, so a given fret is always in the same place.
class FretboardViewModel extends ChangeNotifier {
  FretboardViewModel({
    required this.timeline,
    required this.instrument,
    required this.clock,
    this.lookaheadSec = 1.2,
  }) {
    _spanFrets = _computeSpan();
    advance(0);
  }

  final NoteTimeline timeline;
  final Instrument instrument;
  final PlaybackClock clock;

  /// How far ahead to show notes the player should be preparing for.
  final double lookaheadSec;

  /// When listening, supplies hit/miss for each note so the marker can be
  /// coloured by whether it was actually played.
  PracticeScorer? scorer;

  /// When it is walking, the fretboard shows the note it is standing on
  /// instead of following the clock. Same painter, same picture — the only
  /// difference is what supplies "now", which is why a shape looks identical
  /// whether you stepped onto it or played into it.
  StepWalker? walker;

  late final int _spanFrets;

  /// Highest fret drawn. Fixed for the song so the picture never moves.
  int get spanFrets => _spanFrets;

  int _computeSpan() {
    var highest = 0;
    for (final note in timeline.notes) {
      final fret = note.fret;
      if (fret != null && fret > highest) highest = fret;
    }
    return math.min(instrument.frets, math.max(12, highest));
  }

  double _time = 0;
  int _lastHand = 0;
  List<NoteEvent> _active = const [];
  List<NoteEvent> _upcoming = const [];
  NoteEvent? _lastCurrent;
  NoteEvent? _lastNext;

  /// Bumps only when the current or next note actually changes, so a text
  /// readout can skip ~50 rebuilds a second.
  final ValueNotifier<int> noteChanges = ValueNotifier<int>(0);

  double get time => _time;
  List<NoteEvent> get active => _active;
  List<NoteEvent> get upcoming => _upcoming;

  /// True while [walker] is driving the view rather than the clock.
  bool get stepping => walker?.isActive ?? false;

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

  bool _showHandBox = true;
  bool get showHandBox => _showHandBox;
  set showHandBox(bool value) {
    if (value == _showHandBox) return;
    _showHandBox = value;
    notifyListeners();
  }

  /// Called once per vsync.
  void advance(double dt) {
    final walker = this.walker;
    if (walker != null && walker.isActive) {
      // Stepping: "now" is wherever the walker is standing, and the notes
      // after it are shown by position rather than by how soon they arrive —
      // a bar's rest must not empty the strip.
      final note = walker.note;
      _time = note?.start ?? _time;
      _active = note == null ? const [] : [note];
      _upcoming = walker.lookahead(4);
    } else {
      // Drawn against the calibrated time, not the raw audio position.
      _time = clock.displayPosition;
      _active = timeline.activeAt(_time);
      _upcoming = timeline.between(_time, _time + lookaheadSec, limit: 8);
    }

    final anchor = _resolveHandFret();
    if (anchor > 0) _lastHand = anchor;

    if (!identical(current, _lastCurrent) || !identical(next, _lastNext)) {
      _lastCurrent = current;
      _lastNext = next;
      noteChanges.value++;
    }
    notifyListeners();
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

  @override
  void dispose() {
    noteChanges.dispose();
    super.dispose();
  }
}

class FretboardView extends StatelessWidget {
  const FretboardView({super.key, required this.viewModel});

  final FretboardViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: FretboardPainter(vm: viewModel),
    );
  }
}

class FretboardPainter extends CustomPainter {
  FretboardPainter({required this.vm, this.fontFamily}) : super(repaint: vm);

  final FretboardViewModel vm;

  /// Null uses the platform font. The render test names a family so the
  /// offline picture matches what the app actually draws.
  final String? fontFamily;

  static const double _gutterLeft = 74;
  static const double _gutterBottom = 24;
  static const double _gutterTop = 20;
  static const double _gutterRight = 12;

  // Rosewood board, maple binding, nickel frets, bone nut.
  static const Color _boardDark = Color(0xFF241611);
  static const Color _boardLight = Color(0xFF4A3226);
  static const Color _binding = Color(0xFFC9A227);
  static const Color _fretWire = Color(0xFFB9B2A6);
  static const Color _nutColour = Color(0xFFE8DCC8);
  static const Color _stringMetal = Color(0xFFD8D2C4);
  static const Color _inlay = Color(0xFFEDE6D6);

  @override
  void paint(Canvas canvas, Size size) {
    final neck = Rect.fromLTRB(
      _gutterLeft,
      _gutterTop,
      size.width - _gutterRight,
      size.height - _gutterBottom,
    );
    if (neck.width < 80 || neck.height < 60) return;

    final rows = vm.instrument.stringCount;
    final span = vm.spanFrets;

    double xForFret(double fret) => neck.left + fret * neck.width / span;
    // Centre of a fretted note: between its wire and the one before it.
    double xForMarker(int fret) => xForFret(fret - 0.5);
    // Strings sit close to the edges of the board, as they do on the
    // instrument. Centring them in equal rows left dead bands above the top
    // string and below the bottom one, which reads as a chart, not a neck.
    final inset = neck.height * 0.13;
    final spacing = rows > 1 ? (neck.height - 2 * inset) / (rows - 1) : 0.0;
    double yForString(int string) {
      final row = vm.lowStringOnTop ? string : rows - 1 - string;
      return rows > 1 ? neck.top + inset + row * spacing : neck.center.dy;
    }

    final fretWidth = neck.width / span;
    final rowHeight = rows > 1 ? spacing : neck.height;
    final radius = math.min(fretWidth * 0.46, rowHeight * 0.44);

    _paintBoard(canvas, neck);
    _paintInlays(canvas, neck, span, xForMarker);
    _paintFrets(canvas, neck, span, xForFret);
    if (vm.showHandBox) _paintHandBox(canvas, neck, span, xForFret);
    _paintActiveStringBand(canvas, neck, rowHeight, yForString);
    _paintStrings(canvas, neck, rows, yForString);
    _paintUpcoming(canvas, radius, xForMarker, yForString);
    _paintActive(canvas, neck, radius, xForMarker, yForString);
    _paintFretNumbers(canvas, neck, span, xForMarker);
    _paintStringLabels(canvas, neck, rows, rowHeight, yForString);
  }

  // ----------------------------------------------------------------- board --

  void _paintBoard(Canvas canvas, Rect neck) {
    final rounded = RRect.fromRectAndRadius(neck, const Radius.circular(8));

    canvas.drawRRect(
      rounded,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_boardLight, _boardDark, _boardDark, _boardLight],
          stops: [0.0, 0.22, 0.78, 1.0],
        ).createShader(neck),
    );

    // Wood grain: a few long, faint streaks along the board.
    canvas.save();
    canvas.clipRRect(rounded);
    final grain = Paint()..strokeWidth = 1.2;
    final random = math.Random(7); // fixed seed: the grain must not shimmer
    for (var i = 0; i < 18; i++) {
      final y = neck.top + random.nextDouble() * neck.height;
      grain.color =
          Colors.white.withValues(alpha: 0.015 + random.nextDouble() * 0.02);
      canvas.drawLine(
        Offset(neck.left, y),
        Offset(neck.right, y + (random.nextDouble() - 0.5) * 10),
        grain,
      );
    }
    canvas.restore();

    // Binding along the top and bottom edge.
    final edge = Paint()
      ..color = _binding.withValues(alpha: 0.5)
      ..strokeWidth = 2;
    canvas.drawLine(neck.topLeft, neck.topRight, edge);
    canvas.drawLine(neck.bottomLeft, neck.bottomRight, edge);
  }

  void _paintInlays(
      Canvas canvas, Rect neck, int span, double Function(int) xForMarker) {
    final paint = Paint()..color = _inlay.withValues(alpha: 0.30);
    final radius = math.min(neck.width / span, neck.height / 4) * 0.17;
    for (var fret = 1; fret <= span; fret++) {
      final x = xForMarker(fret);
      if (_doubleInlayFrets.contains(fret)) {
        canvas.drawCircle(
            Offset(x, neck.top + neck.height * 0.26), radius, paint);
        canvas.drawCircle(
            Offset(x, neck.top + neck.height * 0.74), radius, paint);
      } else if (_inlayFrets.contains(fret)) {
        canvas.drawCircle(Offset(x, neck.center.dy), radius, paint);
      }
      // Side dots on the top edge, where a player actually looks.
      if (_inlayFrets.contains(fret) || _doubleInlayFrets.contains(fret)) {
        canvas.drawCircle(
          Offset(x, neck.top - 9),
          _doubleInlayFrets.contains(fret) ? 3.2 : 2.4,
          Paint()..color = _inlay.withValues(alpha: 0.75),
        );
      }
    }
  }

  void _paintFrets(
      Canvas canvas, Rect neck, int span, double Function(double) xForFret) {
    for (var fret = 0; fret <= span; fret++) {
      final x = xForFret(fret.toDouble());
      if (fret == 0) {
        // The nut: thicker, bone coloured, sitting proud of the board.
        canvas.drawRect(
          Rect.fromLTRB(x - 3, neck.top, x + 3, neck.bottom),
          Paint()..color = _nutColour,
        );
        canvas.drawLine(
          Offset(x - 3, neck.top),
          Offset(x - 3, neck.bottom),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.35)
            ..strokeWidth = 1,
        );
      } else {
        canvas.drawLine(
          Offset(x, neck.top),
          Offset(x, neck.bottom),
          Paint()
            ..color = _fretWire
            ..strokeWidth = 2.4,
        );
        // A highlight down one side reads as rounded metal.
        canvas.drawLine(
          Offset(x - 1.2, neck.top),
          Offset(x - 1.2, neck.bottom),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.18)
            ..strokeWidth = 0.8,
        );
      }
    }
  }

  void _paintHandBox(
      Canvas canvas, Rect neck, int span, double Function(double) xForFret) {
    final hand = vm.handFret;
    if (hand <= 0) return;
    final left = xForFret((hand - 1).clamp(0, span).toDouble());
    final right = xForFret((hand + 3).clamp(0, span).toDouble());
    canvas.drawRect(
      Rect.fromLTRB(left, neck.top, right, neck.bottom),
      Paint()..color = Colors.white.withValues(alpha: 0.05),
    );
  }

  // --------------------------------------------------------------- strings --

  /// A wash of the string's own colour along its whole length while it sounds.
  /// This is the "which string do I play" cue: readable at a glance, unlike a
  /// single marker somewhere along the neck.
  void _paintActiveStringBand(Canvas canvas, Rect neck, double rowHeight,
      double Function(int) yForString) {
    for (final note in vm.active) {
      final string = note.string;
      if (string == null) continue;
      final y = yForString(string);
      final colour = stringColour(string);
      final band = Rect.fromLTRB(
          neck.left, y - rowHeight * 0.42, neck.right, y + rowHeight * 0.42);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colour.withValues(alpha: 0.0),
              colour.withValues(alpha: 0.22),
              colour.withValues(alpha: 0.0),
            ],
          ).createShader(band),
      );
    }
  }

  void _paintStrings(
      Canvas canvas, Rect neck, int rows, double Function(int) yForString) {
    final ringing = {
      for (final note in vm.active)
        if (note.string != null) note.string!
    };

    for (var string = 0; string < rows; string++) {
      final y = yForString(string);
      // Lower strings are visibly fatter, as on the instrument.
      final gauge = 1.6 + (rows - 1 - string) * 1.15;
      final lit = ringing.contains(string);

      canvas.drawLine(
        Offset(neck.left, y + gauge * 0.7),
        Offset(neck.right, y + gauge * 0.7),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.45)
          ..strokeWidth = gauge,
      );
      canvas.drawLine(
        Offset(neck.left, y),
        Offset(neck.right, y),
        Paint()
          ..color = lit ? stringColour(string) : _stringMetal
          ..strokeWidth = gauge,
      );
      canvas.drawLine(
        Offset(neck.left, y - gauge * 0.28),
        Offset(neck.right, y - gauge * 0.28),
        Paint()
          ..color = Colors.white.withValues(alpha: lit ? 0.5 : 0.28)
          ..strokeWidth = gauge * 0.3,
      );
    }
  }

  // ----------------------------------------------------------------- notes --

  void _paintUpcoming(Canvas canvas, double radius,
      double Function(int) xForMarker, double Function(int) yForString) {
    for (var i = 0; i < vm.upcoming.length; i++) {
      final note = vm.upcoming[i];
      final string = note.string;
      final fret = note.fret;
      if (string == null || fret == null || fret == 0) continue;

      // Playing, a note fades in as it approaches. Stepping, there is no
      // approach — the clock is stopped — so it fades by how many grips away
      // it is instead, which keeps the same "next is brightest" reading.
      final lead = vm.stepping
          ? (i + 1) / (vm.upcoming.length + 1)
          : (note.start - vm.time) / vm.lookaheadSec;
      final opacity = (1.0 - lead).clamp(0.0, 1.0) * 0.65;
      if (opacity < 0.02) continue;

      canvas.drawCircle(
        Offset(xForMarker(fret), yForString(string)),
        radius * (0.55 + 0.3 * (1 - lead)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..color = stringColour(string).withValues(alpha: opacity),
      );
    }
  }

  void _paintActive(Canvas canvas, Rect neck, double radius,
      double Function(int) xForMarker, double Function(int) yForString) {
    for (final note in vm.active) {
      final string = note.string;
      final fret = note.fret;
      if (string == null || fret == null || fret == 0) continue;

      final progress = note.progressAt(vm.time);
      final swell = 1.0 + 0.18 * (1 - progress) * (1 - progress);
      final verdict = vm.scorer?.verdictFor(note) ?? NoteVerdict.pending;
      final colour = switch (verdict) {
        NoteVerdict.hit => kHitColour,
        NoteVerdict.missed => kMissColour,
        NoteVerdict.pending => stringColour(string),
      };
      final centre = Offset(xForMarker(fret), yForString(string));

      canvas.drawCircle(
        centre,
        radius * swell * 1.7,
        Paint()
          ..color = colour.withValues(alpha: 0.45 * (1 - progress) + 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
      canvas.drawCircle(centre, radius * swell, Paint()..color = colour);
      canvas.drawCircle(
        centre,
        radius * swell,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.9),
      );
      // Inside the marker: which finger. Outside, just above it: which string.
      // The fret is read off the numbers along the bottom.
      final finger = note.finger;
      _drawText(
        canvas,
        finger != null && finger > 0 ? '$finger' : note.name,
        centre,
        TextStyle(
          color: Colors.white,
          fontSize: finger != null && finger > 0
              ? math.min(22, radius * 1.05)
              : math.min(15, radius * 0.72),
          fontWeight: FontWeight.w800,
        ),
      );
      // Above the marker, unless that would push the pill off the top of the
      // board — on the highest string it has to sit underneath instead.
      final gap = radius * swell + 11;
      final above = centre.dy - gap;
      _drawLabel(
        canvas,
        stringLetter(vm.instrument, string),
        Offset(centre.dx, above < neck.top ? centre.dy + gap : above),
        colour,
      );
    }
  }

  /// A small pill so the string letter stays readable over the fretboard.
  void _drawLabel(Canvas canvas, String text, Offset centre, Color colour) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final box = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: centre,
        width: painter.width + 12,
        height: painter.height + 4,
      ),
      const Radius.circular(9),
    );
    canvas.drawRRect(box, Paint()..color = colour);
    canvas.drawRRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.black.withValues(alpha: 0.35),
    );
    painter.paint(
        canvas, centre - Offset(painter.width / 2, painter.height / 2));
  }

  // ---------------------------------------------------------------- labels --

  void _paintFretNumbers(
      Canvas canvas, Rect neck, int span, double Function(int) xForMarker) {
    final handLow = vm.handFret;
    // Stepping, the whole question is "which fret", and the answer is read off
    // this row — so the one being asked about is named in its string's colour
    // rather than left to be counted.
    final current = vm.stepping ? vm.current : null;
    final onFret = (current?.fret ?? 0) > 0 ? current!.fret : null;

    for (var fret = 1; fret <= span; fret++) {
      final marked =
          _inlayFrets.contains(fret) || _doubleInlayFrets.contains(fret);
      final inHand = vm.showHandBox &&
          handLow > 0 &&
          fret >= handLow &&
          fret < handLow + 4;
      final here = fret == onFret;
      _drawText(
        canvas,
        '$fret',
        Offset(xForMarker(fret), neck.bottom + _gutterBottom / 2),
        TextStyle(
          color: here
              ? stringColour(current!.string ?? 0)
              : inHand
                  ? Colors.white
                  : Colors.white.withValues(alpha: marked ? 0.75 : 0.38),
          fontSize: here ? 14 : 11,
          fontWeight:
              here || inHand || marked ? FontWeight.w700 : FontWeight.w400,
        ),
      );
    }
  }

  /// Big colour-coded name per string, doubling as the legend and as the
  /// open-string indicator.
  void _paintStringLabels(Canvas canvas, Rect neck, int rows, double rowHeight,
      double Function(int) yForString) {
    final ringingOpen = {
      for (final note in vm.active)
        if (note.fret == 0 && note.string != null) note.string!
    };
    final ringing = {
      for (final note in vm.active)
        if (note.string != null) note.string!
    };

    for (var string = 0; string < rows; string++) {
      final centre = Offset(_gutterLeft / 2 - 4, yForString(string));
      final colour = stringColour(string);
      final open = ringingOpen.contains(string);
      final lit = ringing.contains(string);
      final size = math.min(20.0, rowHeight * 0.34);

      if (open) {
        canvas.drawCircle(
          centre,
          size * 1.5,
          Paint()
            ..color = colour.withValues(alpha: 0.55)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
        );
      }
      canvas.drawCircle(
        centre,
        size,
        Paint()..color = lit ? colour : colour.withValues(alpha: 0.20),
      );
      canvas.drawCircle(
        centre,
        size,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lit ? 2.5 : 1.4
          ..color = colour.withValues(alpha: lit ? 1.0 : 0.65),
      );
      _drawText(
        canvas,
        stringLetter(vm.instrument, string),
        centre,
        TextStyle(
          color: lit ? Colors.white : colour,
          fontSize: size * 0.95,
          fontWeight: FontWeight.w800,
        ),
      );
      if (open) {
        _drawText(
          canvas,
          'open',
          Offset(centre.dx, centre.dy + size + 7),
          TextStyle(color: colour, fontSize: 9, fontWeight: FontWeight.w700),
        );
      }
    }
  }

  void _drawText(Canvas canvas, String text, Offset centre, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: fontFamily == null
              ? style
              : style.copyWith(fontFamily: fontFamily)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
        canvas, centre - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant FretboardPainter old) =>
      old.vm != vm || old.fontFamily != fontFamily;
}
