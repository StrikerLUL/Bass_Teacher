import 'dart:io';

import 'package:path/path.dart' as p;

/// A reference file kept with a track: a tab PDF, a screenshot, a photo of a
/// page in a book.
class Attachment {
  const Attachment(this.file);

  final File file;

  String get name => p.basename(file.path);
  String get extension => p.extension(file.path).replaceFirst('.', '').toUpperCase();
  int get bytes => file.existsSync() ? file.lengthSync() : 0;

  bool get isImage => const ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp']
      .contains(p.extension(file.path).toLowerCase());

  bool get isPdf => p.extension(file.path).toLowerCase() == '.pdf';

  String get sizeLabel {
    final size = bytes;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).round()} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Reference files stored beside a track's stems.
///
/// They live in the track folder rather than a central library so a track stays
/// self-contained: move or delete the folder and its tab goes with it.
class Attachments {
  static const List<String> allowedExtensions = [
    'pdf', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'txt', 'gp', 'gp3',
    'gp4', 'gp5', 'gpx', 'musicxml', 'xml', 'mid', 'midi',
  ];

  static Directory folderFor(Directory trackDir) =>
      Directory(p.join(trackDir.path, 'reference'));

  static List<Attachment> list(Directory trackDir) {
    final folder = folderFor(trackDir);
    if (!folder.existsSync()) return const [];
    final files = folder.listSync().whereType<File>().toList()
      ..sort((a, b) => p.basename(a.path).toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
    return [for (final file in files) Attachment(file)];
  }

  /// Copies [source] in, keeping the original where it is.
  ///
  /// A name clash gets a numeric suffix rather than overwriting: the two files
  /// may well be different takes on the same song.
  static Future<Attachment> add(Directory trackDir, File source) async {
    final folder = folderFor(trackDir);
    await folder.create(recursive: true);

    final base = p.basenameWithoutExtension(source.path);
    final ext = p.extension(source.path);
    var target = File(p.join(folder.path, '$base$ext'));
    var counter = 2;
    while (target.existsSync()) {
      target = File(p.join(folder.path, '$base ($counter)$ext'));
      counter++;
    }
    await source.copy(target.path);
    return Attachment(target);
  }

  static Future<void> remove(Attachment attachment) async {
    if (attachment.file.existsSync()) await attachment.file.delete();
  }

  /// Hands the file to whatever the desktop uses for it.
  ///
  /// Rendering a PDF in-app would mean another native plugin; opening it in the
  /// system viewer works today and puts the tab on a second screen, which is
  /// where it is wanted anyway.
  static Future<bool> openExternally(Attachment attachment) async {
    if (!attachment.file.existsSync()) return false;
    final path = attachment.file.absolute.path;
    try {
      if (Platform.isWindows) {
        // "start" needs an empty title argument first, or a quoted path is
        // taken as the window title.
        final result =
            await Process.run('cmd', ['/c', 'start', '', path], runInShell: true);
        return result.exitCode == 0;
      }
      if (Platform.isMacOS) {
        return (await Process.run('open', [path])).exitCode == 0;
      }
      return (await Process.run('xdg-open', [path])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
