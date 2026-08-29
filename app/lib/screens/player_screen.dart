import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/instrument.dart';
import '../models/note_event.dart';
import '../models/tempo_grid.dart';
import '../models/transcription.dart';
import '../services/app_settings.dart';
import '../services/note_timeline.dart';
import '../services/playback_clock.dart';
import '../services/stem_player.dart';
import '../widgets/beat_ruler.dart';
import '../widgets/calibration_dialog.dart';
import '../widgets/fretboard_view.dart';
import '../widgets/tempo_dialog.dart';
import '../widgets/transport_controls.dart';

/// Plays one already-loaded transcription.
///
/// The library owns finding, loading and processing tracks; this screen only
/// has to render and play the one it is handed.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.transcription});

  final Transcription transcription;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final PlaybackClock _clock = PlaybackClock();
  late final StemPlayer _player = StemPlayer(_clock);
  late final FretboardViewModel _viewModel;
  Ticker? _ticker;
  Duration _lastFrame = Duration.zero;
  bool _loadingAudio = true;
  TempoGrid? _grid;

  /// Identifies this track in the settings file, for a manual tempo.
  String get _trackKey => widget.transcription.sourcePath ?? widget.transcription.title;

  @override
  void initState() {
    super.initState();
    _clock.duration = widget.transcription.duration;
    _clock.visualOffset = AppSettings.instance.visualOffset;
    _viewModel = FretboardViewModel(
      timeline: NoteTimeline(widget.transcription.notes),
      instrument: widget.transcription.instrument,
      clock: _clock,
    )..lowStringOnTop = AppSettings.instance.lowStringOnTop;
    _grid = _resolveGrid();
    _ticker = createTicker(_onFrame)..start();
    _loadAudio();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _viewModel.dispose();
    _player.dispose();
    _clock.dispose();
    super.dispose();
  }

  /// A hand-set tempo wins over the detected grid.
  TempoGrid? _resolveGrid() {
    final override = AppSettings.instance.tempoOverride(_trackKey);
    if (override != null) {
      return TempoGrid.uniform(
        bpm: override.bpm,
        duration: widget.transcription.duration,
        firstBeat: override.firstBeat,
        beatsPerBar: widget.transcription.tempo?.beatsPerBar ?? 4,
      );
    }
    return widget.transcription.tempo;
  }

  Future<void> _editTempo() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => TempoDialog(
        detected: widget.transcription.tempo,
        active: _grid,
        trackKey: _trackKey,
        duration: widget.transcription.duration,
      ),
    );
    if (changed == true && mounted) setState(() => _grid = _resolveGrid());
  }

  /// Land on a bar line rather than an arbitrary instant.
  void _seek(double seconds) {
    final grid = _grid;
    final target = (grid != null &&
            !grid.isEmpty &&
            AppSettings.instance.snapSeekToBars)
        ? grid.snapToBar(seconds)
        : seconds;
    _player.seek(target);
  }

  Future<void> _loadAudio() async {
    await _player.load(
      bassPath: widget.transcription.bassStemPath,
      backingPath: widget.transcription.backingStemPath,
      fallbackDuration: widget.transcription.duration,
    );
    if (mounted) setState(() => _loadingAudio = false);
  }

  /// One vsync: advance the clock, then let the fretboard restate itself.
  void _onFrame(Duration elapsed) {
    final dt = (elapsed - _lastFrame).inMicroseconds / 1e6;
    _lastFrame = elapsed;
    _clock.tick();

    // Stop at the end of the track. With stems loaded, media_kit's `completed`
    // stream handles this; a transcription with no audio has no engine to
    // report completion, so without this the clock parks on the last frame
    // still reporting itself as playing.
    if (_clock.isPlaying &&
        _clock.duration > 0 &&
        _clock.position >= _clock.duration) {
      _player.pause();
    }

    // Cap dt so a dropped frame or a backgrounded window does not jump the view.
    _viewModel.advance(dt.clamp(0.0, 0.1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.transcription.title),
        actions: [
          IconButton(
            tooltip: _viewModel.lowStringOnTop
                ? 'Low string on top — switch to tab layout'
                : 'Tab layout (G on top) — switch to low string on top',
            icon: const Icon(Icons.swap_vert),
            onPressed: () {
              setState(
                () => _viewModel.lowStringOnTop = !_viewModel.lowStringOnTop,
              );
              AppSettings.instance.setLowStringOnTop(_viewModel.lowStringOnTop);
            },
          ),
          IconButton(
            tooltip: 'Tempo and bar lines',
            icon: const Icon(Icons.straighten),
            onPressed: _editTempo,
          ),
          IconButton(
            tooltip: 'Settings — audio / picture offset',
            icon: const Icon(Icons.tune),
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (context) => SettingsDialog(clock: _clock),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_loadingAudio && !widget.transcription.hasAudio)
            const _SilentModeBanner(),
          Expanded(child: FretboardView(viewModel: _viewModel)),
          if (_grid != null && !_grid!.isEmpty)
            BeatRuler(grid: _grid!, clock: _clock),
          _NoteReadout(viewModel: _viewModel, grid: _grid, clock: _clock),
          TransportControls(
            clock: _clock,
            player: _player,
            onSeek: _seek,
            onTogglePlay: () => _player.togglePlay(),
            onRateChanged: (rate) => _player.setRate(rate),
            onMixChanged: () => setState(() {}),
          ),
        ],
      ),
    );
  }
}

