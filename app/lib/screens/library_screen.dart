import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/transcription.dart';
import '../services/library.dart';
import '../services/transcription_job.dart';
import '../widgets/process_dialogs.dart';
import '../widgets/transport_controls.dart' show formatTime;
import 'player_screen.dart';

const String kSampleAsset = 'assets/sample/demo_transcription.json';

/// Home screen: every processed track in `data/`, plus a way to add more.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<LibraryEntry>? _entries;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    try {
      final found = await Library.scan();
      if (mounted) setState(() => _entries = found);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _open(LibraryEntry entry) async {
    setState(() => _busy = true);
    try {
      final transcription = await Transcription.load(entry.transcriptionFile);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(transcription: transcription),
      ));
    } catch (error) {
      _report('Could not open ${entry.folderName}: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDemo() async {
    setState(() => _busy = true);
    try {
      final text = await rootBundle.loadString(kSampleAsset);
      final transcription = Transcription.parse(text, title: 'Demo riff');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(transcription: transcription),
      ));
    } catch (error) {
      _report('Could not open the demo: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSong() async {
    if (TranscriptionJob.locateProcessor() == null) {
      _report('Could not find backend/processor.py next to the app.');
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
    await _runJob(job, openResult: true);
  }

  Future<void> _retranscribe(LibraryEntry entry) async {
    final job = TranscriptionJob();
    unawaited(job.retranscribe(entry.directory));
    await _runJob(job, openResult: false);
  }

  /// Shows the progress dialog, refreshes the library, and optionally opens
  /// whatever the job produced.
  Future<void> _runJob(TranscriptionJob job, {required bool openResult}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ProcessingDialog(job: job),
    );
    final result = job.resultPath;
    job.dispose();
    if (!mounted) return;
    await _refresh();
    if (ok != true || result == null || !openResult || !mounted) return;

    try {
      final transcription = await Transcription.load(File(result));
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(transcription: transcription),
      ));
    } catch (error) {
      _report('Processed, but could not open the result: $error');
    }
  }

  Future<void> _delete(LibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this track?'),
        content: Text(
          'This removes ${entry.folderName} and its stems from disk. '
          'The original audio file is not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await Library.delete(entry);
    } catch (error) {
      _report('Could not delete: $error');
    }
    await _refresh();
  }

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bass Trainer'),
        actions: [
          IconButton(
            tooltip: 'Play the built-in demo riff',
            icon: const Icon(Icons.piano),
            onPressed: _busy ? null : _openDemo,
          ),
          IconButton(
            tooltip: 'Rescan the data folder',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (entries == null && _error == null)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            _Message(
              icon: Icons.error_outline,
              text: _error!,
              action: FilledButton.tonal(
                onPressed: _refresh,
                child: const Text('Try again'),
              ),
            )
          else
            _Grid(
              entries: entries!,
              onOpen: _open,
              onAdd: _addSong,
              onRetranscribe: _retranscribe,
              onDelete: _delete,
            ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.entries,
    required this.onOpen,
    required this.onAdd,
    required this.onRetranscribe,
    required this.onDelete,
  });

  final List<LibraryEntry> entries;
  final ValueChanged<LibraryEntry> onOpen;
  final VoidCallback onAdd;
  final ValueChanged<LibraryEntry> onRetranscribe;
  final ValueChanged<LibraryEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 380,
        mainAxisExtent: 176,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _AddCard(onTap: onAdd);
        final entry = entries[index - 1];
        return _TrackCard(
          entry: entry,
          onOpen: () => onOpen(entry),
          onRetranscribe: () => onRetranscribe(entry),
          onDelete: () => onDelete(entry),
        );
      },
    );
  }
}

class _AddCard extends StatelessWidget {
  const _AddCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
          color: scheme.primary.withValues(alpha: 0.06),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 34, color: scheme.primary),
            const SizedBox(height: 10),
            Text(
              'Add a song',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: scheme.primary),
            ),
            const SizedBox(height: 4),
            Text(
              'Separate the bass and transcribe it',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.entry,
    required this.onOpen,
    required this.onRetranscribe,
    required this.onDelete,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onRetranscribe;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Track actions',
                    onSelected: (value) {
                      if (value == 'retranscribe') onRetranscribe();
                      if (value == 'delete') onDelete();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'retranscribe',
                        enabled: entry.canRetranscribe,
                        child: const ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.refresh),
                          title: Text('Re-transcribe'),
                          subtitle: Text('Reuses the stems — skips Demucs'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${formatTime(entry.duration)}   ·   ${entry.noteCount} notes'
                '   ·   peak ${entry.peakNotesPerSec.toStringAsFixed(0)}/s',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _Tag(
                    label: entry.hasBass ? 'Bass stem' : 'No bass stem',
                    good: entry.hasBass,
                  ),
                  _Tag(
                    label: entry.hasBacking ? 'Backing' : 'No backing',
                    good: entry.hasBacking,
                  ),
                  if (entry.engine != null) _Tag(label: entry.engine!),
                  if (entry.tuning != null) _Tag(label: entry.tuning!),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.good});

  final String label;

  /// null renders neutral; false marks something missing.
  final bool? good;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = good == null
        ? scheme.onSurfaceVariant
        : good!
            ? scheme.primary
            : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: colour, height: 1.2),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
