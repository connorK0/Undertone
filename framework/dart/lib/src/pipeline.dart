/// Preparing a book for music, stage by stage, into its [Workspace].
///
///     themeBook   the book's musical character           -> themes.json
///     scan        how much each chapter starts a new arc  -> breaks.json
///     cut         where the arcs fall                     -> arcs.json
///     themeArcs   each arc's own character, and grouping -> themes.json, arcs.json
///     tagArc      mood + intensity of every paragraph     -> tags/
///     plan        how many beds each cue gets             -> allocation.json
///
/// then the Python side (framework/python) generates the beds into arc-NNN/.
///
/// The batch form of what the reader app's tools do -- tool/arcs.dart --scan,
/// tool/theme.dart --arcs, tool/allocate.dart --arc N -- in the same order,
/// with the same rules, and the same numbers: chapter digests, batch sizes,
/// the theme sample, the sounding-not-tagged allocation. What differs is only
/// where things are kept.
///
/// Every stage is resumable. Model calls are made in batches and each batch is
/// written before the next is asked for, so a stage stopped by a dead
/// endpoint, a closed laptop or Ctrl-C loses at most the batch in flight, and
/// running it again asks only for what is missing. A [TaggingUnavailable] is
/// rethrown after the batches before it are safe.
library;

import 'dart:math';

import 'allocation.dart';
import 'arcs.dart';
import 'book.dart';
import 'played.dart';
import 'tagging.dart';
import 'theme_similarity.dart';
import 'workspace.dart';

/// Paragraphs per tagging call. The reader's own batch is 6, sized for
/// latency because someone is waiting; nothing waits on this, and num_ctx is
/// 16384, so the limit is context rather than patience.
const paragraphBatch = 24;

/// How many chapters a book-level theme sample is spread across.
const themeSlices = 24;

/// A sample of a book (or an arc) for the theme pass: evenly spaced chapters,
/// the first and last always included, trimmed to fit [budget].
///
/// A book that fits entirely is not a sample, and stays byte-for-byte what it
/// is. Otherwise the ends of a book are where its register is most likely to
/// differ, so they are always in. The separators come out of the budget
/// rather than on top of it, because the prompt truncates at [maxThemeChars]
/// and anything over would silently cost the end of the last excerpt.
String themeSample(List<String> bodies, {int budget = maxThemeChars}) {
  if (bodies.isEmpty) return '';
  final total = bodies.fold<int>(0, (n, b) => n + b.length);
  if (total <= budget) return bodies.join('\n');

  const separator = '\n\n[...]\n\n';
  final slices = min(bodies.length, themeSlices);
  final each = (budget - separator.length * (slices - 1)) ~/ slices;
  final parts = <String>[];
  for (var i = 0; i < slices; i++) {
    final at =
        slices == 1 ? 0 : (i * (bodies.length - 1) / (slices - 1)).round();
    final body = bodies[at];
    parts.add(body.length <= each ? body : body.substring(0, each));
  }
  return parts.join(separator);
}

class Pipeline {
  Pipeline(this.workspace, this.tagger, {void Function(String)? log})
      : log = log ?? print;

  final Workspace workspace;
  final Tagger tagger;
  final void Function(String) log;

  String get _backend => tagger.backend.name;

  // --- The book's theme --------------------------------------------------

  /// The book's musical character: what arc scanning and paragraph tagging
  /// are both scored against. Cached against the sample it was read from.
  Future<BookTheme> themeBook({bool force = false}) async {
    final chapters = await workspace.chapters();
    final sample = themeSample([for (final c in chapters) c.body]);
    final digest = digestOf(sample);
    final stored = await workspace.bookTheme();
    if (stored != null && stored.sample == digest && !force) {
      return stored.theme;
    }
    final theme = await tagger.theme(Book(
      title: workspace.title,
      paragraphs: chapters.first.paragraphs,
      themeTextOverride: sample,
    ));
    await workspace.putBookTheme(
        StoredTheme(theme, sample: digest, backend: _backend));
    log('book theme: ${theme.genreSeed} / ${theme.overallTheme}');
    return theme;
  }

  Future<BookTheme> _requireBookTheme() async {
    final stored = await workspace.bookTheme();
    return stored?.theme ?? await themeBook();
  }

  // --- Arc boundaries ----------------------------------------------------

