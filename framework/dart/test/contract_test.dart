// The contract between the two halves: what the Dart pipeline writes, the
// Python generator reads.
//
// FORMAT.md describes the workspace; this proves it. The pipeline prepares a
// book with a scripted model, then the real music_book_gen.jobs.export_job --
// in Python, as a subprocess -- reads the workspace and must export exactly
// the set that was planned: every cue in the allocation, `overgen` takes each,
// from the arc's own theme, and not one word of the book.
//
// Needs a Python with numpy and soundfile: MUSIC_BOOK_PYTHON, or the reader
// app's venv beside this framework. Skipped, saying so, without one.

import 'dart:convert';
import 'dart:io';

import 'package:music_book_core/music_book_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'scripted_backend.dart';

String? _python() {
  final env = Platform.environment['MUSIC_BOOK_PYTHON'];
  if (env != null) return env;
  final venv = p.normalize(p.join(Directory.current.path, '..', '..',
      'phase1', '.venv', 'Scripts', 'python.exe'));
  return File(venv).existsSync() ? venv : null;
}

void main() {
  final python = _python();
  final gen = p.normalize(p.join(Directory.current.path, '..', 'python'));

  test('what the pipeline writes, the generator exports', () async {
    final temp = await Directory.systemTemp.createTemp('mb-');
    try {
      final ws = await Workspace.create(p.join(temp.path, 'book'),
          title: 'Book', chapters: book(fights: {1, 2, 3}));
      final pipeline = Pipeline(ws, Tagger(ScriptedBackend()), log: (_) {});
      await pipeline.scan();
      await pipeline.cut(min: 3, max: 8);
      await pipeline.themeArcs();
      await pipeline.tagArc(0);
      final plan = await pipeline.plan(arcIndex: 0, budget: 6);
      final allocation = ((plan['sets'] as List).single
          as Map<String, dynamic>)['allocation'] as Map<String, dynamic>;

      final result = await Process.run(python!, [
        '-c',
        'import json, sys\n'
            'sys.path.insert(0, sys.argv[1])\n'
            'from music_book_gen import jobs\n'
            'from music_book_gen.workspace import Workspace\n'
            'job = jobs.export_job(Workspace(sys.argv[2]), overgen=2)\n'
            'print(json.dumps(job))\n',
        gen,
        ws.directory.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final job = jsonDecode(result.stdout as String) as Map<String, dynamic>;

      expect(job['book'], ws.bookId);
      final sets = job['sets'] as List;
      expect([for (final s in sets) s['arc']], [0],
          reason: 'arc 1 has no plan and is not exported');
      final cues = (sets.single as Map<String, dynamic>)['cues'] as List;
      final perCue = <String, int>{};
      for (final cue in cues) {
        perCue[cue['cue'] as String] = (perCue[cue['cue']] ?? 0) + 1;
      }
      expect(perCue, {
        for (final entry in allocation.entries)
          entry.key: (entry.value as int) * 2,
      });
      final themes = await ws.arcThemes();
      expect((sets.single as Map)['theme']['genre_seed'],
          themes[0]!.theme.genreSeed);
      final text = result.stdout as String;
      for (final chapter in await ws.chapters()) {
        for (final paragraph in chapter.paragraphs) {
          expect(text.contains(paragraph.substring(0, 40)), isFalse,
              reason: 'book text in the job');
        }
      }
    } finally {
      await temp.delete(recursive: true);
    }
  },
      skip: python == null
          ? 'no Python: set MUSIC_BOOK_PYTHON to one with numpy and soundfile'
          : false);
}
