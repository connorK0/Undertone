// Carrying a workspace to a device: what goes, what stays, and what a bad
// zip cannot do.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:music_book_core/music_book_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'scripted_backend.dart';

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('mb-'));
  tearDown(() async => temp.delete(recursive: true));

  Future<Workspace> prepared() async {
    final ws = await Workspace.create(p.join(temp.path, 'src'),
        title: 'Book', chapters: book());
    for (final name in [
      'arc-000/manifest.json',
      'arc-000/calm-0.wav',
      'arc-000/calm-0.raw.wav',
      'jobs/arc-000-1/beds/arc-000/calm-0-v7.wav',
      'themes.json.tmp',
    ]) {
      final file = File(p.join(ws.directory.path, name));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(name);
    }
    return ws;
  }

  test('what only preparation needs stays behind', () async {
    final ws = await prepared();
    final zip = p.join(temp.path, 'book.zip');
    await packWorkspace(ws, zip);
    final names = {
      for (final f in ZipDecoder().decodeBytes(File(zip).readAsBytesSync()))
        f.name,
    };
    expect(names, containsAll(
        ['workspace.json', 'chapters.json', 'arc-000/manifest.json',
         'arc-000/calm-0.wav']));
    expect(names.where((n) => n.startsWith('jobs/')), isEmpty);
    expect(names.where((n) => n.endsWith('.raw.wav')), isEmpty);
    expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
  });

  test('unpacking lands under the book id, and keeps the reader\'s place',
      () async {
    final ws = await prepared();
    final zip = p.join(temp.path, 'book.zip');
    await packWorkspace(ws, zip);
    final books = p.join(temp.path, 'books');

    final first = await unpackWorkspace(zip, books);
    expect(p.basename(first.directory.path), ws.bookId);
    expect((await first.chapters()).length, (await ws.chapters()).length);
    File(p.join(first.directory.path, 'reader.json'))
        .writeAsStringSync(jsonEncode({'chapter': 7, 'paragraph': 3}));

    // A newer pack of the same book -- another arc generated since.
    final again = await unpackWorkspace(zip, books);
    expect(
        jsonDecode(File(p.join(again.directory.path, 'reader.json'))
            .readAsStringSync()),
        {'chapter': 7, 'paragraph': 3});
    expect(Directory(books).listSync().map((e) => p.basename(e.path)),
        [ws.bookId], reason: 'no staging directory left behind');
  });

  test('a zip that is not a workspace replaces nothing', () async {
    final ws = await prepared();
    final zip = p.join(temp.path, 'book.zip');
    await packWorkspace(ws, zip);
    final books = p.join(temp.path, 'books');
    await unpackWorkspace(zip, books);

    final bogus = p.join(temp.path, 'bogus.zip');
    final encoder = ZipFileEncoder()..create(bogus);
    final stray = File(p.join(temp.path, 'notes.txt'))
      ..writeAsStringSync('not a book');
    await encoder.addFile(stray, 'notes.txt');
    await encoder.close();

    await expectLater(unpackWorkspace(bogus, books),
        throwsA(isA<WorkspaceException>()));
    expect(Directory(books).listSync().map((e) => p.basename(e.path)),
        [ws.bookId]);
  });
}
