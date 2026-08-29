import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/fretboard_mapper.dart';
import 'instrument.dart';
import 'note_event.dart';
import 'tempo_grid.dart';

/// A parsed `transcription.json` produced by `backend/processor.py`.
class Transcription {
  Transcription({
    required this.title,
    required this.instrument,
    required this.notes,
    required this.duration,
    this.bassStemPath,
    this.backingStemPath,
    this.stats = const {},
    this.tempo,
    this.sourcePath,
  });

  final String title;
  final Instrument instrument;

  /// Sorted by [NoteEvent.start].
  final List<NoteEvent> notes;

  final double duration;

  /// Absolute paths, or null when the stem is missing or was never rendered.
  final String? bassStemPath;
  final String? backingStemPath;

  final Map<String, dynamic> stats;

  /// Beat grid, when the backend found one.
  final TempoGrid? tempo;

  /// Where this was loaded from, used to key per-track settings.
  final String? sourcePath;

  bool get hasAudio => bassStemPath != null || backingStemPath != null;

  static Future<Transcription> load(File file) async {
    final text = await file.readAsString();
    return parse(
      text,
      baseDir: file.parent.path,
      title: p.basename(file.path),
      sourcePath: file.path,
    );
  }

  static Transcription parse(
    String jsonText, {
    String? baseDir,
    String? title,
    String? sourcePath,
  }) {
    final root = json.decode(jsonText);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('expected a JSON object at the top level');
    }

    final rawNotes = root['notes'];
    if (rawNotes is! List) {
      throw const FormatException('missing "notes" array');
    }

    final instrument = root['instrument'] is Map<String, dynamic>
        ? Instrument.fromJson(root['instrument'] as Map<String, dynamic>)
        : Instrument.bassStandard;

    final notes = rawNotes
        .whereType<Map<String, dynamic>>()
        .map(NoteEvent.fromJson)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    // Files written by hand or by another tool may carry pitches only. Work out
    // playable positions rather than refusing to render them.
    final mapper = FretboardMapper(instrument);
    if (notes.any((n) => n.string == null || n.fret == null)) {
      mapper.assign(notes);
    }
    if (notes.any((n) => n.hand == null)) {
      mapper.annotateHandPositions(notes);
    }
    if (notes.any((n) => n.finger == null && n.fret != null)) {
      mapper.assignFingers(notes);
    }

    final source = root['source'];
    final declared = source is Map<String, dynamic>
        ? (source['duration_sec'] as num?)?.toDouble()
        : null;
    final lastNote = notes.isEmpty
        ? 0.0
        : notes.map((n) => n.end).reduce((a, b) => a > b ? a : b);

    final stems = root['stems'];
    String? stem(String key) => stems is Map<String, dynamic>
        ? _resolveStem(stems[key], baseDir)
        : null;

    return Transcription(
      title: title ??
          (source is Map<String, dynamic> ? source['file']?.toString() : null) ??
          'Untitled',
      instrument: instrument,
      notes: notes,
      duration: declared ?? lastNote + 1.0,
      bassStemPath: stem('bass'),
      backingStemPath: stem('backing'),
      stats: root['stats'] is Map<String, dynamic>
          ? root['stats'] as Map<String, dynamic>
          : const {},
      sourcePath: sourcePath,
      tempo: TempoGrid.fromJson(
        root['tempo'] is Map<String, dynamic>
            ? root['tempo'] as Map<String, dynamic>
            : null,
        root['beats'] as List?,
      ),
    );
  }

  /// Stem paths are stored relative to the JSON so a track folder can be moved.
  /// A path that no longer resolves is dropped rather than failing the load —
  /// the visualiser still works without audio.
  static String? _resolveStem(dynamic value, String? baseDir) {
    if (value is! String || value.isEmpty) return null;
    final path = p.isAbsolute(value) || baseDir == null
        ? value
        : p.normalize(p.join(baseDir, value));
    return File(path).existsSync() ? path : null;
  }
}
