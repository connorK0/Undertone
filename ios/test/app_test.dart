// The app end to end, headless: a real ScorePlayer with no audio device --
// the silent player it is designed to fall back to -- over a real workspace on
// disk. What cannot be tested here is the sound itself; what can is that the
// reader drives the score with the right position and the book's own tags.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_book_core/music_book_core.dart';
import 'package:music_book_player/music_book_player.dart';
import 'package:music_book_reader/library_screen.dart';
import 'package:music_book_reader/shelf.dart';
import 'package:path/path.dart' as p;

String para(String what) =>
    '$what. ${'The prose continues for long enough to be a paragraph. ' * 2}';

/// A three-chapter book with its first chapter tagged calm, a theme, and a
/// one-cue bed set -- everything a prepared book has, minus audio files the
/// silent player never opens.
Future<Workspace> preparedBook(Directory shelf) async {
  final ws = await Workspace.create(p.join(shelf.path, 'book'),
      title: 'Test Book',
      chapters: [
        for (var c = 1; c <= 3; c++)
          (
            title: 'Chapter $c',
            text: [for (var i = 1; i <= 3; i++) para('Chapter $c part $i')]
                .join('\n\n'),
          ),
      ]);
  await ws.putBookTheme(StoredTheme(
      BookTheme(
          overallTheme: 'Drama', instrumentation: 'strings', genreSeed: 'drama'),
      sample: 'x'));
  final first = (await ws.chapters()).first;
  await ws.putTags(first, {
    for (var i = 0; i < 3; i++)
      i: const MoodTag(mood: 'calm', intensity: 0.2, reason: ''),
  });
  File(ws.path('palette.json')).writeAsStringSync(jsonEncode({
    'arcs': 1,
    'boundaries': [
      {'index': 0, 'start': 0, 'end': 2, 'title': '', 'palette': 0},
    ],
  }));
  final manifest = File(p.join(ws.directory.path, 'arc-000', 'manifest.json'));
  manifest.parent.createSync();
  manifest.writeAsStringSync(jsonEncode({
    'loops': [
      {'cue': 'calm-0', 'mood': 'calm', 'band': 0, 'variant': 0,
       'file': 'calm-0.wav'},
    ],
  }));
  return ws;
}

class LoggingPlayer extends ScorePlayer {
  final calls = <String>[];

  @override
  Future<void> onPosition(int chapter, int paragraph) async {
    calls.add('$chapter:$paragraph start');
    await super.onPosition(chapter, paragraph);
    calls.add('$chapter:$paragraph -> ${lastDecision?.cue}');
  }
}

/// Let real file IO finish, then rebuild -- several rounds, because each
/// `await` on IO inside the widget resumes only when the test's fake clock
/// is pumped, and opening a book is several of them in a row.
Future<void> settleIo(WidgetTester tester) async {
  for (var round = 0; round < 8; round++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump();
  }
}

void main() {
  late Directory root;
  late Shelf shelf;
  late ScorePlayer player;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mbr-');
    shelf = Shelf(root);
    player = LoggingPlayer(); // never init()ed: no audio device
  });
  tearDown(() {
    // A test that fails mid-read can leave a file open, and Windows will not
    // delete it; a leftover temp folder is not worth masking that failure.
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // left for the OS to clean up
    }
  });

  testWidgets('the library lists a prepared book', (tester) async {
    await tester.runAsync(() => preparedBook(root));
    await tester.pumpWidget(
        MaterialApp(home: LibraryScreen(shelf: shelf, player: player)));
    await settleIo(tester);
    expect(find.text('Test Book'), findsOneWidget);
    expect(find.textContaining('with music'), findsOneWidget);
  });

  testWidgets('an empty library says how to get books', (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: LibraryScreen(shelf: shelf, player: player)));
    await settleIo(tester);
    expect(find.text('No books yet'), findsOneWidget);
  });

  test('a position becomes the set\'s cue, from the book\'s own tags',
      () async {
    final ws = await preparedBook(root);
    final score = ScorePlayer(); // no audio: decisions only
    await score.openBook(
      score: await BookScore.load(ws.directory.path),
      theme: (await ws.bookTheme())!.theme,
      tags: tagSourceFor(ws),
    );
    await score.onPosition(0, 0);
    expect(score.lastDecision?.cue, 'calm-0');
    expect(score.bedSet?.cues, {'calm-0'});
    // Chapter 2 was never tagged: no window, so nothing to decide -- and
    // nothing wrong played in its place.
    await score.onPosition(1, 0);
    expect(score.lastDecision, isNull);
  });

  test('a pack dropped into the folder is unpacked on refresh', () async {
    final source = Directory(p.join(root.path, '..',
        '${p.basename(root.path)}-src'))
      ..createSync();
    try {
      final ws = await preparedBook(source);
      await packWorkspace(ws, p.join(root.path, 'book.zip'));
      final books = await shelf.books();
      expect([for (final b in books) b.bookId], [ws.bookId]);
      expect(File(p.join(root.path, 'book.zip')).existsSync(), isFalse);
    } finally {
      source.deleteSync(recursive: true);
    }
  });

  testWidgets('reading drives the score and keeps the place', (tester) async {
    final ws = (await tester.runAsync(() => preparedBook(root)))!;
    await tester.pumpWidget(
        MaterialApp(home: LibraryScreen(shelf: shelf, player: player)));
    await settleIo(tester);

    await tester.tap(find.text('Test Book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the route
    await settleIo(tester); // the book opens
    await tester.pump(const Duration(milliseconds: 500)); // a settle
    await settleIo(tester); // position -> score, place -> disk
    await settleIo(tester);

    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.textContaining('Chapter 1 part 1'), findsOneWidget);
    // Silent, and saying why rather than showing nothing.
    expect(find.text('No audio device.'), findsOneWidget);
    // Opening reports where the eye is -- chapter 0, paragraph 0 -- to the
    // score. What the score makes of it is the next test's: the player's file
    // reads cannot finish under the widget tester's fake clock.
    expect((player as LoggingPlayer).calls, contains('0:0 start'));
    final place = jsonDecode(
        File(p.join(ws.directory.path, 'reader.json')).readAsStringSync());
    expect(place['chapter'], 0);

    await tester.tap(find.byTooltip('Next chapter'));
    await tester.pump();
    await settleIo(tester);
    expect(find.text('Chapter 2'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
  });
}
