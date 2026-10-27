// Prepare a book for music, stage by stage, into a workspace directory.
//
//   dart run music_book ingest  <book.epub|book.txt> <workspace>
//   dart run music_book status  <workspace>
//   dart run music_book theme   <workspace> [--force]
//   dart run music_book scan    <workspace> [--through N]
//   dart run music_book cut     <workspace> [--min 50] [--max 100]
//   dart run music_book arcs    <workspace> [--merge 0.8] [--force]
//   dart run music_book tag     <workspace> --arc N
//   dart run music_book plan    <workspace> [--arc N] [--budget 32]
//   dart run music_book prepare <workspace> --arc N
//
// Model options, for every stage that asks one:
//   --ollama http://host:11434   --model qwen2.5:7b
//
// Then generate the beds with the Python side (framework/python):
//   python -m music_book_gen export <workspace> --arc N ...
//
// Every stage is resumable: run it again and it asks only for what is missing.

import 'dart:io';

import 'package:music_book_core/music_book_core.dart';
import 'package:path/path.dart' as p;

const usage = '''
usage: music_book <command> <workspace> [options]

  ingest <book.epub|book.txt> <workspace>   create a workspace from a book
  status   <workspace>                      what has been done so far
  theme    <workspace> [--force]            the book's musical theme
  scan     <workspace> [--through N]        score chapters for arc boundaries
  cut      <workspace> [--min 50 --max 100] cut the book into arcs
  arcs     <workspace> [--merge 0.8] [--force]
                                            each arc's theme; group alike arcs
  tag      <workspace> --arc N              mood-tag every paragraph of arc N
  plan     <workspace> [--arc N] [--budget 32]
                                            beds per cue, from what arcs sound like
  prepare  <workspace> --arc N              all of the above, for arc N
  pack     <workspace> <book.zip>           one file to carry to a phone
                                            (no jobs/, no raw takes)

model: --ollama <url> (default $defaultOllamaUrl) --model <name> (default $defaultOllamaModel)''';

String? _option(List<String> args, String name) {
  final at = args.indexOf(name);
  return at < 0 || at + 1 >= args.length ? null : args[at + 1];
}

int? _int(List<String> args, String name) =>
    int.tryParse(_option(args, name) ?? '');

double? _double(List<String> args, String name) =>
    double.tryParse(_option(args, name) ?? '');