  /// Score chapters for arc boundaries, from the scan front up to [through]
  /// (default: the whole book). Returns how far the scan now reaches.
  ///
  /// A chapter the model did not echo still gets a row, scored 0 -- otherwise
  /// the contiguous front stalls on the hole and the batch is asked forever.
  /// A chapter that opens an author-declared division scores 1 regardless.
  Future<int> scan({int? through, int batch = arcScanBatch}) async {
    final theme = await _requireBookTheme();
    final chapters = await workspace.chapters();
    final target = min(through ?? chapters.length, chapters.length);
    var scanned = await workspace.scannedThrough();
    while (scanned < target) {
      final to = min(scanned + batch, target);
      final rows = chapters.sublist(scanned, to);
      final scored = await tagger.chapterBreaks(
        [for (final c in rows) (c.index, chapterDigest(c.title, c.body))],
        theme.overallTheme,
      );
      await workspace.putBreaks([
        for (final c in rows)
          () {
            final hard = isDivisionHeading(c.title, c.body);
            final got = scored[c.index];
            return ChapterBreak(
              index: c.index,
              score: hard ? 1 : (got?.score ?? 0),
              situation: got?.situation ?? '',
              hard: hard,
            );
          }(),
      ], backend: _backend);
      scanned = to;
      log('scanned $scanned/${chapters.length} chapters');
    }
    return scanned;
  }

  /// Cut the book into arcs from the scores so far. Pure arithmetic; no model
  /// calls. Past the scan front, boundaries are evenly spaced until the scan
  /// reaches them. Grouping is reset -- run [themeArcs] to group again.
  Future<List<Arc>> cut({
    int min = minArcChapters,
    int max = maxArcChapters,
  }) async {
    final chapters = await workspace.chapters();
    final arcs = chooseArcs((await workspace.breaks()).values.toList(),
        chapters.length,
        min: min, max: max);
    await workspace.putArcs(arcs,
        min: min, max: max, threshold: defaultPaletteThreshold);
    return arcs;
  }

  // --- Arc themes and grouping -------------------------------------------

  /// Each arc's own theme, and which arcs are alike enough to share beds.
  ///
  /// The sample leads with what the arc scan said happens in it -- measured
  /// on the test book, asking for a genre from prose alone gave "Orchestral
  /// with Electronic Elements" for arc after arc, because every arc *is* the
  /// same genre; the situations are what actually differ. Every theme is
  /// settled before any grouping, since grouping compares them.
  Future<List<Arc>> themeArcs({
    double threshold = defaultPaletteThreshold,
    bool force = false,
  }) async {
    final chapters = await workspace.chapters();
    final arcs = await workspace.arcs() ?? await cut();
    final breaks = await workspace.breaks();
    final stored = await workspace.arcThemes();
    final themes = <int, StoredTheme>{};

    for (final arc in arcs) {
      final bodies = [
        for (final c in chapters.sublist(arc.start, arc.end + 1)) c.body,
      ];
      final situations = <String>{
        for (var i = arc.start; i <= arc.end; i++)
          if (breaks[i]?.situation case final s? when s.isNotEmpty) s,
      }.take(14).join('; ');
      final preamble = situations.isEmpty
          ? ''
          : 'What happens in this section: $situations.\n\n';
      final sample = preamble +
          themeSample(bodies, budget: maxThemeChars - preamble.length);
      final digest = digestOf(sample);

      final have = stored[arc.index];
      if (have != null && have.sample == digest && !force) {
        themes[arc.index] = have;
        continue;
      }
      final theme = await tagger.theme(Book(
        title: 'arc ${arc.index}',
        paragraphs: chapters[arc.start].paragraphs,
        themeTextOverride: sample,
      ));
      themes[arc.index] = StoredTheme(theme, sample: digest, backend: _backend);
      // Saved as it goes: a theme pass over thirty arcs is minutes of model
      // time, and stopping at arc 20 must not cost the first nineteen.
      await workspace.putArcThemes({...stored, ...themes});
      log('arc ${arc.index} (ch ${arc.start + 1}-${arc.end + 1}): '
          '${theme.genreSeed} / ${theme.overallTheme}');
    }

    final palette = paletteFor([
      for (final arc in arcs)
        themes[arc.index] == null
            ? <String>{}
            : themeTokens(
                themes[arc.index]!.theme.genreSeed,
                themes[arc.index]!.theme.overallTheme,
                themes[arc.index]!.theme.instrumentation,
              ),
    ], threshold: threshold);
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
    final range = await workspace.arcRange();
    await workspace.putArcs(grouped,
        min: range?.min ?? minArcChapters,
        max: range?.max ?? maxArcChapters,
        threshold: threshold);
    return grouped;
  }

  // --- Paragraph tags ----------------------------------------------------

