import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import '../services/app_settings.dart';
import '../services/click_track.dart';
import '../services/playback_clock.dart';

String formatOffset(double seconds) {
  final ms = (seconds * 1000).round();
  if (ms == 0) return 'in sync';
  return ms > 0 ? '+$ms ms' : '$ms ms';
}

String describeOffset(double seconds) {
  final ms = (seconds * 1000).round();
  if (ms == 0) return 'Fretboard and audio in sync';
  return ms > 0
      ? 'Fretboard runs $ms ms ahead of the audio'
      : 'Fretboard runs ${-ms} ms behind the audio';
}

/// Plays a click and flashes on the beat so the offset can be dialled in by
/// ear against the eye.
class CalibrationDialog extends StatefulWidget {
  const CalibrationDialog({super.key, required this.clock});

  /// The live clock, so the change is audible/visible while dragging.
  final PlaybackClock clock;

  @override
  State<CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<CalibrationDialog>
    with SingleTickerProviderStateMixin {
  static const ClickTrack _track = ClickTrack();

  final PlaybackClock _clock = PlaybackClock();
  Player? _player;
  StreamSubscription<Duration>? _positionSub;
  Ticker? _ticker;
  String? _error;
  bool _ready = false;

  late double _offset = widget.clock.visualOffset;

  @override
  void initState() {
    super.initState();
    _clock.visualOffset = _offset;
    _ticker = createTicker((_) {
      _clock.tick();
      if (mounted) setState(() {});
    })
      ..start();
    _start();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _positionSub?.cancel();
    _player?.dispose();
    _clock.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final file = await _track.write();
      final player = Player();
      _player = player;
      await player.open(Media(file.path), play: false);
      await player.setPlaylistMode(PlaylistMode.single); // loop it
      _positionSub = player.stream.position.listen(
        (d) => _clock.syncTo(d.inMicroseconds / 1e6),
      );
      _clock.duration = _track.duration;
      await player.play();
      _clock.setPlaying(true);
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _apply(double value) {
    setState(() => _offset = value);
    _clock.visualOffset = value;
    widget.clock.visualOffset = value; // audible on the song behind the dialog
  }

  /// 0 at the instant of a beat, rising to 1 just before the next one.
  double get _phase {
    final beat = _track.beatSeconds;
    if (beat <= 0) return 1;
    final t = _clock.displayPosition;
    return ((t % beat) / beat).clamp(0.0, 1.0);
  }

  int get _beatNumber =>
      _track.beatSeconds <= 0 ? 0 : (_clock.displayPosition / _track.beatSeconds).floor();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A sharp attack that decays, so the eye sees a hit rather than a pulse.
    final flash = _ready ? math.pow(1.0 - _phase, 6).toDouble() : 0.0;
    final accent = _track.isAccent(_beatNumber);
    final colour = accent ? theme.colorScheme.primary : theme.colorScheme.tertiary;

    return AlertDialog(
      title: const Text('Calibrate audio and picture'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Text('Could not play the click: $_error',
                  style: TextStyle(color: theme.colorScheme.error))
            else
              Center(
                child: SizedBox(
                  height: 120,
                  width: 120,
                  child: Center(
                    child: Container(
                      width: 40 + 56 * flash,
                      height: 40 + 56 * flash,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colour.withValues(alpha: 0.25 + 0.75 * flash),
                        boxShadow: [
                          BoxShadow(
                            color: colour.withValues(alpha: 0.6 * flash),
                            blurRadius: 26 * flash,
                            spreadRadius: 6 * flash,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Adjust until the flash lands exactly on the click you hear.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Hear it before you see it? Drag right. See it first? Drag left.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('−300'),
                Expanded(
                  child: Slider(
                    value: _offset.clamp(
                      -PlaybackClock.maxVisualOffset,
                      PlaybackClock.maxVisualOffset,
                    ),
                    min: -PlaybackClock.maxVisualOffset,
                    max: PlaybackClock.maxVisualOffset,
                    divisions: 120, // 5 ms steps
                    label: formatOffset(_offset),
                    onChanged: _apply,
                  ),
                ),
                const Text('+300'),
              ],
            ),
            Center(
              child: Text(
                describeOffset(_offset),
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _apply(0),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Settings, currently just the audio/visual offset and its calibration tool.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.clock});

  final PlaybackClock clock;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late double _offset = widget.clock.visualOffset;
  late double _inputOffset = AppSettings.instance.inputOffset;
  double _restore = 0;

  @override
  void initState() {
    super.initState();
    _restore = widget.clock.visualOffset;
  }

  void _apply(double value) {
    setState(() => _offset = value);
    widget.clock.visualOffset = value;
  }

  Future<void> _calibrate() async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CalibrationDialog(clock: widget.clock),
    );
    if (!mounted) return;
    if (saved == true) {
      setState(() => _offset = widget.clock.visualOffset);
    } else {
      _apply(_offset); // calibration was cancelled: put the slider back
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio / picture offset', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Bluetooth headphones run behind by 100-250 ms. This shifts the '
              'fretboard only — playback, seeking and the end of the song are '
              'unaffected.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                const Text('−300'),
                Expanded(
                  child: Slider(
                    value: _offset.clamp(
                      -PlaybackClock.maxVisualOffset,
                      PlaybackClock.maxVisualOffset,
                    ),
                    min: -PlaybackClock.maxVisualOffset,
                    max: PlaybackClock.maxVisualOffset,
                    divisions: 120,
                    label: formatOffset(_offset),
                    onChanged: _apply,
                  ),
                ),
                const Text('+300'),
              ],
            ),
            Center(child: Text(describeOffset(_offset))),
            const SizedBox(height: 16),
            Text('Microphone offset', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Only used when scoring what you play. The capture buffer is '
              'already accounted for; nudge this if your playing still reads '
              'as consistently early or late.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                const Text('−300'),
                Expanded(
                  child: Slider(
                    value: _inputOffset.clamp(-0.3, 0.3),
                    min: -0.3,
                    max: 0.3,
                    divisions: 120,
                    label: formatOffset(_inputOffset),
                    onChanged: (v) => setState(() => _inputOffset = v),
                  ),
                ),
                const Text('+300'),
              ],
            ),
            Center(child: Text(formatOffset(_inputOffset))),
            const SizedBox(height: 12),
            Center(
              child: OutlinedButton.icon(
                onPressed: _calibrate,
                icon: const Icon(Icons.graphic_eq),
                label: const Text('Calibrate with a click'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.clock.visualOffset = _restore;
            Navigator.pop(context, false);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            await AppSettings.instance.setVisualOffset(_offset);
            await AppSettings.instance.setInputOffset(_inputOffset);
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
