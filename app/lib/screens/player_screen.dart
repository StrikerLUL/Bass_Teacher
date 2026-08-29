import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/instrument.dart';
import '../models/note_event.dart';
import '../models/transcription.dart';
import '../services/note_timeline.dart';
import '../services/playback_clock.dart';
import '../services/stem_player.dart';
import '../widgets/fretboard_view.dart';
import '../widgets/transport_controls.dart';

const String kSampleAsset = 'assets/sample/demo_transcription.json';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final PlaybackClock _clock = PlaybackClock();
  late final StemPlayer _player = StemPlayer(_clock);
  Ticker? _ticker;
  Duration _lastFrame = Duration.zero;

  Transcription? _transcription;
  FretboardViewModel? _viewModel;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame)..start();
    _loadSample();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _viewModel?.dispose();
    _player.dispose();
    _clock.dispose();
    super.dispose();
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

    // Cap dt so a dropped frame or a backgrounded window does not teleport the
    // scrolling neck.
    _viewModel?.advance(dt.clamp(0.0, 0.1));
  }

  Future<void> _loadSample() async {
    try {
      final text = await rootBundle.loadString(kSampleAsset);
      await _apply(Transcription.parse(text, title: 'Demo riff'));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: 'Open a transcription.json',
    );
    final path = result?.files.single.path;
    if (path == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _apply(await Transcription.load(File(path)));
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not open that file: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply(Transcription transcription) async {
    await _player.pause();
    _clock.seekTo(0);
    _clock.duration = transcription.duration;

    final previous = _viewModel;
    final next = FretboardViewModel(
      timeline: NoteTimeline(transcription.notes),
      instrument: transcription.instrument,
      clock: _clock,
    );
    if (previous != null) next.lowStringOnTop = previous.lowStringOnTop;

    if (mounted) {
      setState(() {
        _transcription = transcription;
        _viewModel = next;
      });
    }
    previous?.dispose();

    await _player.load(
      bassPath: transcription.bassStemPath,
      backingPath: transcription.backingStemPath,
      fallbackDuration: transcription.duration,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final transcription = _transcription;
    final viewModel = _viewModel;

    return Scaffold(
      appBar: AppBar(
        title: Text(transcription?.title ?? 'Bass Trainer'),
        actions: [
          if (viewModel != null)
            IconButton(
              tooltip: viewModel.lowStringOnTop
                  ? 'Low string on top — switch to tab layout'
                  : 'Tab layout (G on top) — switch to low string on top',
              icon: const Icon(Icons.swap_vert),
              onPressed: () => setState(
                () => viewModel.lowStringOnTop = !viewModel.lowStringOnTop,
              ),
            ),
          IconButton(
            tooltip: 'Open transcription.json',
            icon: const Icon(Icons.folder_open),
            onPressed: _loading ? null : _openFile,
          ),
        ],
      ),
      body: _buildBody(context, transcription, viewModel),
    );
  }

  Widget _buildBody(
    BuildContext context,
    Transcription? transcription,
    FretboardViewModel? viewModel,
  ) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _openFile,
                child: const Text('Open a transcription'),
              ),
            ],
          ),
        ),
      );
    }

    if (transcription == null || viewModel == null) {
      return const Center(child: Text('Nothing loaded.'));
    }

    return Column(
      children: [
        if (!transcription.hasAudio) const _SilentModeBanner(),
        Expanded(child: FretboardView(viewModel: viewModel)),
        _NoteReadout(viewModel: viewModel),
        TransportControls(
          clock: _clock,
          player: _player,
          onSeek: (value) => _player.seek(value),
          onTogglePlay: () => _player.togglePlay(),
          onRateChanged: (rate) => _player.setRate(rate),
          onMixChanged: () => setState(() {}),
        ),
      ],
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
        'internal clock. Run backend/processor.py on a song to add audio.',
        style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12),
      ),
    );
  }
}

/// What is sounding now and what is next, in words.
class _NoteReadout extends StatelessWidget {
  const _NoteReadout({required this.viewModel});

  final FretboardViewModel viewModel;

  /// Strings are named, not numbered: bassists call the G string the "1st" and
  /// the E string the "4th", which is the reverse of the index used everywhere
  /// else here. "D string, fret 7" cannot be misread.
  String _describe(NoteEvent? note) {
    if (note == null) return 'rest';
    final string = note.string;
    if (string == null || note.fret == null) return 'out of range';
    final open = midiToName(viewModel.instrument.tuningMidi[string]);
    return note.fret == 0
        ? '$open string, open'
        : '$open string, fret ${note.fret}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: viewModel.noteChanges,
      builder: (context, _, __) {
        final current = viewModel.current;
        final next = viewModel.next;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  current?.name ?? '—',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  _describe(current),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (next != null)
                Text(
                  'next  ${next.name}  ·  ${_describe(next)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
