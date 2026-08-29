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
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Seconds to shift the fretboard against the audio. Positive draws it ahead.
  double get visualOffset => _visualOffset;

  bool get lowStringOnTop => _lowStringOnTop;

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

  Future<void> save() async {
    final file = settingsFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'visual_offset_sec': double.parse(_visualOffset.toStringAsFixed(4)),
        'low_string_on_top': _lowStringOnTop,
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
    _loaded = false;
  }
}
