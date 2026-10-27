// The workspace and the pipeline, with a scripted model in place of a real
// one. What is under test is the bookkeeping -- what is asked, what is kept,
// what is asked again after a failure, what invalidates what -- not the
// model's judgement, which no test can pin.

import 'dart:convert';
import 'dart:io';

import 'package:music_book_core/music_book_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bin/music_book.dart' show chaptersOfText;
import 'scripted_backend.dart';

void main() {
  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('mb-'));
  tearDown(() async => temp.delete(recursive: true));

  group('workspace', () {
    test('ingest splits once, and the book id is the text', () async {
      final a = await Workspace.create(p.join(temp.path, 'a'),
          title: 'A', chapters: book());
      final b = await Workspace.create(p.join(temp.path, 'b'),
          title: 'Also A', chapters: book());
      final c = await Workspace.create(p.join(temp.path, 'c'),
          title: 'A', chapters: book(fights: {2}));
      expect(a.bookId, b.bookId, reason: 'same text, same book');
      expect(a.bookId, isNot(c.bookId), reason: 'different text');
      final chapters = await (await Workspace.open(a.directory.path))
          .chapters();
      expect(chapters, hasLength(12));
      expect(chapters.first.paragraphs, hasLength(3));
    });

    test('an existing workspace is not overwritten', () async {
      final dir = p.join(temp.path, 'a');
      await Workspace.create(dir, title: 'A', chapters: book());
      expect(() => Workspace.create(dir, title: 'A', chapters: book()),
          throwsA(isA<WorkspaceException>()));
    });

    test('tags written against other text are not served', () async {
      final ws = await Workspace.create(p.join(temp.path, 'a'),
          title: 'A', chapters: book());
      final chapter = (await ws.chapters()).first;
      await ws.putTags(chapter,
          {0: const MoodTag(mood: 'calm', intensity: 0.2, reason: '')});
      expect(await ws.tags(chapter), hasLength(1));
      final edited = WorkspaceChapter(
          index: 0, title: chapter.title, paragraphs: ['something else']);
      expect(await ws.tags(edited), isEmpty);
    });

    test('no temporary files are left behind', () async {
      final ws = await Workspace.create(p.join(temp.path, 'a'),
          title: 'A', chapters: book());
      await Pipeline(ws, Tagger(ScriptedBackend()), log: (_) {}).themeBook();
      final leftovers = ws.directory
          .listSync(recursive: true)
          .where((f) => f.path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });
  });

  group('pipeline', () {
    Future<(Workspace, ScriptedBackend, Pipeline)> fresh({
      Set<int> fights = const {},
    }) async {
      final ws = await Workspace.create(p.join(temp.path, 'book'),
          title: 'Book', chapters: book(fights: fights));
      final backend = ScriptedBackend();
      return (ws, backend, Pipeline(ws, Tagger(backend), log: (_) {}));
    }

    test('the book theme is asked once and cached against its sample',
        () async {
      final (_, backend, pipeline) = await fresh();
      await pipeline.themeBook();
      await pipeline.themeBook();
      expect(backend.asked.where((a) => a == 'theme'), hasLength(1));
      await pipeline.themeBook(force: true);
      expect(backend.asked.where((a) => a == 'theme'), hasLength(2));
    });

    test('a scan that fails part way keeps what it had and resumes', () async {
      final (ws, backend, pipeline) = await fresh();
      await pipeline.themeBook();
      backend.failOn = backend.calls + 2; // the second scan batch
      await expectLater(pipeline.scan(batch: 5),
          throwsA(isA<TaggingUnavailable>()));
      expect(await ws.scannedThrough(), 5);
      backend.failOn = null;
      final before = backend.asked.where((a) => a == 'scan').length;
      expect(await pipeline.scan(batch: 5), 12);
      // Chapters 5-9 and 10-11: two more calls, not three.
      expect(backend.asked.where((a) => a == 'scan').length - before, 2);
    });

    test('arcs are cut where the scan found a new storyline', () async {
      final (ws, _, pipeline) = await fresh();
      await pipeline.scan();
      final arcs = await pipeline.cut(min: 3, max: 8);
      expect([for (final a in arcs) (a.start, a.end)], [(0, 5), (6, 11)]);
      expect(arcs[1].title, 'situation 6');
      expect((await ws.arcs())!, hasLength(2));
    });

    test('arc themes lead with what happens, and alike arcs share beds',
        () async {
      final (ws, backend, pipeline) = await fresh();
      await pipeline.scan();
      await pipeline.cut(min: 3, max: 8);
      final arcs = await pipeline.themeArcs(threshold: 0.8);
      // The scripted model hears "sea" in arc 1's sample and nowhere else.
      final themes = await ws.arcThemes();
      expect(themes[0]!.theme.genreSeed, 'drama');
      expect(themes[1]!.theme.genreSeed, 'sea-epic');
      expect([for (final a in arcs) a.palette], [0, 1]);
      // Unchanged arcs are not re-themed.
      final asked = backend.asked.length;
      await pipeline.themeArcs(threshold: 0.8);
      expect(backend.asked.length, asked);
      // At a threshold of 0 everything is alike and shares arc 0's beds.
      final merged = await pipeline.themeArcs(threshold: 0);
      expect([for (final a in merged) a.palette], [0, 0]);
    });

    test('tagging an arc covers every paragraph and resumes', () async {
      final (ws, backend, pipeline) = await fresh(fights: {1, 2});
      await pipeline.scan();
      await pipeline.cut(min: 3, max: 8);
      backend.failOn = backend.calls + 2;
      await expectLater(pipeline.tagArc(0, batch: 2),
          throwsA(isA<TaggingUnavailable>()));
      backend.failOn = null;
      await pipeline.tagArc(0, batch: 2);
      final chapters = await ws.chapters();
      for (var c = 0; c <= 5; c++) {
        expect(await ws.tags(chapters[c]), hasLength(3), reason: 'ch $c');
      }
      expect((await ws.tags(chapters[1]))[1]!.mood, 'tense');
      expect(await ws.tags(chapters[6]), isEmpty, reason: 'arc 1 untouched');
    });

    test('the plan is allocate() over what the arc would sound like',
        () async {
      final (ws, _, pipeline) = await fresh(fights: {1, 2, 3});
      await pipeline.scan();
      await pipeline.cut(min: 3, max: 8);
      await pipeline.tagArc(0);
      final json = await pipeline.plan(arcIndex: 0, budget: 8);
      final set = (json['sets'] as List).single as Map<String, dynamic>;
      expect(set['palette'], 0);

      // Recompute it the long way, from the same tags, through the same
      // replay the reader app's allocate tool uses.
      final chapters = await ws.chapters();
      final perChapter = [
        for (var c = 0; c <= 5; c++)
          [
            for (final tag in (await ws.tags(chapters[c])).values)
              (mood: tag.mood, intensity: tag.intensity),
          ],
      ];
      final counted = histograms(contiguousRuns(perChapter));
      expect(set['allocation'],
          allocate(counted.sounding, budget: 8, floor: counted.tagged));
      // A set with no tags yet is left out rather than planned from nothing.
      final again = await pipeline.plan(budget: 8);
      expect([for (final s in again['sets'] as List) s['palette']], [0]);
      expect(jsonDecode(File(ws.path('allocation.json')).readAsStringSync()),
          again);
    });
  });

  test('plain text is chaptered by its headings', () {
    final chapters = chaptersOfText(
        'Front matter\n\nChapter 1\nOne.\n\nCHAPTER II: The Next\nTwo.\n');
    expect([for (final c in chapters) c.title],
        ['', 'Chapter 1', 'CHAPTER II: The Next']);
    expect(chaptersOfText('No headings here.\n\nAt all.'), hasLength(1));
  });
}
