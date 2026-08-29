import 'package:flutter/material.dart';

import '../services/loop_controller.dart';
import '../services/playback_clock.dart';
import 'transport_controls.dart' show formatTime;

/// Seek bar with the loop region drawn on it and a lane to drag one out.
///
/// The drag lane is a separate strip under the slider rather than a gesture on
/// the slider itself: one widget cannot sensibly own both "scrub to here" and
/// "select from here to there".
class LoopSeekBar extends StatefulWidget {
  const LoopSeekBar({
    super.key,
    required this.clock,
    required this.loop,
    required this.onSeek,
  });

  final PlaybackClock clock;
  final LoopController loop;
  final ValueChanged<double> onSeek;

  @override
  State<LoopSeekBar> createState() => _LoopSeekBarState();
}

class _LoopSeekBarState extends State<LoopSeekBar> {
  double? _dragFrom;
  double? _dragTo;

  double _timeAt(double dx, double width) {
    final duration = widget.clock.duration;
    if (duration <= 0 || width <= 0) return 0;
    return (dx / width).clamp(0.0, 1.0) * duration;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([widget.clock, widget.loop]),
      builder: (context, _) {
        final duration = widget.clock.duration;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(formatTime(widget.clock.position),
                      style: theme.textTheme.labelMedium),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // The loop region sits behind the slider track.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _LoopRegionPainter(
                              loop: widget.loop,
                              duration: duration,
                              colour: theme.colorScheme.tertiary,
                            ),
                          ),
                        ),
                      ),
                      Slider(
                        value: duration <= 0
                            ? 0
                            : widget.clock.position.clamp(0.0, duration),
                        max: duration <= 0 ? 1 : duration,
                        onChanged: duration <= 0 ? null : widget.onSeek,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(formatTime(duration),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelMedium),
                ),
              ],
            ),
            // Drag lane.
            Padding(
              padding: const EdgeInsets.only(left: 44 + 24, right: 44 + 24),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (details) => setState(() {
                      _dragFrom = _timeAt(details.localPosition.dx, width);
                      _dragTo = _dragFrom;
                    }),
                    onHorizontalDragUpdate: (details) => setState(
                      () => _dragTo = _timeAt(details.localPosition.dx, width),
                    ),
                    onHorizontalDragEnd: (_) {
                      final from = _dragFrom;
                      final to = _dragTo;
                      if (from != null && to != null) {
                        widget.loop.setRegion(from, to);
                      }
                      setState(() {
                        _dragFrom = null;
                        _dragTo = null;
                      });
                    },
                    child: SizedBox(
                      height: 18,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _LoopLanePainter(
                          loop: widget.loop,
                          duration: duration,
                          dragFrom: _dragFrom,
                          dragTo: _dragTo,
                          colour: theme.colorScheme.tertiary,
                          hint: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LoopRegionPainter extends CustomPainter {
  _LoopRegionPainter({
    required this.loop,
    required this.duration,
    required this.colour,
  });

  final LoopController loop;
  final double duration;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    if (!loop.isSet || duration <= 0) return;
    // Match the Slider's internal 24px horizontal padding so the shading lines
    // up with the track rather than the widget box.
    const pad = 24.0;
    final width = size.width - pad * 2;
    if (width <= 0) return;
    double x(double t) => pad + (t / duration).clamp(0.0, 1.0) * width;

    final rect = Rect.fromLTRB(
      x(loop.start!),
      size.height / 2 - 7,
      x(loop.end!),
      size.height / 2 + 7,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = colour.withValues(alpha: loop.enabled ? 0.28 : 0.12),
    );
  }

  @override
  bool shouldRepaint(covariant _LoopRegionPainter old) => true;
}

class _LoopLanePainter extends CustomPainter {
  _LoopLanePainter({
    required this.loop,
    required this.duration,
    required this.dragFrom,
    required this.dragTo,
    required this.colour,
    required this.hint,
  });

  final LoopController loop;
  final double duration;
  final double? dragFrom;
  final double? dragTo;
  final Color colour;
  final Color hint;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = hint.withValues(alpha: 0.20)
        ..strokeWidth = 2,
    );
    if (duration <= 0) return;
    double x(double t) => (t / duration).clamp(0.0, 1.0) * size.width;

    void band(double a, double b, double alpha) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x(a), y - 5, x(b), y + 5),
          const Radius.circular(3),
        ),
        Paint()..color = colour.withValues(alpha: alpha),
      );
    }

    if (dragFrom != null && dragTo != null) {
      band(dragFrom! < dragTo! ? dragFrom! : dragTo!,
          dragFrom! < dragTo! ? dragTo! : dragFrom!, 0.45);
      return;
    }
    if (!loop.isSet) return;

    band(loop.start!, loop.end!, loop.enabled ? 0.55 : 0.22);
    // End caps rather than letters: at this size a glyph does not fit inside
    // the lane, and the buttons below already name A and B with their times.
    final cap = Paint()
      ..color = colour
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (final edge in [loop.start!, loop.end!]) {
      canvas.drawLine(
        Offset(x(edge), y - 8),
        Offset(x(edge), y + 8),
        cap,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LoopLanePainter old) => true;
}
