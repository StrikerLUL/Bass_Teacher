import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/attachments.dart';
import '../services/fretboard_mapper.dart';

/// Picks where on the neck a part should be played, and keeps reference files
/// with the track.
///
/// The two belong together in practice: you open this because the app is
/// telling you a different string from the tab you are following.
class FingeringDialog extends StatefulWidget {
  const FingeringDialog({
    super.key,
    required this.style,
    required this.preferredFret,
    required this.trackDir,
  });

  final FingeringStyle style;
  final int? preferredFret;

  /// Null for the bundled demo, which has no folder to keep files in.
  final Directory? trackDir;

  @override
  State<FingeringDialog> createState() => _FingeringDialogState();
}

class FingeringChoice {
  const FingeringChoice(this.style, this.preferredFret);
  final FingeringStyle style;
  final int? preferredFret;
}

class _FingeringDialogState extends State<FingeringDialog> {
  late FingeringStyle _style = widget.style;
  late int? _fret = widget.preferredFret;
  List<Attachment> _files = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final dir = widget.trackDir;
    setState(() => _files = dir == null ? const [] : Attachments.list(dir));
  }

  Future<void> _addFile() async {
    final dir = widget.trackDir;
    if (dir == null) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: Attachments.allowedExtensions,
      dialogTitle: 'Add a tab, PDF or image',
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      await Attachments.add(dir, File(path));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add: $error')));
      }
    }
    if (mounted) setState(() => _busy = false);
    _refresh();
  }

  static const Map<FingeringStyle, (String, String)> _labels = {
    FingeringStyle.leastMovement: (
      'Least hand movement',
      'Comfortable, uses open strings, wanders across strings'
    ),
    FingeringStyle.oneString: (
      'Stay on one string',
      'What most tutorials teach: even tone, one shape'
    ),
    FingeringStyle.openPosition: (
      'Low on the neck',
      'Keeps to the first few frets and open strings'
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Fingering and reference'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A note lives in several places on a bass — E2 is string 2 '
                'fret 2, string 1 fret 7, or string 0 fret 12, all correct. '
                'If a video puts it somewhere else, neither of you is wrong; '
                'pick the style it is using.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              RadioGroup<FingeringStyle>(
                groupValue: _style,
                onChanged: (v) => setState(() => _style = v ?? _style),
                child: Column(
                  children: [
                    for (final entry in _labels.entries)
                      RadioListTile<FingeringStyle>(
                        value: entry.key,
                        title: Text(entry.value.$1),
                        subtitle: Text(entry.value.$2,
                            style: theme.textTheme.bodySmall),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(width: 110, child: Text('Around fret')),
                  Expanded(
                    child: Slider(
                      value: (_fret ?? 0).toDouble(),
                      max: 17,
                      divisions: 17,
                      label: _fret == null ? 'anywhere' : '$_fret',
                      onChanged: (v) => setState(() => _fret = v.round()),
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: Text(_fret == null ? 'anywhere' : 'fret $_fret',
                        textAlign: TextAlign.end),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() => _fret = null),
                  child: const Text('No preference'),
                ),
              ),
              const Divider(height: 26),
              Row(
                children: [
                  Text('Reference files', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed:
                        widget.trackDir == null || _busy ? null : _addFile,
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
              if (widget.trackDir == null)
                Text('The bundled demo has no folder to keep files in.',
                    style: theme.textTheme.bodySmall)
              else if (_files.isEmpty)
                Text(
                  'Add the tab you are following — PDF, image, Guitar Pro or '
                  'MIDI. It is copied into the track folder and opens in your '
                  'usual viewer.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final file in _files)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(file.isPdf
                        ? Icons.picture_as_pdf
                        : file.isImage
                            ? Icons.image
                            : Icons.description),
                    title: Text(file.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${file.extension}  ·  ${file.sizeLabel}'),
                    onTap: () async {
                      final ok = await Attachments.openExternally(file);
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Could not open that file.')),
                        );
                      }
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Remove',
                      onPressed: () async {
                        await Attachments.remove(file);
                        _refresh();
                      },
                    ),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, FingeringChoice(_style, _fret)),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Small helper so callers can name the folder a transcription came from.
Directory? trackDirectoryFor(String? transcriptionPath) =>
    transcriptionPath == null ? null : File(transcriptionPath).parent;

String describeStyle(FingeringStyle style) => switch (style) {
      FingeringStyle.leastMovement => 'least movement',
      FingeringStyle.oneString => 'one string',
      FingeringStyle.openPosition => 'low on the neck',
    };

String shortPath(String path) => p.basename(path);
