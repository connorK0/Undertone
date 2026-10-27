// Run the theme pass for a book already in the app's library, and cache it.
//
//     dart run tool/theme.dart --list
//     dart run tool/theme.dart <bookId>
//     dart run tool/theme.dart <bookId> --force
//     dart run tool/theme.dart <bookId> --arcs
//     dart run tool/theme.dart <bookId> --arcs --min 50 --max 100
//     dart run tool/theme.dart <bookId> --arcs --merge 0.8
//
// Why a Dart tool rather than a Python one, when everything else here is
// Python: the sample and the cache key come from Library and Book, and a
// second implementation of either in another language is a parity bug waiting
// to happen -- the theme key folds in a hash of the sample, so being one
// character out means the app re-themes and the beds describe something it
// never quotes. This runs the code the app runs.
//
// Needed because the music generator wants a theme before it can write a
// prompt, and a freshly imported 2,000-chapter book has none until someone
// opens it. Also the way to re-theme a book after the sampling changed.

import 'dart:convert';
import 'dart:io';

import 'package:reader_shell/arcs.dart';
import 'package:reader_shell/book.dart';
import 'package:reader_shell/library.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:reader_shell/theme_similarity.dart';

String get _appSupport =>
    '${Platform.environment['APPDATA']}\\com.example\\reader_shell';

double _decimal(List<String> args, String name, double fallback) {
  final at = args.indexOf(name);
  if (at < 0 || at + 1 >= args.length) return fallback;
  return double.tryParse(args[at + 1]) ?? fallback;
}

int _flag(List<String> args, String name, int fallback) {
  final at = args.indexOf(name);
  if (at < 0 || at + 1 >= args.length) return fallback;
  return int.tryParse(args[at + 1]) ?? fallback;
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final perArc = args.contains('--arcs');
  final min = _flag(args, '--min', minArcChapters);
  final max = _flag(args, '--max', maxArcChapters);
  final threshold = _decimal(args, '--merge', defaultPaletteThreshold);
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      // skip its value
      if (const {'--min', '--max', '--merge'}.contains(args[i])) i++;
      continue;
    }
    positional.add(args[i]);
  }

  final library = await Library.at('$_appSupport\\library.db');
  final cache = await MoodCache.at('$_appSupport\\mood_cache.db');

  final books = await library.entries();
  if (args.contains('--list') || positional.isEmpty) {
    for (final book in books) {
      final first = await library.chapter(book.id, 0);
      final theme = first == null ? null : await cache.theme(first.themeKey);
      stdout.writeln('${book.id}  ${book.chapterCount.toString().padLeft(5)} ch  '
          '${book.title}');
      stdout.writeln('    theme: ${theme == null ? '(none cached)' : ''
          '${theme.genreSeed} / ${theme.overallTheme}'}');
    }
    await library.close();
    await cache.close();
    return;
  }

  final id = positional.first;
  if (!books.any((b) => b.id == id)) {
    stderr.writeln('no book $id; try --list');
    exit(2);
  }

  if (perArc) {
    await _arcThemes(library, cache, id,
        force: force, min: min, max: max, threshold: threshold);
    await library.close();
    await cache.close();
    return;
  }

  // Chapter 0 carries the book-wide theme key and the book-wide sample, which
  // is the whole reason this asks for a chapter rather than a book.
  final chapter = await library.chapter(id, 0);
  if (chapter == null) {
    stderr.writeln('$id has no chapters');
    exit(2);
  }
  stdout.writeln('${chapter.title}  (book $id)');
  stdout.writeln('sample: ${chapter.themeText.length} chars, '
      '${'[...]'.allMatches(chapter.themeText).length + 1} excerpt(s) '
      'across the book');
  stdout.writeln('key:    ${chapter.themeKey}');

  final existing = await cache.theme(chapter.themeKey);
  if (existing != null && !force) {
    stdout.writeln('cached: ${existing.genreSeed} / ${existing.overallTheme}');
    stdout.writeln('        ${existing.instrumentation}');
    stdout.writeln('(--force to run it again)');
    await library.close();
    await cache.close();
    return;
  }

  stdout.writeln('asking $ollamaModel...');
  final started = DateTime.now();
  try {
    final theme = await OllamaClient().theme(chapter);
    final took = DateTime.now().difference(started).inMilliseconds / 1000;
    await cache.putTheme(chapter.themeKey, theme);
    stdout.writeln('${took.toStringAsFixed(1)}s');
    stdout.writeln('  genre:  ${theme.genreSeed}');
    stdout.writeln('  theme:  ${theme.overallTheme}');
    stdout.writeln('  instr:  ${theme.instrumentation}');
    stdout.writeln('cached under ${chapter.themeKey}');
  } on OllamaUnavailable catch (error) {
    stderr.writeln('classifier unavailable: ${error.message}');
    exit(1);
  } finally {
    await library.close();
    await cache.close();
  }
}

