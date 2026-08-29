import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Preferences that outlive a session.
///
/// Stored as a small JSON file in the platform's per-user config directory
/// rather than through a plugin: it is a handful of scalars, and keeping it
/// dependency-free means no extra native build step.
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _fileName = 'settings.json';
  static const String _appFolder = 'bass_trainer';

  double _visualOffset = 0.0;
  bool _lowStringOnTop = false;
  bool _snapSeekToBars = true;
  double _inputOffset = 0.0;
  final Map<String, ({double bpm, double firstBeat})> _tempoOverrides = {};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Seconds to shift the fretboard against the audio. Positive draws it ahead.
  double get visualOffset => _visualOffset;

  bool get lowStringOnTop => _lowStringOnTop;

  /// Seeking lands on a bar line rather than an arbitrary instant.
  bool get snapSeekToBars => _snapSeekToBars;

  /// Extra seconds to subtract when judging what the microphone heard, on top
  /// of the capture buffer the listener already accounts for. Positive means
  /// the input arrives later than that estimate.
  double get inputOffset => _inputOffset;

  /// A tempo typed in by hand, keyed by transcription path. Kept here rather
  /// than rewritten into the track's JSON, so a manual tempo never risks the
  /// transcription itself.
  ({double bpm, double firstBeat})? tempoOverride(String key) =>
      _tempoOverrides[key];

  /// Set by tests so they never touch the real user config.
  @visibleForTesting
  static File? overrideFile;

  static File? settingsFile() {
    if (overrideFile != null) return overrideFile;
    final home = Platform.isWindows
        ? Platform.environment['APPDATA']
        : Platform.environment['XDG_CONFIG_HOME'] ??
            (Platform.environment['HOME'] == null
                ? null
                : p.join(Platform.environment['HOME']!, '.config'));
    if (home == null || home.isEmpty) return null;
    return File(p.join(home, _appFolder, _fileName));
  }

  Future<void> load() async {
    _loaded = true;
    final file = settingsFile();
    if (file == null || !file.existsSync()) return;
    try {
      final document = jsonDecode(await file.readAsString());
      if (document is! Map<String, dynamic>) return;
      _visualOffset = (document['visual_offset_sec'] as num?)?.toDouble() ?? 0.0;
      _lowStringOnTop = document['low_string_on_top'] as bool? ?? false;
      _snapSeekToBars = document['snap_seek_to_bars'] as bool? ?? true;
      _inputOffset = (document['input_offset_sec'] as num?)?.toDouble() ?? 0.0;
      _tempoOverrides.clear();
      final overrides = document['tempo_overrides'];
      if (overrides is Map) {
        overrides.forEach((key, value) {
          if (value is Map) {
            final bpm = (value['bpm'] as num?)?.toDouble();
            if (bpm != null && bpm > 0) {
              _tempoOverrides['$key'] = (
                bpm: bpm,
                firstBeat: (value['first_beat'] as num?)?.toDouble() ?? 0.0,
              );
            }
          }
        });
      }
      notifyListeners();
    } catch (_) {
      // A corrupt settings file must never stop the app starting.
    }
  }

  Future<void> setVisualOffset(double seconds) async {
    if (seconds == _visualOffset) return;
    _visualOffset = seconds;
    notifyListeners();
    await save();
  }

  Future<void> setLowStringOnTop(bool value) async {
    if (value == _lowStringOnTop) return;
    _lowStringOnTop = value;
    notifyListeners();
    await save();
  }

  Future<void> setInputOffset(double seconds) async {
    final clamped = seconds.clamp(-0.3, 0.3);
    if (clamped == _inputOffset) return;
    _inputOffset = clamped;
    notifyListeners();
    await save();
  }

  Future<void> setSnapSeekToBars(bool value) async {
    if (value == _snapSeekToBars) return;
    _snapSeekToBars = value;
    notifyListeners();
    await save();
  }

  Future<void> setTempoOverride(String key, double bpm, double firstBeat) async {
    _tempoOverrides[key] = (bpm: bpm, firstBeat: firstBeat);
    notifyListeners();
    await save();
  }

  Future<void> clearTempoOverride(String key) async {
    if (_tempoOverrides.remove(key) == null) return;
    notifyListeners();
    await save();
  }

  Future<void> save() async {
    final file = settingsFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'visual_offset_sec': double.parse(_visualOffset.toStringAsFixed(4)),
        'low_string_on_top': _lowStringOnTop,
        'snap_seek_to_bars': _snapSeekToBars,
        'input_offset_sec': double.parse(_inputOffset.toStringAsFixed(4)),
        'tempo_overrides': {
          for (final entry in _tempoOverrides.entries)
            entry.key: {
              'bpm': entry.value.bpm,
              'first_beat': entry.value.firstBeat,
            }
        },
      }));
    } catch (_) {
      // Read-only home directory, roaming profile issues: not worth crashing.
    }
  }

  /// Used by tests to get a clean slate without touching the real file.
  @visibleForTesting
  void resetForTest({double visualOffset = 0.0, bool lowStringOnTop = false}) {
    _visualOffset = visualOffset;
    _lowStringOnTop = lowStringOnTop;
    _snapSeekToBars = true;
    _inputOffset = 0.0;
    _tempoOverrides.clear();
    _loaded = false;
  }
}