class _SilentModeBanner extends StatelessWidget {
  const _SilentModeBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'No stems for this transcription — the fretboard is running on the '
        'internal clock.',
        style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12),
      ),
    );
  }
}

/// What is sounding now and what is next: which string, which fret.
class _NoteReadout extends StatelessWidget {
  const _NoteReadout({
    required this.viewModel,
    required this.grid,
    required this.clock,
  });

  final FretboardViewModel viewModel;
  final TempoGrid? grid;
  final PlaybackClock clock;

  String _stringName(int index) =>
      midiToName(viewModel.instrument.tuningMidi[index])
          .replaceAll(RegExp(r'\d'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: viewModel.noteChanges,
      builder: (context, _, __) {
        final current = viewModel.current;
        final next = viewModel.next;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Row(
            children: [
              _NoteChip(viewModel: viewModel, note: current, label: 'NOW'),
              const SizedBox(width: 18),
              if (next != null)
                Opacity(
                  opacity: 0.62,
                  child:
                      _NoteChip(viewModel: viewModel, note: next, label: 'NEXT'),
                ),
              const Spacer(),
              if (grid != null && !grid!.isEmpty) ...[
                _BarBeat(grid: grid!, clock: clock),
                const SizedBox(width: 18),
              ],
              if (current != null && current.string != null)
                Text(
                  '${_stringName(current.string!)} string'
                  '${current.fret == 0 ? '  ·  open' : '  ·  fret ${current.fret}'}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Where we are in the music, in bars and beats rather than seconds.
class _BarBeat extends StatelessWidget {
  const _BarBeat({required this.grid, required this.clock});

  final TempoGrid grid;
  final PlaybackClock clock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: clock,
      builder: (context, _) {
        final at = grid.barAndBeatAt(clock.displayPosition);
        final label = at.bar == 0 ? '—' : 'bar ${at.bar}  ·  beat ${at.beat}';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${grid.bpm.round()} bpm',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}

/// A note as the fretboard draws it: the string's colour, its name, the fret.
class _NoteChip extends StatelessWidget {
  const _NoteChip({
    required this.viewModel,
    required this.note,
    required this.label,
  });

  final FretboardViewModel viewModel;
  final NoteEvent? note;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final string = note?.string;
    final colour =
        string == null ? theme.colorScheme.outline : stringColour(string);
    final stringName = string == null
        ? '—'
        : midiToName(viewModel.instrument.tuningMidi[string])
            .replaceAll(RegExp(r'\d'), '');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: note == null ? 0.15 : 1.0),
            shape: BoxShape.circle,
            border: Border.all(color: colour, width: 2),
          ),
          child: Text(
            stringName,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              note?.name ?? 'rest',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.1),
            ),
            Text(
              note == null
                  ? ''
                  : note!.fret == 0
                      ? 'open'
                      : 'fret ${note!.fret}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.1,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
