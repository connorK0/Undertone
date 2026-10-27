// Find where a book's storyline turns, and cut it into arcs there.
//
//     dart run tool/arcs.dart --list
//     dart run tool/arcs.dart <bookId>                    # show the cut
//     dart run tool/arcs.dart <bookId> --scan             # score ahead
//     dart run tool/arcs.dart <bookId> --scan --through 200
//     dart run tool/arcs.dart <bookId> --min 50 --max 100 # re-cut, no model
//
// Two commands in one because they are two halves of one idea. `--scan` is the
// slow half: it asks the model how much of a fresh start each chapter is, and
// caches the answer per chapter. Everything else is the fast half, arithmetic
// over that cache -- so re-cutting a 2,364-chapter book with a different length
// range is instant and costs nothing.
//
// The scan is resumable and runs in reading order, which is the point: the
// reader starts on arc 0 while the rest of the book is still unscored.

import 'dart:io';

import 'package:reader_shell/arcs.dart';
import 'package:reader_shell/library.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/ollama_client.dart';

// The path is built here rather than taken from app_stores.dart, which imports
// path_provider -- and path_provider reaches dart:ui, so a command-line tool
// that imports it does not fail at the call, it fails to compile, with a page
// of errors out of Flutter's own gesture code. tool/theme.dart does the same,
// which is why that one kept working.
String get _appSupport =>
    '${Platform.environment['APPDATA']}\\com.example\\reader_shell';

int _flag(List<String> args, String name, int fallback) {
  final at = args.indexOf(name);
  if (at < 0 || at + 1 >= args.length) return fallback;
  return int.tryParse(args[at + 1]) ?? fallback;
}

Future<void> main(List<String> args) async {
  final scan = args.contains('--scan');
  final min = _flag(args, '--min', minArcChapters);
  final max = _flag(args, '--max', maxArcChapters);
  final through = _flag(args, '--through', 0);

  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (const {'--min', '--max', '--through'}.contains(args[i])) i++;
      continue;
    }
    positional.add(args[i]);
  }

  final library = await Library.at('$_appSupport\\library.db');
  final books = await library.entries();

  if (args.contains('--list') || positional.isEmpty) {
    for (final book in books) {
      final scanned = await library.scannedThrough(book.id);
      stdout.writeln('${book.id}  ${book.chapterCount.toString().padLeft(5)} ch'
          '  scanned ${scanned.toString().padLeft(5)}  ${book.title}');
    }
    await library.close();
    return;
  }

  final id = positional.first;
  final entry = books.where((b) => b.id == id).firstOrNull;
  if (entry == null) {
    stderr.writeln('no book $id; try --list');
    await library.close();
    exit(2);
  }

  if (scan) {
    await _scan(library, id, entry.chapterCount,
        through: through <= 0 ? entry.chapterCount : through);
  }

  final breaks = await library.chapterBreaks(id);
  final scanned = await library.scannedThrough(id);
  final arcs = chooseArcs(breaks, entry.chapterCount, min: min, max: max);

  stdout.writeln('\n${entry.title}');
  stdout.writeln('${entry.chapterCount} chapters, $scanned scored, '
      '${arcs.length} arc(s) at $min-$max chapters\n');
  for (final arc in arcs) {
    // An arc past the scan is a placeholder: chooseArcs had no scores out
    // there, so it cut at the earliest chapter it was allowed to. Saying so
    // matters -- those boundaries are arithmetic, not judgement.
    final settled = arc.end < scanned;
    stdout.writeln('  arc ${arc.index.toString().padLeft(3)}  '
        'ch ${(arc.start + 1).toString().padLeft(5)}-'
        '${(arc.end + 1).toString().padLeft(5)}  '
        '${arc.length.toString().padLeft(3)} ch  '
        '${settled ? ' ' : '?'} ${arc.title}');
  }
  if (arcs.any((a) => a.end >= scanned)) {
    stdout.writeln('\n? = past the scan; run --scan to settle these.');
  }

  await library.close();
}

/// Score chapters in reading order, resuming where the last run stopped.
Future<void> _scan(
  Library library,
  String id,
  int chapterCount, {
  required int through,
}) async {
  final chapter = await library.chapter(id, 0);
  final cache = await MoodCache.at('$_appSupport\\mood_cache.db');
  final theme = chapter == null ? null : await cache.theme(chapter.themeKey);
  await cache.close();
  if (theme == null) {
    stderr.writeln('no cached theme for $id; run tool/theme.dart $id first');
    exit(2);
  }

  final client = OllamaClient();
  var from = await library.scannedThrough(id);
  final target = through.clamp(0, chapterCount);
  if (from >= target) {
    stdout.writeln('already scored through $from');
    return;
  }
  stdout.writeln('scoring chapters $from-${target - 1} of $chapterCount '
      'in batches of $arcScanBatch...');

  final started = DateTime.now();
  while (from < target) {
    final to = (from + arcScanBatch).clamp(0, target);
    final rows = await library.chapterRange(id, from, to);
    if (rows.isEmpty) break;

    final digests = [
      for (final (index, title, body) in rows)
        (index, chapterDigest(title, body)),
    ];
    final Map<int, ChapterBreak> scored;
    try {
      scored = await client.chapterBreaks(digests, theme.overallTheme);
    } on OllamaUnavailable catch (error) {
      stderr.writeln('classifier unavailable: ${error.message}');
      stderr.writeln('scored through ${await library.scannedThrough(id)}; '
          'run again to resume');
      return;
    }

    // Every chapter in the batch gets a row, including ones the model did not
    // echo -- otherwise the contiguous scan front would stall on a hole and
    // the same batch would be retried forever. An absent score is 0, which is
    // exactly "no reason to cut here".
    final batch = [
      for (final (index, title, body) in rows)
        () {
          final hard = isDivisionHeading(title, body);
          final got = scored[index];
          return ChapterBreak(
            index: index,
            // A declared division is certain, so the model's guess cannot
            // lower it. It can however reach 1.0 on its own, and on this book
            // it did: chapter 1978 scored 1.0 as "End of Volume 13", because
            // chapter 1977 closes with an author's note saying the thirteenth
            // volume ends there. Only `hard` overrides a window outright.
            score: hard ? 1 : (got?.score ?? 0),
            situation: got?.situation ?? '',
            hard: hard,
          );
        }(),
    ];
    await library.putChapterBreaks(id, batch);

    final top = batch.reduce((a, b) => b.score > a.score ? b : a);
    stdout.writeln('  ${from.toString().padLeft(5)}-'
        '${(to - 1).toString().padLeft(5)}  '
        'top ${top.score.toStringAsFixed(2)} at ch ${top.index + 1}'
        '${top.hard ? ' (declared)' : ''}  ${top.situation}');
    from = to;
  }
  final took = DateTime.now().difference(started).inSeconds;
  stdout.writeln('scored to $from in ${took}s');
}
