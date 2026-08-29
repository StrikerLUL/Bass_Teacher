import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads real Roboto faces from the Flutter SDK cache.
///
/// Without this the test renderer draws every glyph as a filled box, which
/// makes a rendered screenshot useless for judging a layout.
Future<void> loadTestFonts() async {
  var dir = File(Platform.resolvedExecutable).parent;
  Directory? fontDir;
  for (var up = 0; up < 6 && fontDir == null; up++) {
    final candidate = Directory('${dir.path}/artifacts/material_fonts');
    if (candidate.existsSync()) fontDir = candidate;
    dir = dir.parent;
  }
  expect(fontDir, isNotNull,
      reason: 'material fonts not found - text would render as boxes');

  final faces = fontDir!
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.ttf'))
      .where((f) => f.path.toLowerCase().contains('roboto'))
      .toList();
  expect(faces, isNotEmpty, reason: 'no Roboto faces in ${fontDir.path}');

  final loader = FontLoader('Roboto');
  for (final face in faces) {
    loader.addFont(Future.value(ByteData.view(face.readAsBytesSync().buffer)));
  }
  await loader.load();

  // Icons live in their own font; without it every icon renders as a box.
  final icons = fontDir
      .listSync()
      .whereType<File>()
      .firstWhere(
        (f) => f.path.toLowerCase().contains('materialicons'),
        orElse: () => File(''),
      );
  if (icons.path.isNotEmpty && icons.existsSync()) {
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)));
    await iconLoader.load();
  }
}
