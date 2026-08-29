import 'package:flutter/material.dart';

import '../models/tempo_grid.dart';
import '../services/playback_clock.dart';

/// A scrolling strip of beats and bar lines under the fretboard.
///
/// The fretboard's horizontal axis is frets, not time, so the grid cannot be
/// drawn on it. This is a separate window of time centred on the playhead:
/// tall labelled lines for bars, short ticks for beats.
class BeatRuler extends StatelessWidget {
  const BeatRuler({
    super.key,
    required this.grid,
    required this.clock,
    this.windowSeconds = 4.0,
    this.height = 44,
    this.fontFamily,
  });

  final TempoGrid grid;
  final PlaybackClock clock;

  /// How much time the strip shows, centred on now.
  final double windowSeconds;
  final double height;

  /// Null uses the platform font. The render test names a family so the
  /// offline picture matches what the app actually draws.
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BeatRulerPainter(
          grid: grid,
          clock: clock,
          windowSeconds: windowSeconds,
          line: scheme.onSurfaceVariant,
          bar: scheme.onSurface,
          playhead: scheme.primary,
          background: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          fontFamily: fontFamily,
        ),
      ),
    );
  }
}

class _BeatRulerPainter extends CustomPainter {
  _BeatRulerPainter({
    required this.grid,
    required this.clock,
    required this.windowSeconds,
    required this.line,
    required this.bar,
    required this.playhead,
    required this.background,
    this.fontFamily,
  }) : super(repaint: clock);

  final TempoGrid grid;
  final PlaybackClock clock;
  final double windowSeconds;
  final Color line;
  final Color bar;
  final Color playhead;
  final Color background;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    if (grid.isEmpty || size.width < 40) return;

    // Drawn against the calibrated time so the ruler agrees with the fretboard.
    final now = clock.displayPosition;
    final from = now - windowSeconds / 2;
    final to = now + windowSeconds / 2;
    double xFor(double t) => (t - from) / (to - from) * size.width;

    final barTimes = grid.barStarts.toSet();
    final beatPaint = Paint()
      ..color = line.withValues(alpha: 0.55)
      ..strokeWidth = 1.4;
    final barPaint = Paint()
      ..color = bar.withValues(alpha: 0.85)
      ..strokeWidth = 2.2;

    for (final beat in grid.beatsBetween(from, to)) {
      final x = xFor(beat);
      final isBar = barTimes.contains(beat);
      canvas.drawLine(
        Offset(x, isBar ? 4 : size.height * 0.45),
        Offset(x, size.height - 12),
        isBar ? barPaint : beatPaint,
      );
      if (isBar) {
        final position = grid.barAndBeatAt(beat + 1e-6);
        if (position.bar > 0) {
          _text(canvas, '${position.bar}', Offset(x + 5, 3), bar, 10,
              FontWeight.w700);
        }
      }
    }

    // Playhead down the middle: the music moves, the marker does not.
    final centre = size.width / 2;
    canvas.drawLine(
      Offset(centre, 0),
      Offset(centre, size.height),
      Paint()
        ..color = playhead
        ..strokeWidth = 2,
    );
    canvas.drawPath(
      Path()
        ..moveTo(centre - 5, size.height)
        ..lineTo(centre + 5, size.height)
        ..lineTo(centre, size.height - 7)
        ..close(),
      Paint()..color = playhead,
    );
  }

  void _text(Canvas canvas, String value, Offset at, Color colour, double size,
      FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: colour,
          fontSize: size,
          fontWeight: weight,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _BeatRulerPainter old) =>
      old.grid != grid || old.clock != clock || old.fontFamily != fontFamily;
}
