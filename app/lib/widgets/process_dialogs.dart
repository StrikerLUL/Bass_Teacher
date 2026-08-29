import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/transcription_job.dart';

/// Asks how to process a freshly picked song. Returns true for a 30s preview,
/// false for the whole song, or null if cancelled.
Future<bool?> askProcessingOptions(BuildContext context, String audioPath) {
  var preview = false;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Add this song'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.basename(audioPath),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'The bass is separated out with Demucs, then transcribed. '
              'A full song usually takes a couple of minutes on the GPU.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: preview,
              onChanged: (v) => setState(() => preview = v ?? false),
              title: const Text('Quick preview'),
              subtitle: const Text('First 30 seconds only'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, preview),
            child: const Text('Process'),
          ),
        ],
      ),
    ),
  );
}

/// Live progress for a running [TranscriptionJob]. Closes itself when the job
/// finishes, returning true on success.
class ProcessingDialog extends StatefulWidget {
  const ProcessingDialog({super.key, required this.job});

  final TranscriptionJob job;

  @override
  State<ProcessingDialog> createState() => _ProcessingDialogState();
}

class _ProcessingDialogState extends State<ProcessingDialog> {
  @override
  void initState() {
    super.initState();
    widget.job.addListener(_onJobChanged);
  }

  @override
  void dispose() {
    widget.job.removeListener(_onJobChanged);
    super.dispose();
  }

  void _onJobChanged() {
    if (!mounted) return;
    if (widget.job.status == JobStatus.succeeded) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final failed = job.status == JobStatus.failed;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(failed ? 'Processing failed' : 'Processing'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!failed) ...[
              Text(job.stage, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: job.progress),
              const SizedBox(height: 14),
            ],
            if (failed) ...[
              Text(job.error ?? 'Unknown error',
                  style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
            ],
            Container(
              height: 150,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView(
                reverse: true,
                children: [
                  for (final line in job.log.reversed.take(60))
                    Text(
                      line,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (job.isRunning)
          TextButton(
            onPressed: () {
              job.cancel();
              Navigator.of(context).pop(false);
            },
            child: const Text('Cancel'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
      ],
    );
  }
}
