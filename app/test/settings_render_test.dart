import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/widgets/calibration_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

/// Renders the settings dialog in isolation so its layout can be inspected.
void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  testWidgets('settings dialog renders', (tester) async {
    tester.view.physicalSize = const Size(760, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final clock = PlaybackClock()..visualOffset = -0.12;
    addTearDown(clock.dispose);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFB300),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: RepaintBoundary(
        key: const ValueKey('capture'),
        child: Scaffold(body: SettingsDialog(clock: clock)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('behind the audio'), findsOneWidget);
    expect(find.text('Calibrate with a click'), findsOneWidget);

    if (outDir != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        final ui.Image image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(outDir).createSync(recursive: true);
        File('$outDir/settings.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
