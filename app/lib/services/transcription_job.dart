import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

enum JobStatus { idle, running, succeeded, failed }

/// Runs `backend/processor.py` on an audio file and reports progress.
///
/// The pipeline lives in Python because that is where Demucs and Basic Pitch
/// are; this drives it as a child process so a song can be added from inside
/// the app instead of from a terminal.
class TranscriptionJob extends ChangeNotifier {
  static const List<String> audioExtensions = [
    'mp3', 'wav', 'flac', 'm4a', 'ogg', 'opus', 'aac', 'wma',
  ];

  /// Interpreters to try, in order. Windows installs vary.
  static const List<String> _interpreters = ['python', 'py', 'python3'];

  JobStatus status = JobStatus.idle;
  String stage = '';
  double? progress; // 0..1 while Demucs reports a percentage, else null
  String? resultPath;
  String? error;
  final List<String> log = [];

  Process? _process;
  bool _cancelled = false;

  bool get isRunning => status == JobStatus.running;

  /// Finds `backend/processor.py` by walking up from the executable and the
  /// working directory, so it works both from `flutter run` and a built exe
  /// sitting in `build/windows/x64/runner/Debug`.
  static File? locateProcessor() {
    final seeds = <Directory>[
      File(Platform.resolvedExecutable).parent,
      Directory.current,
    ];
    for (final seed in seeds) {
      var dir = seed;
      for (var depth = 0; depth < 8; depth++) {
        final candidate = File(p.join(dir.path, 'backend', 'processor.py'));
        if (candidate.existsSync()) return candidate;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }

  Future<void> run({required String audioPath, bool preview = false}) async {
    final processor = locateProcessor();
    if (processor == null) {
      _fail('Could not find backend/processor.py. Expected it next to the '
          'project folder this app was built from.');
      return;
    }

    final backendDir = processor.parent;
    final dataDir = p.normalize(p.join(backendDir.parent.path, 'data'));

    status = JobStatus.running;
    stage = 'Starting Python…';
    progress = null;
    resultPath = null;
    error = null;
    _cancelled = false;
    log.clear();
    notifyListeners();

    final arguments = [
      processor.path,
      audioPath,
      '-o', dataDir,
      if (preview) ...['--preview', '30'],
    ];

    Object? lastLaunchError;
    for (final interpreter in _interpreters) {
      try {
        _process = await Process.start(
          interpreter,
          arguments,
          workingDirectory: backendDir.path,
        );
        lastLaunchError = null;
        break;
      } catch (e) {
        lastLaunchError = e;
      }
    }
    if (_process == null) {
      _fail('Could not start Python ($lastLaunchError). Make sure it is on '
          'your PATH.');
      return;
    }

    final streams = <Future<void>>[
      _consume(_process!.stdout),
      _consume(_process!.stderr),
    ];
    final code = await _process!.exitCode;
    await Future.wait(streams);
    _process = null;

    if (_cancelled) {
      _fail('Cancelled.');
    } else if (code == 0 && resultPath != null) {
      status = JobStatus.succeeded;
      stage = 'Done';
      progress = 1;
      notifyListeners();
    } else {
      _fail(error ?? 'Python exited with code $code. See the log below.');
    }
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  void _fail(String message) {
    status = JobStatus.failed;
    error = message;
    notifyListeners();
  }

  /// Demucs draws a progress bar with carriage returns rather than newlines,
  /// so split on both or the bar arrives as one blob at the end.
  Future<void> _consume(Stream<List<int>> raw) async {
    var buffer = '';
    await for (final chunk in raw.transform(utf8.decoder)) {
      buffer += chunk;
      final parts = buffer.split(RegExp(r'[\r\n]'));
      buffer = parts.removeLast();
      for (final line in parts) {
        if (line.trim().isNotEmpty) _onLine(line.trim());
      }
    }
    if (buffer.trim().isNotEmpty) _onLine(buffer.trim());
  }

  void _onLine(String line) {
    log.add(line);
    if (log.length > 300) log.removeRange(0, log.length - 300);

    if (line.contains('demucs:')) {
      stage = 'Separating the bass — this is the slow part';
      progress = null;
    } else if (line.contains('basic-pitch:')) {
      stage = 'Transcribing notes';
      progress = null;
    } else if (line.contains('octave fix')) {
      stage = 'Checking octaves against the stem';
    } else if (line.contains('clean-up:')) {
      stage = 'Cleaning up';
    } else if (line.startsWith('Separating track')) {
      stage = 'Separating the bass — this is the slow part';
    } else if (stage.startsWith('Separating')) {
      // Only trust a percentage while Demucs is the thing running.
      final match = RegExp(r'(\d{1,3})%').firstMatch(line);
      if (match != null) {
        progress = (int.parse(match.group(1)!) / 100).clamp(0.0, 1.0);
      }
    }

    final wrote = RegExp(r'wrote (.+transcription\.json)').firstMatch(line);
    if (wrote != null) resultPath = wrote.group(1)!.trim();

    final failed = RegExp(r'^error:\s*(.+)').firstMatch(line);
    if (failed != null) error = failed.group(1);

    notifyListeners();
  }
}
