import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'transcription_job.dart';

/// A processed track sitting in `data/`, summarised without loading its notes.
class LibraryEntry {
  LibraryEntry({
    required this.directory,
    required this.transcriptionFile,
    required this.title,
    required this.duration,
    required this.noteCount,
    required this.peakNotesPerSec,
    required this.maxFretJump,
    required this.hasBass,
    required this.hasBacking,
    required this.modified,
    this.engine,
    this.tuning,
  });

  final Directory directory;
  final File transcriptionFile;
  final String title;
  final double duration;
  final int noteCount;
  final double peakNotesPerSec;
  final int maxFretJump;
  final bool hasBass;
  final bool hasBacking;
  final DateTime modified;
  final String? engine;
  final String? tuning;

  String get folderName => p.basename(directory.path);
  bool get hasAudio => hasBass || hasBacking;

  /// Stems are what a re-transcribe reuses; without them it would have to run
  /// Demucs again, which is the slow part.
  bool get canRetranscribe => hasBass;
}

class Library {
  /// `data/` lives beside `backend/`, which is found relative to the running
  /// executable — same lookup the processing job uses.
  static Directory? dataDirectory() {
    final processor = TranscriptionJob.locateProcessor();
    if (processor == null) return null;
    return Directory(
      p.normalize(p.join(processor.parent.parent.path, 'data')),
    );
  }

  /// Every track in `data/`, newest first. Unreadable folders are skipped
  /// rather than failing the whole scan.
  static Future<List<LibraryEntry>> scan() async {
    final root = dataDirectory();
    if (root == null || !root.existsSync()) return const [];

    final entries = <LibraryEntry>[];
    for (final child in root.listSync().whereType<Directory>()) {
      final json = File(p.join(child.path, 'transcription.json'));
      if (!json.existsSync()) continue;
      try {
        entries.add(summarise(
          child,
          json,
          jsonDecode(await json.readAsString()) as Map<String, dynamic>,
        ));
      } catch (_) {
        // A half-written or hand-edited file should not hide the whole library.
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Build a summary from an already-decoded transcription document.
  ///
  /// Split out from the scan so it can be tested without a filesystem, and so
  /// a document missing `stats` still yields something sensible.
  static LibraryEntry summarise(
    Directory dir,
    File json,
    Map<String, dynamic> document, {
    DateTime? modified,
    bool? hasBass,
    bool? hasBacking,
  }) {
    final source = document['source'] as Map<String, dynamic>?;
    final stats = document['stats'] as Map<String, dynamic>?;
    final transcription = document['transcription'] as Map<String, dynamic>?;
    final instrument = document['instrument'] as Map<String, dynamic>?;
    final notes = document['notes'] as List?;

    final tuning = instrument?['tuning'];
    return LibraryEntry(
      directory: dir,
      transcriptionFile: json,
      title: (source?['file'] as String?) ?? p.basename(dir.path),
      duration: (source?['duration_sec'] as num?)?.toDouble() ?? 0,
      noteCount: (stats?['notes'] as num?)?.toInt() ?? notes?.length ?? 0,
      peakNotesPerSec:
          (stats?['peak_notes_per_sec'] as num?)?.toDouble() ?? 0,
      maxFretJump: (stats?['max_fret_jump'] as num?)?.toInt() ?? 0,
      hasBass: hasBass ?? File(p.join(dir.path, 'bass.wav')).existsSync(),
      hasBacking:
          hasBacking ?? File(p.join(dir.path, 'backing.wav')).existsSync(),
      modified: modified ?? json.statSync().modified,
      engine: transcription?['engine'] as String?,
      tuning: tuning is List ? tuning.join('-') : null,
    );
  }

  static Future<void> delete(LibraryEntry entry) async {
    if (entry.directory.existsSync()) {
      await entry.directory.delete(recursive: true);
    }
  }
}
