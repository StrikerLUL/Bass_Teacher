import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/services/loop_controller.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/widgets/loop_controls.dart';
import 'package:bass_trainer/widgets/loop_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  testWidgets('loop bar and controls render', (tester) async {
    tester.view.physicalSize = const Size(2000, 700); // logical 1000x350 at DPR 2
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final clock = PlaybackClock()..duration = 247;
    clock.seekTo(96);
    addTearDown(clock.dispose);

    final loop = LoopController()
      ..setRegion(72, 118)
      ..ramp = const SpeedRamp(enabled: true, from: 0.6, to: 1.0, steps: 5);
    loop.completePass();
    loop.completePass();
    addTearDown(loop.dispose);

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
        body: RepaintBoundary(
          key: const ValueKey('capture'),
          child: ColoredBox(
            color: const Color(0xFF1A1614),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LoopSeekBar(clock: clock, loop: loop, onSeek: (_) {}),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: LoopControls(
                    loop: loop,
                    clock: clock,
                    onMarkStart: () {},
                    onMarkEnd: () {},
                    onChanged: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('A 1:12'), findsOneWidget);
    expect(find.text('B 1:58'), findsOneWidget);
    expect(find.text('pass 3'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('60-100%'), findsOneWidget);

    if (outDir != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture')),
        );
        final ui.Image image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(outDir).createSync(recursive: true);
        File('$outDir/loop.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
