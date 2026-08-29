import 'dart:io';

import 'package:bass_trainer/services/attachments.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory track;
  late Directory source;

  setUp(() {
    track = Directory.systemTemp.createTempSync('bass_track');
    source = Directory.systemTemp.createTempSync('bass_src');
  });

  tearDown(() {
    for (final dir in [track, source]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  File make(String name, [String body = 'x']) =>
      File('${source.path}/$name')..writeAsStringSync(body);

  test('starts empty', () {
    expect(Attachments.list(track), isEmpty);
  });

  test('copies a file in and leaves the original alone', () async {
    final original = make('Seven Nation Army.pdf', 'pdf bytes');
    final added = await Attachments.add(track, original);

    expect(added.name, 'Seven Nation Army.pdf');
    expect(added.file.existsSync(), isTrue);
    expect(original.existsSync(), isTrue, reason: 'the source must not move');
    expect(Attachments.list(track).length, 1);
  });

  test('a second file with the same name does not overwrite the first', () async {
    await Attachments.add(track, make('tab.pdf', 'one'));
    final second = await Attachments.add(track, make('tab.pdf', 'two'));

    expect(second.name, 'tab (2).pdf');
    expect(Attachments.list(track).length, 2);
    // Two takes on the same song are not the same file.
    final bodies =
        Attachments.list(track).map((a) => a.file.readAsStringSync()).toSet();
    expect(bodies, {'one', 'two'});
  });

  test('identifies pdfs and images', () async {
    final pdf = await Attachments.add(track, make('a.pdf'));
    final png = await Attachments.add(track, make('b.PNG'));
    final other = await Attachments.add(track, make('c.gp5'));

    expect(pdf.isPdf, isTrue);
    expect(pdf.isImage, isFalse);
    expect(png.isImage, isTrue, reason: 'extension case must not matter');
    expect(other.isPdf, isFalse);
    expect(other.isImage, isFalse);
    expect(other.extension, 'GP5');
  });

  test('reports a readable size', () async {
    final added =
        await Attachments.add(track, make('big.pdf', 'y' * 5000));
    expect(added.sizeLabel, '5 KB');
  });

  test('removing deletes only that file', () async {
    await Attachments.add(track, make('keep.pdf'));
    final drop = await Attachments.add(track, make('drop.pdf'));
    await Attachments.remove(drop);

    final left = Attachments.list(track);
    expect(left.length, 1);
    expect(left.single.name, 'keep.pdf');
  });

  test('lives in the track folder so it travels with it', () async {
    await Attachments.add(track, make('tab.pdf'));
    expect(
      Attachments.folderFor(track).path,
      equals('${track.path}${Platform.pathSeparator}reference'),
    );
  });

  test('listing a track with no reference folder is empty, not an error', () {
    final bare = Directory.systemTemp.createTempSync('bass_bare');
    addTearDown(() => bare.deleteSync(recursive: true));
    expect(Attachments.list(bare), isEmpty);
  });
}
