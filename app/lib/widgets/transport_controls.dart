import 'package:flutter/material.dart';

import '../services/playback_clock.dart';
import '../services/stem_player.dart';

String formatTime(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) seconds = 0;
  final total = seconds.round();
  final minutes = total ~/ 60;
  return '$minutes:${(total % 60).toString().padLeft(2, '0')}';
}

/// Seek bar, transport, speed and the stem mix.
class TransportControls extends StatelessWidget {
  const TransportControls({
    super.key,
    required this.clock,
    required this.player,
    required this.onSeek,
    required this.onTogglePlay,
    required this.onRateChanged,
    required this.onMixChanged,
  });

  final PlaybackClock clock;
  final StemPlayer player;
  final ValueChanged<double> onSeek;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onMixChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The clock ticks every frame, so only the seek bar listens to it —
          // the rest of the controls would repaint 60 times a second for nothing.
          AnimatedBuilder(
            animation: clock,
            builder: (context, _) {
              final duration = clock.duration;
              return Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatTime(clock.position),
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: duration <= 0
                          ? 0
                          : clock.position.clamp(0.0, duration),
                      max: duration <= 0 ? 1 : duration,
                      onChanged: duration <= 0 ? null : onSeek,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatTime(duration),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AnimatedBuilder(
                animation: clock,
                builder: (context, _) => IconButton.filled(
                  onPressed: onTogglePlay,
                  iconSize: 28,
                  icon: Icon(clock.isPlaying ? Icons.pause : Icons.play_arrow),
                  tooltip: clock.isPlaying ? 'Pause' : 'Play',
                ),
              ),
              _SpeedSelector(clock: clock, onRateChanged: onRateChanged),
              _StemMix(player: player, onChanged: onMixChanged),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  const _SpeedSelector({required this.clock, required this.onRateChanged});

  final PlaybackClock clock;
  final ValueChanged<double> onRateChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: clock,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, size: 18),
          const SizedBox(width: 6),
          for (final speed in StemPlayer.speeds)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text('${(speed * 100).round()}%'),
                selected: (clock.rate - speed).abs() < 0.001,
                onSelected: (_) => onRateChanged(speed),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

class _StemMix extends StatelessWidget {
  const _StemMix({required this.player, required this.onChanged});

  final StemPlayer player;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = player.hasAudio;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: enabled
              ? () async {
                  await player.setBassMuted(!player.bassMuted);
                  onChanged();
                }
              : null,
          icon: Icon(
            player.bassMuted ? Icons.music_off : Icons.music_note,
          ),
          tooltip: player.bassMuted
              ? 'Unmute bass — hear the line'
              : 'Mute bass — play it yourself',
          isSelected: player.bassMuted,
        ),
        FilterChip(
          label: const Text('Solo bass'),
          selected: player.soloBass,
          onSelected: enabled
              ? (value) async {
                  await player.setSoloBass(value);
                  onChanged();
                }
              : null,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
