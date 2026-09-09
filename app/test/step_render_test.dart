import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/models/transcription.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/services/step_walker.dart';
import 'package:bass_trainer/widgets/fretboard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

/// Paints the fretboard while it is being stepped through, so the picture a
/// learner stares at can be looked at offline.
///
/// Set BASS_RENDER_OUT to choose where the files land.
void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  ({FretboardViewModel vm, StepWalker walker, PlaybackClock clock}) build() {
    final text = File('assets/sample/demo_transcription.json').readAsStringSync();
    final transcription = Transcription.parse(text, title: 'render');
    final timeline = NoteTimeline(transcription.notes);
    final clock = PlaybackClock()..duration = transcription.duration;
    final walker = StepWalker(timeline);
    final vm = FretboardViewModel(
      timeline: timeline,
      instrument: transcription.instrument,
      clock: clock,
    )..walker = walker;
    return (vm: vm, walker: walker, clock: clock);
  }

  Future<void> renderStep(String name, int index) async {
    final parts = build();
    parts.walker.start(0);
    parts.walker.jumpTo(index);
    parts.vm.advance(0);

    const size = Size(1180, 420);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF141210),
    );
    FretboardPainter(vm: parts.vm, fontFamily: 'Roboto').paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    expect(bytes, isNotNull, reason: 'the painter produced no image');
    expect(bytes!.lengthInBytes, greaterThan(2000),
        reason: 'image is suspiciously small — did anything draw?');

    if (outDir != null) {
      Directory(outDir).createSync(recursive: true);
      File('$outDir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    // Exactly one grip is being shown: that is what stepping means.
    expect(parts.vm.active.length, 1);
    expect(parts.vm.stepping, isTrue);
  }

  testWidgets('renders the first grip of the part', (tester) async {
    await tester.runAsync(() => renderStep('step_first', 0));
  });

  testWidgets('renders a grip in the middle of the riff', (tester) async {
    await tester.runAsync(() => renderStep('step_middle', 12));
  });

  test('the clock stays where it was; only the walker moves', () {
    final parts = build();
    parts.clock.seekTo(4.0);
    parts.walker.start(0);
    for (var i = 0; i < 5; i++) {
      parts.walker.next();
      parts.vm.advance(0.016);
    }
    // Stepping must not drag the audio around by itself — the screen seeks
    // deliberately, and the view model only reads.
    expect(parts.clock.position, 4.0);
    expect(parts.vm.time, parts.walker.note!.start);
  });

  test('the neck span does not change between playing and stepping', () {
    final parts = build();
    final span = parts.vm.spanFrets;
    parts.walker.start(0);
    for (final index in [0, 5, 40, 100]) {
      parts.walker.jumpTo(index);
      parts.vm.advance(0.016);
      expect(parts.vm.spanFrets, span,
          reason: 'a fret must sit in the same place in both modes');
    }
  });
}