/// One theme per arc of the book, and which arcs can share a set of beds.
///
/// The point of arcs: a single theme for 2,364 chapters is the same complaint
/// that started all of this -- everything sounding alike -- one level up. An
/// arc is sampled exactly as a whole book is, through Library.themeSample, so
/// there is only ever one implementation of what a sample is.
///
/// Boundaries come from [chooseArcs] over whatever tool/arcs.dart has scored,
/// so they land where the storyline turns rather than on round numbers. A book
/// with nothing scored yet still gets arcs -- evenly spaced ones, because that
/// is what chooseArcs does with no scores -- which is what makes it safe to
/// theme and generate arc 0 before the scan has read the rest of the book.
///
/// Keys are `bookId#arcN`, and Book.themeKey folds a hash of the sample onto
/// that, so **re-cutting the book invalidates exactly the arcs whose chapters
/// changed** and leaves the others cached. That matters: the scan runs while
/// reading, so boundaries well ahead of the reader move as it learns more.
///
/// Every theme is settled before any grouping is done, because grouping is a
/// comparison between them and a half-filled list would group against the
/// wrong neighbours.
Future<void> _arcThemes(
  Library library,
  MoodCache cache,
  String id, {
  required bool force,
  required int min,
  required int max,
  required double threshold,
}) async {
  final chapters = await library.chapterBodies(id);
  final breaks = await library.chapterBreaks(id);
  final scanned = await library.scannedThrough(id);
  final arcs = chooseArcs(breaks, chapters.length, min: min, max: max);
  stdout.writeln('${chapters.length} chapters, $scanned scored, '
      '${arcs.length} arc(s) at $min-$max');
  if (scanned < chapters.length) {
    stdout.writeln('note: boundaries past chapter $scanned are evenly spaced '
        'until the scan reaches them (dart run tool/arcs.dart $id --scan)');
  }

  final client = OllamaClient();
  final themes = <BookTheme?>[];
  for (final arc in arcs) {
    final bodies = [
      for (final (_, body) in chapters.sublist(arc.start, arc.end + 1)) body,
    ];

    // What actually distinguishes one arc of this book from another.
    //
    // Measured, and it is the whole reason this exists: asked for a genre from
    // prose alone, 34 arcs of a cultivation serial came back as 25 distinct
    // instrumentations, eight of them the bare words "Orchestral with
    // Electronic Elements" -- because every arc genuinely *is* epic fantasy,
    // and the theme pass was being asked the one question whose answer never
    // changes. The arc scan already knows what changes: a one-line situation
    // per chapter ("an invasion", "an auction", "a death and a breakthrough").
    // Those cost nothing extra; they are sitting in chapter_breaks.
    final situations = <String>{
      for (final b in breaks)
        if (b.index >= arc.start && b.index <= arc.end && b.situation.isNotEmpty)
          b.situation,
    }.take(14).join('; ');
    final preamble = situations.isEmpty
        ? ''
        : 'What happens in this section: $situations.\n\n';
    // The preamble comes out of the sample's budget, not off the end of the
    // prompt, which truncates.
    final sample = preamble +
        Library.themeSample(bodies, budget: maxThemeChars - preamble.length);

    // A Book whose *theme* is this arc, so OllamaClient.theme reads the arc
    // and the key names it. The prose it carries is the arc's first chapter,
    // which nothing here looks at.
    final book = Book.fromText(
      'arc ${arc.index}',
      bodies.first,
      source: '$id#arc${arc.index}',
      themeKey: '$id#arc${arc.index}',
      themeText: sample,
    );

    final existing = await cache.theme(book.themeKey);
    if (existing != null && !force) {
      stdout.writeln('  arc ${arc.index}  ch ${arc.start + 1}-${arc.end + 1}  '
          '${existing.genreSeed} / ${existing.overallTheme}  (cached)');
      themes.add(existing);
      continue;
    }
    try {
      final started = DateTime.now();
      final theme = await client.theme(book);
      await cache.putTheme(book.themeKey, theme);
      final took = DateTime.now().difference(started).inMilliseconds / 1000;
      stdout.writeln('  arc ${arc.index}  ch ${arc.start + 1}-${arc.end + 1}  '
          '${took.toStringAsFixed(1)}s  '
          '${theme.genreSeed} / ${theme.overallTheme}');
      themes.add(theme);
    } on OllamaUnavailable catch (error) {
      stderr.writeln('  arc ${arc.index} failed: ${error.message}');
      return;
    }
  }

  // Which arcs are alike enough to share beds. An arc with no theme is left
  // representing itself rather than being merged on no evidence.
  final tokens = [
    for (final theme in themes)
      theme == null
          ? <String>{}
          : themeTokens(
              theme.genreSeed, theme.overallTheme, theme.instrumentation),
  ];
  final palette = paletteFor(tokens, threshold: threshold);
  final grouped = [
    for (var i = 0; i < arcs.length; i++)
      Arc(
        index: arcs[i].index,
        start: arcs[i].start,
        end: arcs[i].end,
        title: arcs[i].title,
        palette: palette[i],
      ),
  ];

  final sets = palette.toSet().length;
  stdout.writeln('\n${arcs.length} arc(s) -> $sets bed set(s) at threshold '
      '$threshold');
  for (var i = 0; i < grouped.length; i++) {
    if (grouped[i].palette == grouped[i].index) continue;
    stdout.writeln('  arc ${grouped[i].index} plays arc '
        '${grouped[i].palette}\'s beds  '
        '(${similarity(tokens[i], tokens[palette[i]]).toStringAsFixed(2)})');
  }
  if (sets < arcs.length) {
    final saved = (arcs.length - sets) * 32 * 3.4 / 60;
    stdout.writeln('saves about ${saved.toStringAsFixed(1)} h of generation '
        'at the full palette');
  }

  // The generator reads this rather than re-deriving the cut in Python. One
  // implementation of chooseArcs, and the handoff is a file.
  final root = Directory('$_appSupport\\generated\\$id');
  await root.create(recursive: true);
  await File('${root.path}\\arcs.json').writeAsString(
      '${jsonEncode({
        'book': id,
        'min': min,
        'max': max,
        'threshold': threshold,
        'scanned_through': scanned,
        'sets': sets,
        'arcs': [for (final arc in grouped) arc.toJson()],
      })}\n');
}