  /// Tag every paragraph of every chapter in [arcIndex], against the *book*
  /// theme -- as the reader app does, so a workspace's tags and the app's are
  /// asked the same question.
  ///
  /// Whole chapters, not a sample: allocation replays the tags through the
  /// real cue selector, and a scattered sample cannot be windowed.
  Future<void> tagArc(int arcIndex, {int batch = paragraphBatch}) async {
    final theme = await _requireBookTheme();
    final arcs = await workspace.arcs() ?? await cut();
    final arc = arcs.firstWhere((a) => a.index == arcIndex,
        orElse: () => throw ArgumentError('no arc $arcIndex'));
    final chapters = await workspace.chapters();
    var asked = 0;
    final started = DateTime.now();
    for (var at = arc.start; at <= arc.end; at++) {
      final chapter = chapters[at];
      final have = await workspace.tags(chapter);
      final missing = [
        for (var i = 0; i < chapter.paragraphs.length; i++)
          if (!have.containsKey(i)) i,
      ];
      for (var from = 0; from < missing.length; from += batch) {
        final ask = missing.sublist(from, min(from + batch, missing.length));
        final tagged = await tagger.paragraphs(
          [for (final i in ask) (i, chapter.paragraphs[i])],
          theme.overallTheme,
        );
        // Whatever came back is kept; anything the model did not echo is
        // still missing and a later run asks again.
        await workspace.putTags(chapter, tagged,
            backend: _backend, theme: theme.overallTheme);
        asked += ask.length;
      }
      if (missing.isNotEmpty) {
        final seconds = DateTime.now().difference(started).inSeconds;
        log('arc $arcIndex ch ${at + 1}: ${missing.length} tagged, '
            '$asked so far'
            '${seconds > 0 ? ', ${(asked / seconds).toStringAsFixed(2)}/s' : ''}');
      }
    }
  }

  /// One nullable tag per paragraph of every chapter of [arc], null where the
  /// model never answered -- the input [contiguousRuns] splits on.
  Future<List<List<({String mood, double intensity})?>>> _tagsOf(Arc arc)
  async {
    final chapters = await workspace.chapters();
    return [
      for (var at = arc.start; at <= arc.end; at++)
        await () async {
          final tags = await workspace.tags(chapters[at]);
          return [
            for (var i = 0; i < chapters[at].paragraphs.length; i++)
              if (tags[i] case final tag?)
                (mood: tag.mood, intensity: tag.intensity)
              else
                null,
          ];
        }(),
    ];
  }

  // --- Allocation --------------------------------------------------------

  /// How many beds each cue of each bed set gets, from what the set's arcs
  /// *sound* like -- the tags replayed through the real cue selector -- with
  /// every mood that is *tagged* guaranteed one bed (see [allocate]).
  ///
  /// Merged into allocation.json by set, so planning one arc keeps the plans
  /// made before it. Same shape as the reader app's allocation.json, which is
  /// what the generator reads. A set with no tags yet is left out.
  Future<Map<String, dynamic>> plan({
    int budget = defaultBudget,
    int? arcIndex,
  }) async {
    final arcs = await workspace.arcs() ?? await cut();
    final byPalette = <int, List<Arc>>{};
    for (final arc in arcs) {
      byPalette.putIfAbsent(arc.palette, () => []).add(arc);
    }
    final json = await workspace.allocation() ??
        {'book': workspace.bookId, 'budget': budget, 'sets': <Object>[]};
    final sets = {
      for (final raw in json['sets'] as List)
        ((raw as Map<String, dynamic>)['palette'] as num).toInt(): raw,
    };

    final wanted = arcIndex == null
        ? (byPalette.keys.toList()..sort())
        : [arcs.firstWhere((a) => a.index == arcIndex).palette];
    for (final palette in wanted) {
      final members = byPalette[palette] ?? const <Arc>[];
      final runs = <List<({String mood, double intensity})>>[];
      for (final arc in members) {
        runs.addAll(contiguousRuns(await _tagsOf(arc)));
      }
      final counted = histograms(runs);
      final observations = counted.sounding.values.fold(0, (a, b) => a + b);
      if (observations == 0) {
        log('set $palette: not tagged yet; run tag for arc '
            '${members.first.index}');
        continue;
      }
      final beds =
          allocate(counted.sounding, budget: budget, floor: counted.tagged);
      sets[palette] = {
        'palette': palette,
        'arcs': [for (final arc in members) arc.index],
        'chapters': [members.first.start, members.last.end],
        'observations': observations,
        'runs': runs.length,
        'changes': counted.changes,
        'tagged': counted.tagged,
        'sounding': counted.sounding,
        'allocation': beds,
      };
      log('set $palette: ${beds.length} cue(s), '
          '${beds.values.fold(0, (a, b) => a + b)} bed(s) from '
          '$observations paragraph(s)');
    }
    final ordered = sets.keys.toList()..sort();
    final out = {
      ...json,
      'budget': budget,
      'sets': [for (final k in ordered) sets[k]],
    };
    await workspace.putAllocation(out);
    return out;
  }
}
