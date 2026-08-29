import 'dart:async';
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
import '../services/transcription_job.dart';
import '../widgets/process_dialogs.dart';
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

  /// Pick a song, run the Python pipeline on it, then load the result.
  Future<void> _processSong() async {
    if (TranscriptionJob.locateProcessor() == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not find backend/processor.py next to the app.'),
      ));
      return;
    }

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: TranscriptionJob.audioExtensions,
      dialogTitle: 'Choose a song to transcribe',
    );
    final audioPath = picked?.files.single.path;
    if (audioPath == null || !mounted) return;

    final preview = await askProcessingOptions(context, audioPath);
    if (preview == null || !mounted) return;

    final job = TranscriptionJob();
    unawaited(job.run(audioPath: audioPath, preview: preview));
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ProcessingDialog(job: job),
    );

    final result = job.resultPath;
    job.dispose();
    if (ok != true || result == null || !mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _apply(await Transcription.load(File(result)));
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not open the result: $error');
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
            tooltip: 'Add a song — separate the bass and transcribe it',
            icon: const Icon(Icons.library_music),
            onPressed: _loading ? null : _processSong,
          ),
          IconButton(
            tooltip: 'Open an existing transcription.json',
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
        'internal clock. Use the ♫ button above to add a song.',
        style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12),
      ),
    );
  }
}

/// What is sounding now and what is next: which string, which fret.
class _NoteReadout extends StatelessWidget {
  const _NoteReadout({required this.viewModel});

  final FretboardViewModel viewModel;

  String _stringName(int index) =>
      midiToName(viewModel.instrument.tuningMidi[index]).replaceAll(RegExp(r'\d'), '');

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
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          child: Row(
            children: [
              _NoteChip(viewModel: viewModel, note: current, label: 'NOW'),
              const SizedBox(width: 18),
              if (next != null)
                Opacity(
                  opacity: 0.62,
                  child: _NoteChip(
                      viewModel: viewModel, note: next, label: 'NEXT'),
                ),
              const Spacer(),
              if (current != null && current.string != null)
                Text(
                  '${_stringName(current.string!)} string'
                  '${current.fret == 0 ? '  ·  open' : '  ·  fret ${current.fret}'}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
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
    final colour = string == null
        ? theme.colorScheme.outline
        : stringColour(string);
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
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
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
