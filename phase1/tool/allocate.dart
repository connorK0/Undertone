// Size an arc's bed set to what that arc actually sounds like.
//
//     dart run tool/allocate.dart --list
//     dart run tool/allocate.dart <bookId>                # plan, from the cache
//     dart run tool/allocate.dart <bookId> --arc 0         # classify it, then plan
//     dart run tool/allocate.dart <bookId> --arc 0 --write
//     dart run tool/allocate.dart <bookId> --next --write  # the next arc with no beds
//
// Step three of preparing an arc, between its theme and its beds:
//
//   1. tool/arcs.dart --scan      where the storyline turns
//   2. tool/theme.dart --arcs     this arc's own theme
//   3. tool/allocate.dart --arc N  <-- here
//   4. tool/generate_beds.py --arc N
//
// It classifies every paragraph of every chapter in the arc, into the reader's
// own mood cache under the reader's own keys, and then replays those tags
// through the real CueSelector to find what would actually *sound*. The bed set
// is sized against that.
//
// Whole chapters rather than a sample of paragraphs, because a scattered sample
// cannot be windowed and windowing is where the whole difference lives -- see
// lib/played.dart. Measured on this book, sizing by tags rather than by sound
// moves seven beds in thirty-two, and spends three of them on a mood that never
// once reaches the speakers.
//
// It pays for itself twice. Reading an arc that has been through this waits on
// no classifier at all, because every paragraph it would ask for is already
// cached -- which is the chapter-turn stall, gone.
//
// About 1.19 paragraphs a second, measured: a 66-chapter arc is roughly 40
// minutes, against about 1.8 hours to generate the same arc's beds. Resumable:
// anything already in the cache is not asked for again.

import 'dart:convert';
import 'dart:io';

import 'package:reader_shell/allocation.dart';
import 'package:reader_shell/arcs.dart';
import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/library.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:reader_shell/palette.dart';
import 'package:reader_shell/played.dart';

// See tool/arcs.dart: path_provider reaches dart:ui, so a command-line tool
// that imports app_stores.dart fails to compile rather than fails to run.
String get _appSupport =>
    '${Platform.environment['APPDATA']}\\com.example\\reader_shell';

/// Paragraphs per classifier call.
///
/// Larger than the reader's own batch of 6, which is sized for latency because
/// someone is waiting on it. Nothing waits on this, and num_ctx is 16384, so
/// the limit here is context rather than patience.
const paragraphBatch = 24;

int _flag(List<String> args, String name, int fallback) {
  final at = args.indexOf(name);
  if (at < 0 || at + 1 >= args.length) return fallback;
  return int.tryParse(args[at + 1]) ?? fallback;
}

