import 'package:flutter/material.dart';

import '../services/loop_controller.dart';
import '../services/playback_clock.dart';
import 'transport_controls.dart' show formatTime;

/// Mark A and B, arm the loop, and drive the speed ramp.
class LoopControls extends StatelessWidget {
  const LoopControls({
    super.key,
    required this.loop,
    required this.clock,
    required this.onMarkStart,
    required this.onMarkEnd,
    required this.onChanged,
  });

  final LoopController loop;
  final PlaybackClock clock;
  final VoidCallback onMarkStart;
  final VoidCallback onMarkEnd;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: loop,
      builder: (context, _) {
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: onMarkStart,
              child: Text(loop.start == null
                  ? 'Set A'
                  : 'A ${formatTime(loop.start!)}'),
            ),
            OutlinedButton(
              onPressed: onMarkEnd,
              child: Text(
                  loop.end == null ? 'Set B' : 'B ${formatTime(loop.end!)}'),
            ),
            FilterChip(
              label: const Text('Loop'),
              selected: loop.isActive,
              onSelected: loop.isSet
                  ? (value) {
                      loop.enabled = value;
                      onChanged();
                    }
                  : null,
              visualDensity: VisualDensity.compact,
            ),
            if (loop.isSet)
              IconButton(
                tooltip: 'Clear the loop',
                icon: const Icon(Icons.close),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  loop.clear();
                  onChanged();
                },
              ),
            if (loop.isSet) ...[
              Text(
                'pass ${loop.passes + 1}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              _RampButton(loop: loop, onChanged: onChanged),
            ],
          ],
        );
      },
    );
  }
}

class _RampButton extends StatelessWidget {
  const _RampButton({required this.loop, required this.onChanged});

  final LoopController loop;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ramp = loop.ramp;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilterChip(
          avatar: const Icon(Icons.trending_up, size: 16),
          label: Text(
            ramp.enabled
                ? '${(ramp.from * 100).round()}-${(ramp.to * 100).round()}%'
                : 'Speed ramp',
          ),
          selected: ramp.enabled,
          onSelected: (value) {
            loop.ramp = ramp.copyWith(enabled: value);
            onChanged();
          },
          visualDensity: VisualDensity.compact,
        ),
        if (ramp.enabled) ...[
          const SizedBox(width: 6),
          Text(
            loop.rampComplete
                ? 'at full speed'
                : '${(loop.currentRate * 100).round()}%',
            style: theme.textTheme.labelMedium?.copyWith(
              color: loop.rampComplete
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Back to the slowest step',
            icon: const Icon(Icons.restart_alt),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              loop.resetRamp();
              onChanged();
            },
          ),
          IconButton(
            tooltip: 'Ramp settings',
            icon: const Icon(Icons.tune),
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await showDialog<void>(
                context: context,
                builder: (context) => _RampDialog(loop: loop),
              );
              onChanged();
            },
          ),
        ],
      ],
    );
  }
}

class _RampDialog extends StatefulWidget {
  const _RampDialog({required this.loop});

  final LoopController loop;

  @override
  State<_RampDialog> createState() => _RampDialogState();
}

class _RampDialogState extends State<_RampDialog> {
  late SpeedRamp _ramp = widget.loop.ramp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Speed ramp'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each clean pass moves up a step. The ramp holds at the top; it '
              'never drops back on its own.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _row(
              'Start',
              '${(_ramp.from * 100).round()}%',
              Slider(
                value: _ramp.from,
                min: 0.3,
                max: 1.0,
                divisions: 14,
                onChanged: (v) => setState(
                  () => _ramp = _ramp.copyWith(from: v > _ramp.to ? _ramp.to : v),
                ),
              ),
            ),
            _row(
              'Finish',
              '${(_ramp.to * 100).round()}%',
              Slider(
                value: _ramp.to,
                min: 0.5,
                max: 1.2,
                divisions: 14,
                onChanged: (v) => setState(
                  () => _ramp =
                      _ramp.copyWith(to: v < _ramp.from ? _ramp.from : v),
                ),
              ),
            ),
            _row(
              'Steps',
              '${_ramp.steps}',
              Slider(
                value: _ramp.steps.toDouble(),
                min: 2,
                max: 10,
                divisions: 8,
                onChanged: (v) =>
                    setState(() => _ramp = _ramp.copyWith(steps: v.round())),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _ramp.rungs.map((r) => '${(r * 100).round()}%').join('  >  '),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            widget.loop.ramp = _ramp;
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _row(String label, String value, Widget slider) => Row(
        children: [
          SizedBox(width: 62, child: Text(label)),
          Expanded(child: slider),
          SizedBox(width: 46, child: Text(value, textAlign: TextAlign.end)),
        ],
      );
}
