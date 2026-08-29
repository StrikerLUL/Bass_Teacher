import 'package:flutter/material.dart';

import '../models/tempo_grid.dart';
import '../services/app_settings.dart';

/// Shows what the backend detected, how sure it is, and lets it be overridden.
///
/// Beat tracking is a guess, so the confidence is shown plainly rather than
/// hidden: a "weak" reading is a prompt to type the tempo in, not a number to
/// trust silently.
class TempoDialog extends StatefulWidget {
  const TempoDialog({
    super.key,
    required this.detected,
    required this.active,
    required this.trackKey,
    required this.duration,
  });

  /// What the backend wrote into the JSON, if anything.
  final TempoGrid? detected;

  /// What is in use right now — the override if one is set.
  final TempoGrid? active;

  final String trackKey;
  final double duration;

  @override
  State<TempoDialog> createState() => _TempoDialogState();
}

class _TempoDialogState extends State<TempoDialog> {
  late final TextEditingController _bpm;
  late final TextEditingController _firstBeat;
  late bool _snap = AppSettings.instance.snapSeekToBars;
  String? _error;

  @override
  void initState() {
    super.initState();
    final active = widget.active;
    _bpm = TextEditingController(
      text: active == null ? '' : active.bpm.toStringAsFixed(1),
    );
    _firstBeat = TextEditingController(
      text: active == null ? '0.0' : active.firstDownbeat.toStringAsFixed(3),
    );
  }

  @override
  void dispose() {
    _bpm.dispose();
    _firstBeat.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bpm = double.tryParse(_bpm.text.trim());
    if (bpm == null || bpm <= 0 || bpm > 400) {
      setState(() => _error = 'Enter a tempo between 1 and 400.');
      return;
    }
    final firstBeat = double.tryParse(_firstBeat.text.trim()) ?? 0.0;
    await AppSettings.instance
        .setTempoOverride(widget.trackKey, bpm, firstBeat);
    await AppSettings.instance.setSnapSeekToBars(_snap);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _useDetected() async {
    await AppSettings.instance.clearTempoOverride(widget.trackKey);
    await AppSettings.instance.setSnapSeekToBars(_snap);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detected = widget.detected;
    final overridden = AppSettings.instance.tempoOverride(widget.trackKey);

    return AlertDialog(
      title: const Text('Tempo'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (detected == null)
              Text(
                'No beat grid in this transcription. Re-transcribe it, or type '
                'a tempo below.',
                style: theme.textTheme.bodySmall,
              )
            else
              RichText(
                text: TextSpan(
                  style: theme.textTheme.bodyMedium,
                  children: [
                    const TextSpan(text: 'Detected '),
                    TextSpan(
                      text: '${detected.bpm.toStringAsFixed(1)} bpm',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: '  ·  confidence '
                          '${(detected.confidence * 100).round()}% '
                          '(${detected.quality})',
                      style: TextStyle(
                        color: detected.confidence >= 0.5
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            if (overridden != null) ...[
              const SizedBox(height: 6),
              Text(
                'Currently overridden by hand.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bpm,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'BPM',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _firstBeat,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'First downbeat (s)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 4),
            Text(
              'A tempo typed here builds an even grid, so it will drift on a '
              'song that speeds up or slows down.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            CheckboxListTile(
              value: _snap,
              onChanged: (v) => setState(() => _snap = v ?? true),
              title: const Text('Snap seeking to bar lines'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        if (detected != null)
          TextButton(
            onPressed: _useDetected,
            child: const Text('Use detected'),
          ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
