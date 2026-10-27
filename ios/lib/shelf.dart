/// The books on this device, and how new ones arrive.
///
/// A phone cannot prepare a book -- there is no model to tag with and no GPU
/// for MusicGen -- so books are prepared on a computer with the framework's
/// command-line tools and carried over as a pack (`music_book pack`). Two ways
/// in, both ending in the same place:
///
///   * the import button, which opens the system file picker;
///   * dropping `book.zip` into this app's folder in the Files app (or in
///     Finder, over USB): the app's Documents folder is shared for exactly
///     that, and any pack found there is unpacked on the next refresh.
///
/// Every book is a workspace directory under Documents/, named by its book
/// id; FORMAT.md in the framework describes what is inside.
library;

import 'dart:convert';
import 'dart:io';

import 'package:music_book_core/music_book_core.dart';
import 'package:music_book_player/music_book_player.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Shelf {
  Shelf(this.root);

  /// Where the books live. Documents/, so the Files app can see it.
  final Directory root;

  static Future<Shelf> open() async =>
      Shelf(await getApplicationDocumentsDirectory());

  /// Every book on the shelf, after unpacking any pack dropped in since the
  /// last look. [problems] collects packs that would not open, which stay
  /// where they are so nothing the reader copied over is lost.
  Future<List<Workspace>> books({List<String>? problems}) async {
    await root.create(recursive: true);
    for (final entity in root.listSync()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.zip')) {
        continue;
      }
      try {
        await unpackWorkspace(entity.path, root.path);
        await entity.delete();
      } catch (error) {
        problems?.add('${p.basename(entity.path)}: $error');
      }
    }

    final found = <Workspace>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      if (!File(p.join(entity.path, 'workspace.json')).existsSync()) continue;
      try {
        found.add(await Workspace.open(entity.path));
      } catch (error) {
        problems?.add('${p.basename(entity.path)}: $error');
      }
    }
    found.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return found;
  }

  /// Unpack a pack chosen in the file picker.
  Future<Workspace> import(String zipPath) =>
      unpackWorkspace(zipPath, root.path);

  /// Remove a book and everything generated for it.
  Future<void> remove(Workspace ws) => ws.directory.delete(recursive: true);
}

/// Where the reader left a book: kept beside it, so it travels with the
/// workspace and survives a newer pack of the same book (see unpackWorkspace).
class ReadingPlace {
  const ReadingPlace(this.chapter, this.paragraph);

  final int chapter;
  final int paragraph;

  static Future<ReadingPlace> load(Workspace ws) async {
    final file = File(p.join(ws.directory.path, 'reader.json'));
    if (!await file.exists()) return const ReadingPlace(0, 0);
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ReadingPlace((json['chapter'] as num).toInt(),
          (json['paragraph'] as num).toInt());
    } catch (_) {
      return const ReadingPlace(0, 0);
    }
  }

  Future<void> save(Workspace ws) =>
      File(p.join(ws.directory.path, 'reader.json')).writeAsString(
          jsonEncode({'chapter': chapter, 'paragraph': paragraph}));
}

/// A book's tags as the player wants them: one per paragraph, null where the
/// book was never tagged, and nothing past the last chapter (which the
/// look-ahead reads as "no tags"). One function, used by the reader and by
/// the tests, so what is tested is what plays.
TagSource tagSourceFor(Workspace ws) {
  Future<List<WorkspaceChapter>>? chapters;
  return (int chapter) async {
    final all = await (chapters ??= ws.chapters());
    if (chapter < 0 || chapter >= all.length) return const [];
    final tags = await ws.tags(all[chapter]);
    return [
      for (var i = 0; i < all[chapter].paragraphs.length; i++) tags[i],
    ];
  };
}

/// Whether a book has any music generated for it yet.
bool hasMusic(Workspace ws) =>
    File(p.join(ws.directory.path, 'palette.json')).existsSync() ||
    File(p.join(ws.directory.path, 'manifest.json')).existsSync();
