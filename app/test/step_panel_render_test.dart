import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/models/instrument.dart';
import 'package:bass_trainer/models/note_event.dart';
import 'package:bass_trainer/models/tempo_grid.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/step_walker.dart';
import 'package:bass_trainer/widgets/step_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

/// Renders the step panel and checks it says what a learner needs to read.
///
/// The fretboard shows the grip; this says it in words, and the words are the
/// part you repeat to yourself while your hand finds the note.
void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  List<NoteEvent> part() => [
        NoteEvent(
            start: 0.0, end: 0.4, midi: 45, string: 1, fret: 7, hand: 5, finger: 3),
        NoteEvent(
            start: 0.5, end: 0.9, midi: 38, string: 2, fret: 0, hand: 5, finger: 0),
        NoteEvent(
            start: 1.0, end: 1.4, midi: 43, string: 1, fret: 5, hand: 5, finger: 1),
        NoteEvent(
            start: 1.5, end: 1.9, midi: 52, string: 3, fret: 9, hand: 9, finger: 1),
      ];

  Future<void> pumpPanel(WidgetTester tester, StepWalker walker) async {
    tester.view.physicalSize = const Size(1200, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFB300),
      brightness: Brightness.dark,
    );

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: StepPanel(
              walker: walker,
              instrument: Instrument.bassStandard,
              grid: TempoGrid.uniform(
                  bpm: 120, duration: 4, firstBeat: 0, beatsPerBar: 4),
              canAudition: true,
              onAudition: () {},
              onExit: () {},
              onChanged: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('names the string, the fret and the finger', (tester) async {
    final walker = StepWalker(NoteTimeline(part()))..start(0);
    await pumpPanel(tester, walker);

    expect(find.text('A string, fret 7'), findsOneWidget);
    expect(find.text('3 · ring'), findsOneWidget);
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('1 / 4'), findsOneWidget);
    // Fret 5 is where the hand sits for this phrase, not fret 7 where the
    // finger lands — they are different facts and both are shown.
    expect(find.text('fret 5'), findsOneWidget);
  });

  testWidgets('an open string asks for no finger at all', (tester) async {
    final walker = StepWalker(NoteTimeline(part()))..start(0);
    walker.jumpTo(1);
    await pumpPanel(tester, walker);

    expect(find.text('D string, open'), findsOneWidget);
    expect(find.text('none — open string'), findsOneWidget);
  });

  testWidgets('renders to a picture', (tester) async {
    final walker = StepWalker(NoteTimeline(part()))..start(0);
    await pumpPanel(tester, walker);

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final ui.Image image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      if (outDir != null) {
        Directory(outDir).createSync(recursive: true);
        File('$outDir/step_panel.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      }
    });
  });

  testWidgets('the buttons walk the part', (tester) async {
    final walker = StepWalker(NoteTimeline(part()))..start(0);
    await pumpPanel(tester, walker);

    await tester.tap(find.text('Next grip'));
    await tester.pumpAndSettle();
    expect(walker.step, 2);
    expect(find.text('2 / 4'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(walker.step, 1);
    // Nothing before the first grip: the button is disabled rather than a
    // no-op you have to discover by pressing it.
    final back = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Back'), matching: find.byType(FilledButton)),
    );
    expect(back.onPressed, isNull);
  });
}
