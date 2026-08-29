import 'package:flutter/material.dart';

import '../services/practice_scorer.dart';
import 'fretboard_view.dart' show kHitColour, kMissColour;

/// What the microphone is hearing, and how the last loop pass went.
class ScoreStrip extends StatelessWidget {
  const ScoreStrip({
    super.key,
    required this.scorer,
    required this.lastPass,
    required this.onDismiss,
  });

  final PracticeScorer scorer;
  final SectionScore? lastPass;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: scorer,
      builder: (context, _) {
        final reading = scorer.lastReading;
        final pass = lastPass;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Row(
            children: [
              Icon(Icons.mic, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              SizedBox(
                width: 190,
                child: Text(
                  reading == null
                      ? 'listening…'
                      : 'hearing ${_noteName(reading.midi)}  '
                          '${reading.cents >= 0 ? '+' : ''}'
                          '${reading.cents.round()}c',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (scorer.judged > 0)
                Text(
                  '${scorer.hits}/${scorer.judged} so far',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              if (pass != null && !pass.isEmpty) ...[
                Text(
                  'last pass  ',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: _bandColour(pass.accuracy).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _bandColour(pass.accuracy)),
                  ),
                  child: Text(
                    '${pass.percent}%   ${pass.hits}/${pass.total}',
                    style: TextStyle(
                      color: _bandColour(pass.accuracy),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Dismiss',
                  onPressed: onDismiss,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static Color _bandColour(double accuracy) =>
      accuracy >= 0.8 ? kHitColour : (accuracy >= 0.5 ? Colors.amber : kMissColour);

  static const List<String> _names = [
    'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
  ];

  static String _noteName(int midi) =>
      '${_names[midi % 12]}${midi ~/ 12 - 1}';
}