Future<void> main(List<String> args) async {
  final write = args.contains('--write');
  final next = args.contains('--next');
  final budget = _flag(args, '--budget', defaultBudget);
  final arcWanted = _flag(args, '--arc', -1);
  final timeline = _flag(args, '--timeline', 0);
  final leads = args.contains('--leads');

  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      if (const {'--budget', '--arc', '--timeline'}.contains(args[i])) i++;
      continue;
    }
    positional.add(args[i]);
  }

  final library = await Library.at('$_appSupport\\library.db');
  final books = await library.entries();

  if (args.contains('--list') || positional.isEmpty) {
    for (final book in books) {
      stdout.writeln('${book.id}  ${book.chapterCount.toString().padLeft(5)} ch'
          '  ${book.title}');
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

  final root = Directory('$_appSupport\\generated\\$id');
  final arcs = await _arcsOf(root, entry);
  final cache = await MoodCache.at('$_appSupport\\mood_cache.db');

  if (leads) {
    await _leads(library, cache, id, root, arcs, arcWanted < 0 ? 0 : arcWanted);
    await cache.close();
    await library.close();
    return;
  }

  if (timeline > 0) {
    await _timeline(library, cache, id, root, arcs, timeline - 1);
    await cache.close();
    await library.close();
    return;
  }

  var arc = arcWanted;
  if (next) {
    arc = arcs
            .where((a) =>
                a.palette == a.index &&
                !File('${root.path}\\${arcDirectory(a.index)}\\manifest.json')
                    .existsSync())
            .map((a) => a.index)
            .firstOrNull ??
        -1;
    if (arc < 0) {
      stdout.writeln('every arc already has beds');
      await cache.close();
      await library.close();
      return;
    }
    stdout.writeln('next arc without beds: $arc');
  }

  if (arc >= 0) {
    final chosen = arcs.where((a) => a.index == arc).firstOrNull;
    if (chosen == null) {
      stderr.writeln('no arc $arc; the cut has ${arcs.length}');
      await cache.close();
      await library.close();
      exit(2);
    }
    final first = await library.chapter(id, chosen.start);
    final theme = first == null ? null : await cache.theme(first.themeKey);
    if (theme == null) {
      stderr.writeln('no cached theme for $id; run tool/theme.dart $id first');
      await cache.close();
      await library.close();
      exit(2);
    }
    await _classify(library, cache, id, chosen, theme.overallTheme);
  }

  await _plan(library, cache, id, entry, arcs, root,
      budget: budget, write: write, only: arc < 0 ? null : arc);
  await cache.close();
  await library.close();
}

/// The cut, or one arc covering the whole book if it has not been cut yet.
Future<List<Arc>> _arcsOf(Directory root, LibraryEntry entry) async {
  final file = File('${root.path}\\arcs.json');
  if (!await file.exists()) {
    return [
      Arc(index: 0, start: 0, end: entry.chapterCount - 1, title: entry.title),
    ];
  }
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  return [
    for (final raw in json['arcs'] as List)
      Arc.fromJson(raw as Map<String, dynamic>),
  ];
}

/// Classify every paragraph of every chapter in [arc], skipping what is cached.
Future<void> _classify(
  Library library,
  MoodCache cache,
  String id,
  Arc arc,
  String theme,
) async {
  final client = OllamaClient();
  final started = DateTime.now();
  var asked = 0;
  var chapters = 0;

  stdout.writeln('classifying arc ${arc.index}, chapters '
      '${arc.start + 1}-${arc.end + 1} (${arc.length} chapters)...');
  for (var at = arc.start; at <= arc.end; at++) {
    final book = await library.chapter(id, at);
    if (book == null) continue;
    final have = await cache.tags(book.key);
    final missing = [
      for (var i = 0; i < book.paragraphs.length; i++)
        if (!have.containsKey(i)) i,
    ];
    chapters++;
    if (missing.isEmpty) continue;

    for (var from = 0; from < missing.length; from += paragraphBatch) {
      final batch = missing.sublist(
          from, (from + paragraphBatch).clamp(0, missing.length));
      final Map<int, MoodTag> tagged;
      try {
        tagged = await client.paragraphs(
          [for (final i in batch) (i, book.paragraphs[i])],
          theme,
        );
      } on OllamaUnavailable catch (error) {
        stderr.writeln('classifier unavailable: ${error.message}');
        stderr.writeln('stopped at chapter ${at + 1}; run again to resume');
        return;
      }
      // Whatever came back is kept; anything the model did not echo is simply
      // still missing, and a later run asks for it again. Unlike the reader's
      // pipeline this is not a loop, so an index the model will never answer
      // for costs one retry per run rather than hanging.
      await cache.putTags(book.key, tagged);
      asked += batch.length;
    }
    final took = DateTime.now().difference(started).inSeconds;
    final rate = took == 0 ? 0.0 : asked / took;
    stdout.writeln('  ch ${(at + 1).toString().padLeft(5)}  '
        '${missing.length.toString().padLeft(3)} new  '
        '${asked.toString().padLeft(5)} done  '
        '${rate.toStringAsFixed(2)}/s', );
  }
  final took = DateTime.now().difference(started).inSeconds;
  stdout.writeln('$chapters chapter(s), $asked paragraph(s) in ${took}s\n');
}

/// The tags of one arc, as one contiguous run per unbroken stretch.
///
/// The splitting itself is [contiguousRuns], which is where the rule lives and
/// where it is tested. This is only the reading of it: one nullable entry per
/// paragraph of every chapter in the arc, null where the model never returned a
/// tag. A chapter that is missing outright reads as one long hole.
Future<List<List<({String mood, double intensity})>>> _runsOf(
  Library library,
  MoodCache cache,
  String id,
  Arc arc,
) async {
  final chapters = <List<({String mood, double intensity})?>>[];
  for (var at = arc.start; at <= arc.end; at++) {
    final book = await library.chapter(id, at);
    if (book == null) {
      chapters.add([null]);
      continue;
    }
    final tags = await cache.tags(book.key);
    chapters.add([
      for (var i = 0; i < book.paragraphs.length; i++)
        if (tags[i] case final tag?)
          (mood: tag.mood, intensity: tag.intensity)
        else
          null,
    ]);
  }
  return contiguousRuns(chapters);
}

/// The mood a cue belongs to: `tense-2` is `tense`, and an unbanded cue is
/// its own mood. Only a *numeric* tail is a band, so `treatment-a` is left
/// alone -- the same rule as LoopLibrary.moodOf.
String _moodOfCue(String cue) {
  final at = cue.lastIndexOf('-');
  if (at < 0) return cue;
  return int.tryParse(cue.substring(at + 1)) == null
      ? cue
      : cue.substring(0, at);
}

/// The cues a set has beds for, from its manifest -- what `MusicLibrary`
/// would key `assets` by. Read here rather than through it because that file
/// reaches `dart:ui` (see [_leads]).
Set<String> _bedsOf(Map<String, dynamic> manifest) => {
      for (final row in (manifest['loops'] as List? ?? const []))
        if (row is Map && row['cue'] is String) row['cue'] as String,
    };

/// How often the engine would lead into a change over a whole arc.
///
/// The threshold is the whole design: too low and the score is permanently
/// preparing for something, which is worse than the stark change it is meant
/// to soften; too high and it never fires. This replays the arc and counts,
/// against the same measured distances the engine reads.
///
/// Reads `distances` straight out of the manifest rather than through
/// [LoopLibrary], which cannot be imported here -- it reaches `path_provider`
/// and so `dart:ui`, and a command-line tool that imports it fails to compile.
Future<void> _leads(
  Library library,
  MoodCache cache,
  String id,
  Directory root,
  List<Arc> arcs,
  int index,
) async {
  final arc = arcs.where((a) => a.index == index).firstOrNull;
  if (arc == null) {
    stderr.writeln('no arc $index; the cut has ${arcs.length}');
    return;
  }
  final manifestFile =
      File('${root.path}\\${arcDirectory(arc.palette)}\\manifest.json');
  if (!await manifestFile.exists()) {
    stderr.writeln('arc $index has no beds yet, so nothing to measure against');
    return;
  }
  final manifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final table = manifest['distances'];
  if (table is! Map) {
    stderr.writeln('that set has no measured distances; run\n'
        '  python tool/bench_palette.py --write-distances '
        '${manifestFile.parent.path}');
    return;
  }
  ({double timbre, double chroma}) apart(String a, String b) {
    final row = table[a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a'];
    if (row is! Map) return (timbre: 1, chroma: 1);
    return (
      timbre: (row['timbre'] as num?)?.toDouble() ?? 1,
      chroma: (row['chroma'] as num?)?.toDouble() ?? 1,
    );
  }
  // Replay against the beds this set has, not the cues the tags ask for: the
  // engine resolves a missing cue to a neighbour, so a change the tags make
  // between two names it plays as one bed is not a change at all, and a pair
  // it cannot find in the table is a pair the engine never asks about.
  final beds = _bedsOf(manifest);

  final runs = await _runsOf(library, cache, id, arc);
  // Which dimension the score moves in. §9.16 finds the bands barely decide
  // how a bed *sounds*; this is whether they decide when the music *moves*,
  // which is the other half of what they cost.
  var bandStep = 0;
  var moodChange = 0;
  var changes = 0;
  var wouldLead = 0;
  var overlapped = 0;
  var paragraphs = 0;
  final starkest = <({String from, String to, double timbre, double chroma})>[];
  for (final run in runs) {
    paragraphs += run.length;
    String? last;
    for (final step in soundingSteps(run, beds: beds)) {
      if (!step.changed) continue;
      if (last != null) {
        changes++;
        if (_moodOfCue(last) == _moodOfCue(step.cue)) {
          bandStep++;
        } else {
          moodChange++;
        }
        final d = apart(last, step.cue);
        if (d.timbre >= leadThreshold) {
          wouldLead++;
          if (d.chroma <= leadChromaCeiling) overlapped++;
          starkest.add(
              (from: last, to: step.cue, timbre: d.timbre, chroma: d.chroma));
        }
      }
      last = step.cue;
    }
  }

  stdout.writeln('arc $index (ch ${arc.start + 1}-${arc.end + 1}), '
      '$paragraphs paragraphs, $changes cue change(s)\n');
  final stepPct = changes == 0 ? 0 : (100 * bandStep / changes).round();
  stdout.writeln('  a band step within one mood  $bandStep '
      '($stepPct% of changes)');
  stdout.writeln('  a change of mood             $moodChange');
  stdout.writeln('');
  stdout.writeln('  would lead in    $wouldLead '
      '(${(100 * wouldLead / (changes == 0 ? 1 : changes)).round()}% of '
      'changes, threshold ${leadThreshold}x)');
  stdout.writeln('  of those, with a second bed  $overlapped');
  stdout.writeln('  brightness sweep only        ${wouldLead - overlapped} '
      '(tonally further than ${leadChromaCeiling}x apart)');

  final counted = <String, int>{};
  for (final lead in starkest) {
    counted['${lead.from} -> ${lead.to}'] =
        (counted['${lead.from} -> ${lead.to}'] ?? 0) + 1;
  }
  final ranked = counted.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (ranked.isNotEmpty) stdout.writeln('\n  most often led into:');
  for (final entry in ranked.take(6)) {
    stdout.writeln('    ${entry.value.toString().padLeft(4)}x  ${entry.key}');
  }
}

/// The cue timeline for one chapter, replayed from the start of its arc.
///
/// Replaying the chapter on its own would be wrong for the same reason
/// `_runsOf` groups chapters into runs: reading is continuous, so the selector
/// arrives at a chapter already holding a cue and already part way through its
/// dwell. Starting it fresh at the chapter gives its opening cue a free commit
/// and a timeline that never happened.
Future<void> _timeline(
  Library library,
  MoodCache cache,
  String id,
  Directory root,
  List<Arc> arcs,
  int chapter,
) async {
  final arc =
      arcs.where((a) => chapter >= a.start && chapter <= a.end).firstOrNull ??
          arcs.first;
  final tags = <({String mood, double intensity})>[];
  var opens = 0;
  var holes = 0;
  for (var at = arc.start; at <= chapter; at++) {
    if (at == chapter) opens = tags.length;
    final book = await library.chapter(id, at);
    if (book == null) continue;
    final cached = await cache.tags(book.key);
    for (var i = 0; i < book.paragraphs.length; i++) {
      if (cached[i] case final tag?) {
        tags.add((mood: tag.mood, intensity: tag.intensity));
      } else {
        holes++;
      }
    }
  }

  // The same resolution as --leads, when the set exists. Before it does the
  // raw cue is the only one there is.
  final manifestFile =
      File('${root.path}\\${arcDirectory(arc.palette)}\\manifest.json');
  final beds = await manifestFile.exists()
      ? _bedsOf(jsonDecode(await manifestFile.readAsString())
          as Map<String, dynamic>)
      : null;

  const perParagraph = Duration(seconds: 40);
  final steps =
      soundingSteps(tags, perParagraph: perParagraph, beds: beds);
  String clock(int paragraphs) {
    final seconds = paragraphs * perParagraph.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2)}m'
        '${(seconds % 60).toString().padLeft(2, '0')}s';
  }

  stdout.writeln('chapter ${chapter + 1}, arc ${arc.index} '
      '(ch ${arc.start + 1}-${arc.end + 1})');
  stdout.writeln('replayed from chapter ${arc.start + 1}, because the selector '
      'carries across chapters');
  stdout.writeln('${tags.length} paragraphs to here'
      '${holes > 0 ? ', $holes unclassified and skipped' : ''}, '
      'reading at ${perParagraph.inSeconds}s a paragraph\n');

  final changes = steps.where((s) => s.changed).toList();
  final holding = changes.where((s) => s.paragraph < opens).lastOrNull;
  stdout.writeln('  the chapter opens on '
      '${holding?.cue ?? '(nothing committed yet)'}\n');

  stdout.writeln('  para      at   held for   cue');
  var previous = holding?.paragraph ?? 0;
  var inChapter = 0;
  for (final change in changes) {
    if (change.paragraph < opens) continue;
    inChapter++;
    stdout.writeln('  ${(change.paragraph - opens).toString().padLeft(4)}  '
        '${clock(change.paragraph - opens)}  '
        '${clock(change.paragraph - previous).padLeft(9)}   ${change.cue}');
    previous = change.paragraph;
  }

  final length = tags.length - opens;
  stdout.writeln('\n  $inChapter change(s) over $length paragraphs '
      '(${clock(length)} of reading)');
  if (inChapter > 0) {
    stdout.writeln('  one change every '
        '${clock((length / inChapter).round())} on average');
  }
}

