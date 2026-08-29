import 'dart:io';
import 'dart:ui' as ui;

import 'package:bass_trainer/models/transcription.dart';
import 'package:bass_trainer/services/note_timeline.dart';
import 'package:bass_trainer/services/playback_clock.dart';
import 'package:bass_trainer/widgets/fretboard_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fonts.dart';

/// Renders the fretboard straight to a PNG so it can be inspected.
///
/// This paints the widget in isolation rather than capturing the screen: it
/// cannot pick up anything else on the desktop, and it produces the same image
/// on any machine.
///
/// Set BASS_RENDER_OUT to choose where the files land.
void main() {
  final outDir = Platform.environment['BASS_RENDER_OUT'];

  setUpAll(loadTestFonts);

  Future<void> renderAt(String name, double seconds, {bool flip = false}) async {
    final text = File('assets/sample/demo_transcription.json').readAsStringSync();
    final transcription = Transcription.parse(text, title: 'render');

    final clock = PlaybackClock()..duration = transcription.duration;
    clock.seekTo(seconds);

    final vm = FretboardViewModel(
      timeline: NoteTimeline(transcription.notes),
      instrument: transcription.instrument,
      clock: clock,
    )..lowStringOnTop = flip;
    vm.advance(0);

    const size = Size(1180, 420);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF141210),
    );
    FretboardPainter(vm: vm, fontFamily: 'Roboto').paint(canvas, size);
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

    // Sanity check the state the picture is meant to show.
    final active = vm.active;
    if (active.isNotEmpty) {
      expect(active.first.string, isNotNull);
      expect(active.first.fret, isNotNull);
    }
  }

  testWidgets('renders a note on the A string', (tester) async {
    await tester.runAsync(() => renderAt('neck_a_string', 0.02));
  });

  testWidgets('renders an octave note higher up the neck', (tester) async {
    await tester.runAsync(() => renderAt('neck_octave', 0.22));
  });

  testWidgets('renders an open string', (tester) async {
    await tester.runAsync(() => renderAt('neck_open', 1.62));
  });

  testWidgets('renders with the low string on top', (tester) async {
    await tester.runAsync(() => renderAt('neck_flipped', 0.02, flip: true));
  });

  test('the neck span is fixed, not scrolled', () {
    final text = File('assets/sample/demo_transcription.json').readAsStringSync();
    final transcription = Transcription.parse(text);
    final vm = FretboardViewModel(
      timeline: NoteTimeline(transcription.notes),
      instrument: transcription.instrument,
      clock: PlaybackClock(),
    );
    final span = vm.spanFrets;
    // Whatever happens during playback, the drawn range must not change —
    // that is the whole point of not scrolling.
    for (final t in [0.0, 1.0, 3.5, 7.0, 12.0]) {
      vm.clock.seekTo(t);
      vm.advance(0.016);
      expect(vm.spanFrets, span);
    }
    expect(span, greaterThanOrEqualTo(12));

    final highest = transcription.notes
        .map((n) => n.fret ?? 0)
        .reduce((a, b) => a > b ? a : b);
    expect(span, greaterThanOrEqualTo(highest),
        reason: 'every note in the song must be on screen');
  });
}
