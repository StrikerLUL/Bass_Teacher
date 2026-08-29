import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/screens/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

/// Renders the library screen to a PNG so the layout can be inspected.
///
/// It paints the widget tree in isolation - no screen capture, so it cannot
/// pick up anything else on the desktop.
void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  testWidgets('library screen renders', (tester) async {
    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB300),
      brightness: Brightness.dark,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: const RepaintBoundary(
          key: ValueKey('capture'),
          child: LibraryScreen(),
        ),
      ));
      // The scan is real file IO, so give it a moment rather than pumpAndSettle
      // (a progress spinner never settles).
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final ui.Image image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      if (outDir != null) {
        Directory(outDir).createSync(recursive: true);
        File('$outDir/library.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      }
    });

    // The add card is always present, whatever the data folder holds.
    expect(find.text('Add a song'), findsOneWidget);
  });
}