/// One bed set per palette, sized to the arcs that play it.
Future<void> _plan(
  Library library,
  MoodCache cache,
  String id,
  LibraryEntry entry,
  List<Arc> arcs,
  Directory root, {
  required int budget,
  required bool write,
  int? only,
}) async {
  final byPalette = <int, List<Arc>>{};
  for (final arc in arcs) {
    byPalette.putIfAbsent(arc.palette, () => []).add(arc);
  }
  // One arc at a time is the workflow, so planning it must not throw away the
  // arcs planned before it: allocation.json is merged, never rewritten.
  final file = File('${root.path}\\allocation.json');
  final existing = <int, Map<String, dynamic>>{};
  if (await file.exists()) {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (final raw in (json['sets'] as List? ?? [])) {
      final set = raw as Map<String, dynamic>;
      // Sets written before allocation was sized by what sounds carry a
      // `histogram` and no `sounding`. They are not comparable and cannot be
      // merged into the whole-book total, so they are dropped rather than
      // crashing the merge or quietly skewing it. Re-run --arc N for them.
      if (set['sounding'] == null || set['tagged'] == null) continue;
      existing[(set['palette'] as num).toInt()] = set;
    }
  }

  final wanted = only == null
      ? byPalette.keys.toList()
      : [
          // An arc grouped onto an earlier one contributes to *that* set.
          arcs.where((a) => a.index == only).map((a) => a.palette).first,
        ];
  wanted.sort();

  stdout.writeln('${entry.title}: ${byPalette.length} bed set(s), '
      'budget $budget\n');
  for (final palette in wanted) {
    final members = byPalette[palette] ?? const <Arc>[];
    final runs = <List<({String mood, double intensity})>>[];
    for (final arc in members) {
      runs.addAll(await _runsOf(library, cache, id, arc));
    }
    final counted = histograms(runs);
    final observations = counted.sounding.values.fold(0, (a, b) => a + b);

    final label = members.map((a) => a.index).join(', ');
    stdout.writeln('set $palette  arc(s) $label  '
        'ch ${members.first.start + 1}-${members.last.end + 1}');
    if (observations == 0) {
      stdout.writeln('    not classified yet; run --arc ${members.first.index}');
      continue;
    }

    final plan = allocate(counted.sounding,
        budget: budget, floor: counted.tagged);
    existing[palette] = {
      'palette': palette,
      'arcs': [for (final arc in members) arc.index],
      'chapters': [members.first.start, members.last.end],
      'observations': observations,
      'runs': runs.length,
      'changes': counted.changes,
      'tagged': counted.tagged,
      'sounding': counted.sounding,
      'allocation': plan,
    };

    final tagTotal = counted.tagged.values.fold(0, (a, b) => a + b);
    stdout.writeln('    $observations paragraph(s) over ${runs.length} run(s), '
        '${counted.changes} cue change(s)');
    stdout.writeln('    cue              tagged   sounding   beds');
    final all = {...counted.tagged.keys, ...counted.sounding.keys}.toList()
      ..sort((a, b) =>
          (counted.sounding[b] ?? 0).compareTo(counted.sounding[a] ?? 0));
    for (final cue in all) {
      final tagged = counted.tagged[cue] ?? 0;
      final sounding = counted.sounding[cue] ?? 0;
      final beds = plan[cue] ?? 0;
      stdout.writeln('    ${cue.padRight(15)} '
          '${(100 * tagged / tagTotal).toStringAsFixed(1).padLeft(5)}%   '
          '${(100 * sounding / observations).toStringAsFixed(1).padLeft(5)}%   '
          '${beds == 0 ? ' .' : beds.toString().padLeft(2)}'
          '${beds > 0 ? '  ${'#' * beds}' : ''}');
    }
  }

  if (!write) {
    stdout.writeln('\n--write to save this for the generator.');
    return;
  }
  final sets = existing.keys.toList()..sort();
  // The whole-book set is the floor under the per-arc ones, so it is sized
  // against every arc that has been classified rather than against arc 0.
  final whole = <String, int>{};
  final wholeFloor = <String, int>{};
  for (final palette in sets) {
    for (final e in (existing[palette]!['sounding'] as Map).entries) {
      whole[e.key as String] =
          (whole[e.key as String] ?? 0) + (e.value as num).toInt();
    }
    for (final e in (existing[palette]!['tagged'] as Map).entries) {
      wholeFloor[e.key as String] =
          (wholeFloor[e.key as String] ?? 0) + (e.value as num).toInt();
    }
  }
  await root.create(recursive: true);
  await file.writeAsString('${jsonEncode({
        'book': id,
        'budget': budget,
        'whole': {
          'observations': whole.values.fold(0, (a, b) => a + b),
          'sounding': whole,
          'tagged': wholeFloor,
          'allocation': allocate(whole, budget: budget, floor: wholeFloor),
        },
        'sets': [for (final palette in sets) existing[palette]],
      })}\n');
  stdout.writeln('\nwrote ${file.path} (${sets.length} set(s))');
}
