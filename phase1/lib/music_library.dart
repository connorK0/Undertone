import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'arcs.dart';
import 'palette.dart';

/// Which set of loops to play.
///
/// [generated] is the default: eight beds written by tool/make_loops.py, exactly
/// seamless and all normalised to the same level. [licensed] is the CC0/CC-BY
/// set from OpenGameArt fetched by tool/fetch_licensed_loops.py -- real music,
/// but nothing on this machine could audition it, check where it loops, or
/// match its levels, so it is not what the app reaches for first. Switch to
/// compare them.
/// [experiment] is Phase 5 Task 0 scaffolding: four treatments of one
/// hand-written motif, keyed by intensity rather than by mood. It is not a
/// mood library at all and answers a single question -- see
/// lib/experiment_treatments.dart. Delete it with that file.
///
/// [perBook] is different in kind from the rest: its files are written by
/// tool/generate_beds.py per book, so they live on disk under the app's
/// support directory rather than in the asset bundle, and there is a different
/// set for every book. It is the only library whose beds actually differ
/// between books -- the other three are one set shared by everything, which is
/// why *Dracula* and *Alice* used to be byte-identical.
enum MusicLibrary { generated, licensed, experiment, perBook }

const activeLibrary = MusicLibrary.generated;

/// Where each mood's loop lives, read from the library's own manifest.
///
/// The manifest is the source of truth rather than a naming convention, because
/// the licensed files keep whatever extension they were published with and
/// carry attribution that has to travel with them.
class LoopLibrary {
  const LoopLibrary._(
    this.library,
    this.assets,
    this.variants,
    this.attributions,
    this.details,
    this.manifest, {
    this.banded = false,
    this.arcSize = 0,
    this.arc = 0,
  });

  final MusicLibrary library;

  /// Whether this set has a bed per mood *and intensity band* rather than one
  /// per mood. Read from what is on disk, never from a setting: a setting that
  /// could disagree with the files is a way to get silence.
  final bool banded;

  /// Chapters per arc, or 0 when one set covers the whole book.
  final int arcSize;

  /// Which arc's beds these are.
  final int arc;

  /// The cue a tag asks for: in the vocabulary this set speaks, and one it
  /// actually has.
  ///
  /// A 32-bed banded run takes about two hours and a per-arc run many more, so
  /// being stopped part way is the ordinary way to use them rather than an
  /// edge case -- and a set is banded as soon as *one* row carries a band, so
  /// a run stopped at bed 20 would otherwise ask for beds 21 to 32 and get
  /// silence. A missing cue falls back to the nearest band of **the same
  /// mood**, quieter side first, since a stiller bed under a fierce paragraph
  /// is a gentler failure than a fierce one under a still paragraph.
  ///
  /// Never to another mood. A calm bed under a tense scene is worse than
  /// silence, which is the rule [missing] already keeps.
  ///
  /// The rule itself is [resolveCue], so that the offline replay in
  /// `played.dart` can apply exactly the same one without importing this
  /// file, which reaches `dart:ui` and would stop a command-line tool
  /// compiling.
  String cueFor(String mood, double intensity) =>
      resolveCue(mood, intensity, banded: banded, has: assets.containsKey);

  /// mood -> asset key, ready for SoLoud's loadAsset. The cue's first bed;
  /// [variantsOf] is the whole of what it has.
  final Map<String, String> assets;

  /// cue -> every bed that cue owns, in variant order.
  ///
  /// A cue holds more than one when [allocate] gave it more than one, which it
  /// does for whatever the arc is mostly made of. Same prompt, different seeds:
  /// the point is not that they differ in character but that they differ at
  /// all, so a long stretch on one cue is not one file on repeat. The engine
  /// rotates through them each time it fades *into* the cue.
  final Map<String, List<String>> variants;

  /// Every bed for [cue], or an empty list if it has none.
  List<String> variantsOf(String cue) =>
      variants[cue] ?? [if (assets[cue] != null) assets[cue]!];

