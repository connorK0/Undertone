// Choosing which arc's beds to hear: the sets a book has, and a pin that
// plays one of them whatever chapter is open. On a temporary book directory,
// never the reader's own.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_shell/music_library.dart';

/// Three arcs, the third sharing the first's beds; sets on disk for the first
/// two. palette.json still says one arc is generated, as it does until the
/// book is told about the second.
Directory makeBook() {
  final root = Directory.systemTemp.createTempSync('pin-');
  File(p.join(root.path, 'palette.json')).writeAsStringSync(jsonEncode({
    'arcs': 1,
    'boundaries': [
      {'index': 0, 'start': 0, 'end': 9, 'title': 'first', 'palette': 0},
      {'index': 1, 'start': 10, 'end': 19, 'title': 'second', 'palette': 1},
      {'index': 2, 'start': 20, 'end': 29, 'title': 'third', 'palette': 0},
    ],
  }));
  for (final set in ['arc-000', 'arc-001']) {
    final dir = Directory(p.join(root.path, set))..createSync();
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync('{"loops": []}');
  }
  return root;
}

void main() {
  late Directory root;
  setUp(() => root = makeBook());
  tearDown(() => root.deleteSync(recursive: true));

  group('the sets a book has', () {
    test('every set on disk, with the arcs that play it', () async {
      final sets = await LoopLibrary.setsIn(root.path);
      expect([for (final s in sets) s.set], [0, 1]);
      expect([for (final a in sets[0].arcs) a.index], [0, 2]);
      expect([for (final a in sets[1].arcs) a.index], [1]);
    });

    test('a set that was never generated is not offered', () async {
      Directory(p.join(root.path, 'arc-001')).deleteSync(recursive: true);
      final sets = await LoopLibrary.setsIn(root.path);
      expect([for (final s in sets) s.set], [0]);
    });
  });

  group('a pinned set', () {
    test('unpinned, the book decides, clamped to what it says exists',
        () async {
      final where = await LoopLibrary.resolveIn(root.path, 15);
      expect(p.basename(where.directory), 'arc-000');
      expect(where.arc, 1);
    });

    test('pinned, the set plays under any chapter', () async {
      final early = await LoopLibrary.resolveIn(root.path, 5, pinned: 1);
      expect(p.basename(early.directory), 'arc-001');
      // Still the chapter's own arc: the pin changes the files, not where
      // the reader is.
      expect(early.arc, 0);
      final later = await LoopLibrary.resolveIn(root.path, 25, pinned: 1);
      expect(p.basename(later.directory), 'arc-001');
    });

    test('pinned to a set that is not on disk, the book decides', () async {
      final where = await LoopLibrary.resolveIn(root.path, 5, pinned: 7);
      expect(p.basename(where.directory), 'arc-000');
    });
  });
}