/// Plain text has no navigation, so chapters are found by their headings:
/// a line that is "Chapter 12", "CHAPTER XII" or "Chapter 12: Title" on its
/// own. A text with none is one chapter.
List<({String title, String text})> chaptersOfText(String raw) {
  final heading = RegExp(r'^\s*chapter\s+([0-9]+|[ivxlcdm]+)\b.{0,80}$',
      caseSensitive: false);
  final chapters = <({String title, String text})>[];
  var title = '';
  final body = StringBuffer();
  void end() {
    if (body.toString().trim().isNotEmpty) {
      chapters.add((title: title, text: body.toString()));
    }
    body.clear();
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (heading.hasMatch(line)) {
      end();
      title = line.trim();
      continue;
    }
    body.writeln(line);
  }
  end();
  return chapters;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.writeln(usage);
    exit(args.isEmpty ? 64 : 0);
  }
  final command = args.first;

  if (command == 'ingest') {
    if (args.length < 3) {
      stderr.writeln(usage);
      exit(64);
    }
    final source = args[1];
    final Workspace ws;
    if (source.toLowerCase().endsWith('.epub')) {
      ws = await Workspace.fromEpub(args[2], await File(source).readAsBytes(),
          source: p.basename(source));
    } else {
      ws = await Workspace.create(args[2],
          title: p.basenameWithoutExtension(source),
          source: p.basename(source),
          chapters: chaptersOfText(await File(source).readAsString()));
    }
    stdout.writeln('${ws.bookId}  ${ws.title}: ${ws.info['chapters']} '
        'chapter(s), ${ws.info['paragraphs']} paragraph(s) -> '
        '${ws.directory.path}');
    return;
  }

  if (args.length < 2) {
    stderr.writeln(usage);
    exit(64);
  }
  final ws = await Workspace.open(args[1]);

  if (command == 'status') {
    await _status(ws);
    return;
  }
  if (command == 'pack') {
    if (args.length < 3) {
      stderr.writeln(usage);
      exit(64);
    }
    final count = await packWorkspace(ws, args[2]);
    final size = await File(args[2]).length();
    stdout.writeln('${args[2]}: $count file(s), '
        '${(size / 1048576).toStringAsFixed(1)} MB');
    return;
  }

  final backend = OllamaBackend(
    baseUrl: _option(args, '--ollama') ?? defaultOllamaUrl,
    model: _option(args, '--model') ?? defaultOllamaModel,
  );
  final pipeline = Pipeline(ws, Tagger(backend), log: stdout.writeln);
  final arc = _int(args, '--arc');
  try {
    switch (command) {
      case 'theme':
        await pipeline.themeBook(force: args.contains('--force'));
      case 'scan':
        await pipeline.scan(through: _int(args, '--through'));
      case 'cut':
        for (final a in await pipeline.cut(
            min: _int(args, '--min') ?? minArcChapters,
            max: _int(args, '--max') ?? maxArcChapters)) {
          stdout.writeln(a);
        }
      case 'arcs':
        for (final a in await pipeline.themeArcs(
            threshold: _double(args, '--merge') ?? defaultPaletteThreshold,
            force: args.contains('--force'))) {
          stdout.writeln(a);
        }
      case 'tag':
        if (arc == null) throw ArgumentError('tag needs --arc N');
        await pipeline.tagArc(arc);
      case 'plan':
        await pipeline.plan(
            arcIndex: arc, budget: _int(args, '--budget') ?? defaultBudget);
      case 'prepare':
        if (arc == null) throw ArgumentError('prepare needs --arc N');
        await pipeline.themeBook();
        await pipeline.scan();
        await pipeline.cut();
        await pipeline.themeArcs();
        await pipeline.tagArc(arc);
        await pipeline.plan(arcIndex: arc);
      default:
        stderr.writeln('unknown command: $command\n\n$usage');
        exit(64);
    }
  } on TaggingUnavailable catch (error) {
    stderr.writeln('model unavailable: ${error.message}');
    stderr.writeln('everything up to the failed batch is saved; run the same '
        'command again to resume');
    exit(69);
  } finally {
    backend.close();
  }
}

Future<void> _status(Workspace ws) async {
  final chapters = await ws.chapters();
  stdout.writeln('${ws.bookId}  ${ws.title}');
  stdout.writeln('  ${chapters.length} chapters, ${ws.info['paragraphs']} '
      'paragraphs');
  final theme = await ws.bookTheme();
  stdout.writeln('  theme: ${theme == null ? '-' : '${theme.theme.genreSeed} '
      '/ ${theme.theme.overallTheme}'}');
  stdout.writeln('  scanned: ${await ws.scannedThrough()}/${chapters.length}');
  final arcs = await ws.arcs();
  if (arcs == null) {
    stdout.writeln('  arcs: not cut');
    return;
  }
  final themes = await ws.arcThemes();
  final allocation = await ws.allocation();
  final planned = {
    for (final set in (allocation?['sets'] as List? ?? const []))
      ((set as Map)['palette'] as num).toInt(),
  };
  for (final arc in arcs) {
    var tagged = 0, total = 0;
    for (var at = arc.start; at <= arc.end; at++) {
      total += chapters[at].paragraphs.length;
      tagged += (await ws.tags(chapters[at])).length;
    }
    final beds = await File(p.join(ws.directory.path, arcDirectory(arc.palette),
            'manifest.json'))
        .exists();
    stdout.writeln('  arc ${arc.index.toString().padLeft(2)}  '
        'ch ${arc.start + 1}-${arc.end + 1}  '
        '${arc.palette == arc.index ? '' : 'plays ${arc.palette}  '}'
        'themed ${themes.containsKey(arc.index) ? 'yes' : 'no '}  '
        'tagged $tagged/$total  '
        'planned ${planned.contains(arc.palette) ? 'yes' : 'no '}  '
        'beds ${beds ? 'yes' : 'no'}  ${arc.title}');
  }
}