  /// How far apart two cues sound, relative to this set's own average change.
  ///
  /// Measured from the finished audio by `tool/bench_palette.py
  /// --write-distances`, because the engine cannot analyse audio while
  /// someone is reading -- and because the labels are a poor guide to it.
  /// §9.16 found a same-mood band change that sounds *larger* than a
  /// cross-mood one, so leading in on "the mood changed" would prepare for
  /// the wrong changes.
  ///
  /// 1.0 is this set's average change, so a threshold reads as "this much
  /// bigger than usual for this palette" rather than an absolute that would
  /// mean something different in every set. A set with no measurements
  /// reports exactly 1.0 for every pair, which is the safe answer: it sits
  /// below the lead-in threshold, so an unmeasured set behaves as it always
  /// did.
  ({double timbre, double chroma}) distanceBetween(String from, String to) {
    if (from == to) return (timbre: 0, chroma: 0);
    final table = manifest['distances'];
    if (table is! Map) return (timbre: 1, chroma: 1);
    // Written once per unordered pair, so ask for it the way it was written.
    final row = table[from.compareTo(to) <= 0 ? '$from|$to' : '$to|$from'];
    if (row is! Map) return (timbre: 1, chroma: 1);
    return (
      timbre: (row['timbre'] as num?)?.toDouble() ?? 1,
      chroma: (row['chroma'] as num?)?.toDouble() ?? 1,
    );
  }

  /// mood -> the credit line this file requires, for moods that require one.
  final Map<String, String> attributions;

  /// mood -> everything its manifest row records: how it was made, what it is
  /// meant to sound like, how seamless it measured. Each library chooses its
  /// own fields, so this is deliberately untyped -- the inspector shows
  /// whatever is there rather than a fixed set the manifests must supply.
  final Map<String, Map<String, dynamic>> details;

  /// The manifest's own top-level fields, minus the loops. Carries things that
  /// belong to the set rather than to one file -- the experiment library's
  /// motif, for instance.
  final Map<String, dynamic> manifest;

  /// Whether [assets] holds filesystem paths rather than asset-bundle keys.
  /// Generated beds are written per book at import, so they cannot be bundled.
  bool get fromFiles => library == MusicLibrary.perBook;

