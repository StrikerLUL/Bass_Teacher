import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/models/tempo_grid.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/widgets/beat_ruler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  testWidgets('beat ruler renders bars and beats', (tester) async {
    tester.view.physicalSize = const Size(900, 90);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    // 172.3 bpm, the tempo measured on Cagayake! GIRLS.
    final grid = TempoGrid.uniform(bpm: 172.3, duration: 60, firstBeat: 0.12);
    final clock = PlaybackClock()..duration = 60;
    clock.seekTo(11.4);
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
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            // The ruler's background is translucent by design; without an
            // opaque backdrop the capture composites over nothing and cannot
            // be judged.
            child: ColoredBox(
              color: const Color(0xFF1A1614),
              child: BeatRuler(
                grid: grid,
                clock: clock,
                height: 56,
                fontFamily: 'Roboto',
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    if (outDir != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        final ui.Image image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(outDir).createSync(recursive: true);
        File('$outDir/ruler.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    // Four beats to a bar at 172.3 bpm is a bar every ~1.4s, so a 4s window
    // must contain at least two bar lines.
    expect(grid.beatsBetween(9.4, 13.4).length, greaterThan(8));
  });
}
