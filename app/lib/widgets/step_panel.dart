import 'package:flutter/material.dart';

import '../models/instrument.dart';
import '../models/note_event.dart';
import '../models/tempo_grid.dart';
import '../services/step_walker.dart';
import 'fretboard_view.dart';

/// Names for the fretting fingers. The number is what the fretboard draws
/// inside the marker; the name is what a teacher says out loud, and one is not
/// obvious from the other until you have been told once.
const List<String> kFingerNames = ['open', 'index', 'middle', 'ring', 'pinky'];

String fingerLabel(int? finger) {
  if (finger == null) return '—';
  return finger >= 0 && finger < kFingerNames.length
      ? '$finger · ${kFingerNames[finger]}'
      : '$finger';
}

/// The grip you are standing on, spelled out, with the ones after it.
///
/// Everything here is also on the fretboard above — this says it in words,
/// because "third fret, A string, middle finger" is what you repeat to yourself
/// while your hand finds it, and a coloured dot is not.
class StepPanel extends StatelessWidget {
  const StepPanel({
    super.key,
    required this.walker,
    required this.instrument,
    required this.grid,
    required this.canAudition,
    required this.onAudition,
    required this.onExit,
    required this.onChanged,
  });

  final StepWalker walker;
  final Instrument instrument;
  final TempoGrid? grid;

  /// False when the track has no stems, where there is nothing to play back.
  final bool canAudition;

  final VoidCallback onAudition;
  final VoidCallback onExit;

  /// Called after the walker moves, so the screen can seek the audio with it.
  final VoidCallback onChanged;

  void _move(bool Function() action) {
    if (action()) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: walker,
      builder: (context, _) {
        final note = walker.note;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.55),
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.55),
                width: 2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(context),
              const SizedBox(height: 10),
              _GripCard(note: note, instrument: instrument, grid: grid),
              if (walker.lookahead(4).isNotEmpty) ...[
                const SizedBox(height: 10),
                _Lookahead(walker: walker, instrument: instrument),
              ],
              _scrubber(context),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        FilledButton.tonalIcon(
          onPressed: walker.hasPrevious ? () => _move(walker.previous) : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Back'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: walker.hasNext ? () => _move(walker.next) : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next grip'),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Skip to where the hand moves',
          icon: const Icon(Icons.swipe_right_alt_outlined),
          onPressed: walker.hasShiftAhead ? () => _move(walker.nextShift) : null,
        ),
        IconButton(
          tooltip:
              canAudition ? 'Hear this note' : 'No audio for this track',
          icon: const Icon(Icons.play_circle_outline),
          onPressed: canAudition ? onAudition : null,
        ),
        const Spacer(),
        Text(
          '${walker.step} / ${walker.length}',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: onExit,
          icon: const Icon(Icons.close),
          label: const Text('Play along'),
        ),
      ],
    );
  }

  Widget _scrubber(BuildContext context) {
    if (walker.length < 2) return const SizedBox.shrink();
    return Slider(
      value: walker.index.toDouble().clamp(0, (walker.length - 1).toDouble()),
      max: (walker.length - 1).toDouble(),
      // One division per note, so dragging lands on a grip rather than between
      // two of them.
      divisions: walker.length - 1,
      label: '${walker.step}',
      onChanged: (value) => _move(() => walker.jumpTo(value.round())),
    );
  }
}

/// String, fret and finger for one note, at a size you can read from a stand.
class _GripCard extends StatelessWidget {
  const _GripCard({
    required this.note,
    required this.instrument,
    required this.grid,
  });

  final NoteEvent? note;
  final Instrument instrument;
  final TempoGrid? grid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = this.note;
    final string = note?.string;

    if (note == null || string == null || note.fret == null) {
      return Text(
        note == null
            ? 'Nothing to step through.'
            : '${note.name} — no playable position on this tuning.',
        style: theme.textTheme.titleMedium,
      );
    }

    final colour = stringColour(string);
    final open = note.fret == 0;
    final at = grid != null && !grid!.isEmpty
        ? grid!.barAndBeatAt(note.start)
        : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.85),
              width: 2,
            ),
          ),
          child: Text(
            stringLetter(instrument, string),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 24,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                open
                    ? '${stringLetter(instrument, string)} string, open'
                    : '${stringLetter(instrument, string)} string, '
                        'fret ${note.fret}',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700, height: 1.1),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 16,
                runSpacing: 2,
                children: [
                  _Fact(label: 'note', value: note.name),
                  _Fact(
                    label: 'finger',
                    value:
                        open ? 'none — open string' : fingerLabel(note.finger),
                  ),
                  if ((note.hand ?? 0) > 0)
                    _Fact(label: 'hand at', value: 'fret ${note.hand}'),
                  if (at != null && at.bar > 0)
                    _Fact(
                      label: 'in the music',
                      value: 'bar ${at.bar}, beat ${at.beat}',
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// The grips after this one, so the next shape can be read before arriving.
class _Lookahead extends StatelessWidget {
  const _Lookahead({required this.walker, required this.instrument});

  final StepWalker walker;
  final Instrument instrument;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          'THEN',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final note in walker.lookahead(4))
                _GripChip(note: note, instrument: instrument),
            ],
          ),
        ),
      ],
    );
  }
}

class _GripChip extends StatelessWidget {
  const _GripChip({required this.note, required this.instrument});

  final NoteEvent note;
  final Instrument instrument;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final string = note.string;
    final colour = string == null
        ? theme.colorScheme.outline
        : stringColour(string);
    final where = string == null
        ? note.name
        : note.fret == 0
            ? '${stringLetter(instrument, string)} open'
            : '${stringLetter(instrument, string)}${note.fret}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.20),
        border: Border.all(color: colour.withValues(alpha: 0.85)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            where,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          if ((note.finger ?? 0) > 0) ...[
            const SizedBox(width: 6),
            Text(
              'f${note.finger}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