  /// Where a book's generated beds live: one directory per book under the
  /// app's support directory, written by tool/generate_beds.py --install.
  static Future<Directory> generatedRoot() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path,
          'generated'));

  /// Whether this book has a generated set. Books imported before generation
  /// existed do not, and must fall back rather than play nothing.
  static Future<bool> hasGenerated(String bookId) async {
    final root = p.join((await generatedRoot()).path, bookId);
    // Either shape counts: a whole-book set is a manifest in the book's own
    // directory, a per-arc set is a palette.json describing the arcs.
    return await File(p.join(root, 'manifest.json')).exists() ||
        await File(p.join(root, 'palette.json')).exists();
  }

  /// Where a book's beds for [chapter] live, and how the set is laid out.
  ///
  /// A set generated before arcs existed has no palette.json and is read as
  /// one arc covering everything, so nothing already on disk stops working.
  ///
  /// [pinned] names a set to play instead of the chapter's own -- see
  /// `MusicEngine.pinSet`. It applies only when that set exists; otherwise the
  /// book decides, as it always does.
  static Future<({String directory, int arcSize, int arc})> _resolve(
    String bookId,
    int chapter, {
    int? pinned,
  }) async =>
      resolveIn(p.join((await generatedRoot()).path, bookId), chapter,
          pinned: pinned);

  /// [_resolve] for a book directory given directly, so it can be tested on
  /// a temporary one rather than the reader's own.
  @visibleForTesting
  static Future<({String directory, int arcSize, int arc})> resolveIn(
    String root,
    int chapter, {
    int? pinned,
  }) async {
    final palette = File(p.join(root, 'palette.json'));
    if (!await palette.exists()) {
      return (directory: root, arcSize: 0, arc: 0);
    }
    final json =
        jsonDecode(await palette.readAsString()) as Map<String, dynamic>;
    final arcSize = (json['arc_size'] as num?)?.toInt() ?? 0;
    final arcs = (json['arcs'] as num?)?.toInt() ?? 1;

    // Explicit boundaries are the real thing: chapters grouped by where the
    // storyline turns, found by tool/arcs.dart. `arc_size` is the older
    // fixed-length scheme and is still honoured, because sets generated under
    // it are on disk and must keep playing.
    final boundaries = json['boundaries'];
    if (boundaries is List && boundaries.isNotEmpty) {
      final list = [
        for (final entry in boundaries)
          Arc.fromJson(entry as Map<String, dynamic>),
      ];
      // Clamped to what was actually generated, not to what was planned: the
      // whole workflow is generating one arc ahead of the reader, so the
      // boundary list routinely describes more arcs than exist on disk.
      final at = arcIndexFor(list, chapter);
      // The beds live under the arc that *represents* this one, which is
      // itself unless the theme pass found an earlier arc close enough to
      // share with. Clamped to what was generated, not to what was planned.
      final arc = at.clamp(0, list.length - 1);
      if (pinned != null) {
        final directory = p.join(root, arcDirectory(pinned));
        if (await File(p.join(directory, 'manifest.json')).exists()) {
          return (directory: directory, arcSize: 0, arc: arc);
        }
      }
      final palette = list[arc].palette.clamp(0, arcs - 1);
      return (
        directory: await _arcOrBook(root, palette),
        arcSize: 0,
        arc: arc,
      );
    }

    if (arcSize <= 0) return (directory: root, arcSize: 0, arc: 0);
    // Reading past the last arc that was generated plays the last one rather
    // than nothing: generation may have been stopped part way.
    final arc = arcOf(chapter, arcSize).clamp(0, arcs - 1);
    return (
      directory: await _arcOrBook(root, arc),
      arcSize: arcSize,
      arc: arc,
    );
  }

  /// This arc's beds, or the whole-book set if the arc has none yet.
  ///
  /// The just-in-time workflow means the reader is routinely ahead of
  /// generation -- and on the first run of a book, ahead of all of it. Without
  /// this, opening a book whose arc 0 has not been generated would fail to
  /// load a manifest and read in silence, and the whole-book set sitting in
  /// the same directory would never be touched again once any arc existed.
  ///
  /// So a whole-book set is the floor under a per-arc one rather than a thing
  /// it replaces: the book always sounds like itself, and an arc improves on
  /// it where one has been made.
  static Future<String> _arcOrBook(String root, int arc) async {
    final directory = p.join(root, arcDirectory(arc));
    if (await File(p.join(directory, 'manifest.json')).exists()) {
      return directory;
    }
    return root;
  }

  /// Which arc of [bookId] a chapter falls in, without loading anything. The
  /// engine uses it to notice that a chapter turn crossed a boundary.
  static Future<int> arcForChapter(String bookId, int chapter) async =>
      (await _resolve(bookId, chapter)).arc;

  /// Every per-arc set of [bookId] that is on disk, in order, each with the
  /// arcs that play it -- usually one, more where the theme pass let arcs
  /// share. Empty for a book with no per-arc sets. Ignores palette.json's
  /// `arcs` clamp on purpose: this is what could be listened to, not what the
  /// book would choose.
  static Future<List<({int set, List<Arc> arcs})>> generatedSets(
    String bookId,
  ) async =>
      setsIn(p.join((await generatedRoot()).path, bookId));

  /// [generatedSets] for a book directory given directly, for tests.
  @visibleForTesting
  static Future<List<({int set, List<Arc> arcs})>> setsIn(String root) async {
    final palette = File(p.join(root, 'palette.json'));
    if (!await palette.exists()) return const [];
    final json =
        jsonDecode(await palette.readAsString()) as Map<String, dynamic>;
    final boundaries = json['boundaries'];
    if (boundaries is! List) return const [];
    final bySet = <int, List<Arc>>{};
    for (final entry in boundaries) {
      final arc = Arc.fromJson(entry as Map<String, dynamic>);
      bySet.putIfAbsent(arc.palette, () => []).add(arc);
    }
    final found = <({int set, List<Arc> arcs})>[];
    for (final set in bySet.keys.toList()..sort()) {
      final manifest = File(p.join(root, arcDirectory(set), 'manifest.json'));
      if (await manifest.exists()) found.add((set: set, arcs: bySet[set]!));
    }
    return found;
  }

  /// Load a library. [bookId] is required for [MusicLibrary.perBook] and
  /// ignored otherwise; so is [pinned], a set to play in place of the
  /// chapter's own.
  static Future<LoopLibrary> load([
    MusicLibrary library = activeLibrary,
    AssetBundle? bundle,
    String? bookId,
    int chapter = 0,
    int? pinned,
  ]) async {
    if (library == MusicLibrary.perBook) {
      if (bookId == null) {
        throw ArgumentError('perBook needs a book id');
      }
      final where = await _resolve(bookId, chapter, pinned: pinned);
      return _loadFromDisk(where.directory,
          arcSize: where.arcSize, arc: where.arc);
    }
    final directory = switch (library) {
      MusicLibrary.generated => 'assets/music',
      MusicLibrary.licensed => 'assets/music/licensed',
      MusicLibrary.experiment => 'assets/music/experiment',
      MusicLibrary.perBook => throw StateError('handled above'),
    };
    final raw = await (bundle ?? rootBundle).loadString(
      '$directory/manifest.json',
    );
    final manifest = jsonDecode(raw) as Map<String, dynamic>;

    return fromManifest(library, manifest, directory);
  }

  /// A generated set, read from a directory rather than the asset bundle.
  static Future<LoopLibrary> _loadFromDisk(
    String directory, {
    int arcSize = 0,
    int arc = 0,
  }) async {
    final file = File(p.join(directory, 'manifest.json'));
    final manifest =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return fromManifest(MusicLibrary.perBook, manifest, directory,
        arcSize: arcSize, arc: arc);
  }

  /// A library from an already-parsed manifest.
  ///
  /// Both sources produce the same manifest shape, so they share this. The
  /// only difference is whether `directory` is an asset prefix or a real path,
  /// which is what [fromFiles] tells the engine. Public because it is the
  /// whole of what a manifest *means* -- which cues exist, whether the set is
  /// banded -- with none of the IO, so it can be exercised directly.
  static LoopLibrary fromManifest(
    MusicLibrary library,
    Map<String, dynamic> manifest,
    String directory, {
    int arcSize = 0,
    int arc = 0,
  }) {
    // Rows are grouped by cue and ordered by variant, so a manifest whose rows
    // arrived in any order still lays its beds down the same way -- the
    // rotation has to be reproducible or two runs of one book differ.
    final rows = <String, List<Map<String, dynamic>>>{};
    var banded = false;
    for (final entry in manifest['loops'] as List) {
      final loop = entry as Map<String, dynamic>;
      // A banded set names its own cues; a mood-keyed one is keyed by mood, as
      // every manifest written before bands existed still is.
      final cue = (loop['cue'] ?? loop['mood']) as String;
      if (loop['band'] != null) banded = true;
      rows.putIfAbsent(cue, () => []).add(loop);
    }

    final assets = <String, String>{};
    final variants = <String, List<String>>{};
    final attributions = <String, String>{};
    final details = <String, Map<String, dynamic>>{};
    for (final entry in rows.entries) {
      // A row with no `variant` is variant 0, which is what every manifest
      // written before variants existed says by saying nothing.
      final ordered = entry.value.toList()
        ..sort((a, b) => ((a['variant'] as num?) ?? 0)
            .compareTo((b['variant'] as num?) ?? 0));
      variants[entry.key] = [
        for (final loop in ordered)
          library == MusicLibrary.perBook
              ? p.join(directory, loop['file'] as String)
              : '$directory/${loop['file']}',
      ];
      assets[entry.key] = variants[entry.key]!.first;
      // The inspector shows one row per cue, so it shows the first: they share
      // a prompt, and it is the prompt the panel is there to explain.
      details[entry.key] = ordered.first;
      final loop = ordered.first;
      if (loop['attribution_required'] == true) {
        final author = loop['author'] ?? 'unknown';
        attributions[entry.key] =
            '${loop['title']} by $author (${loop['license']}) — ${loop['page']}';
      }
    }

    return LoopLibrary._(
      library,
      assets,
      variants,
      attributions,
      details,
      {
        for (final entry in manifest.entries)
          if (entry.key != 'loops') entry.key: entry.value,
      },
      banded: banded,
      arcSize: arcSize,
      arc: arc,
    );
  }

  /// Moods with no loop in this library. The engine plays nothing for these
  /// rather than substituting something that would be wrong.
  ///
  /// Judged by mood rather than by cue key, or a banded set would report every
  /// mood missing while holding four beds for each. [moodOf] only strips a
  /// *numeric* tail, so the experiment library's `treatment-a` is left alone.
  List<String> missing(Iterable<String> moods) {
    final have = assets.keys.map(moodOf).toSet();
    return [for (final mood in moods) if (!have.contains(mood)) mood];
  }
}
