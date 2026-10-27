/// A generated set of beds on disk, and how a book finds the one for a
/// chapter.
///
/// The reader app's `LoopLibrary`, minus Flutter and minus the asset-bundle
/// libraries: the same manifest semantics (rows grouped by cue, variants in
/// order, banded if any row has a band, measured distances with 1.0 as
/// "unmeasured") and the same palette.json resolution (boundaries clamped to
/// what was generated, an arc with no beds of its own falling back to the
/// whole-book set). Pure Dart with dart:io, so a player on any platform, a
/// server, or a command-line check reads a set exactly as the app does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'arcs.dart';
import 'palette.dart';

class BedSet {
  BedSet._(this.directory, this.variants, this.rows, this.manifest,
      {required this.banded});

  /// A set from an already-parsed manifest; [directory] is where its files
  /// are. Public because it is the whole of what a manifest *means*, with
  /// none of the IO, so it can be exercised directly.
  factory BedSet.fromManifest(Map<String, dynamic> manifest, String directory) {
    // Grouped by cue and ordered by variant, so rows in any order lay their
    // beds down the same way -- the rotation has to be reproducible.
    final grouped = <String, List<Map<String, dynamic>>>{};
    var banded = false;
    for (final entry in manifest['loops'] as List) {
      final loop = entry as Map<String, dynamic>;
      final cue = (loop['cue'] ?? loop['mood']) as String;
      if (loop['band'] != null) banded = true;
      grouped.putIfAbsent(cue, () => []).add(loop);
    }
    final variants = <String, List<String>>{};
    final rows = <String, List<Map<String, dynamic>>>{};
    for (final entry in grouped.entries) {
      final ordered = entry.value.toList()
        ..sort((a, b) => ((a['variant'] as num?) ?? 0)
            .compareTo((b['variant'] as num?) ?? 0));
      rows[entry.key] = ordered;
      variants[entry.key] = [
        for (final loop in ordered) p.join(directory, loop['file'] as String),
      ];
    }
    return BedSet._(
      directory,
      variants,
      rows,
      {
        for (final entry in manifest.entries)
          if (entry.key != 'loops') entry.key: entry.value,
      },
      banded: banded,
    );
  }

  static Future<BedSet> load(String directory) async {
    final file = File(p.join(directory, 'manifest.json'));
    final manifest =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return BedSet.fromManifest(manifest, directory);
  }

  final String directory;

  /// Whether the set has a bed per mood *and band*. Read from what is on
  /// disk, never from a setting that could disagree with the files.
  final bool banded;

  /// cue -> every bed it owns, as file paths, in variant order.
  final Map<String, List<String>> variants;

  /// cue -> its manifest rows, in variant order: how each bed was made.
  final Map<String, List<Map<String, dynamic>>> rows;

  /// The manifest's own top-level fields, minus the loops.
  final Map<String, dynamic> manifest;

  Set<String> get cues => variants.keys.toSet();

  List<String> variantsOf(String cue) => variants[cue] ?? const [];

  /// The cue a tag gets from this set: what it asks for if the set has it,
  /// else the nearest band of the same mood, never another mood. The rule is
  /// [resolveCue], shared with the offline replay.
  String cueFor(String mood, double intensity) =>
      resolveCue(mood, intensity, banded: banded, has: variants.containsKey);

  /// How far apart two cues sound, relative to this set's average change
  /// (1.0). Written by the generator's measurement step; a set with none
  /// reports 1.0 for every pair, which sits below any lead-in threshold, so an
  /// unmeasured set simply never leads in.
  ({double timbre, double chroma}) distanceBetween(String from, String to) {
    if (from == to) return (timbre: 0, chroma: 0);
    final table = manifest['distances'];
    if (table is! Map) return (timbre: 1, chroma: 1);
    final row = table[from.compareTo(to) <= 0 ? '$from|$to' : '$to|$from'];
    if (row is! Map) return (timbre: 1, chroma: 1);
    return (
      timbre: (row['timbre'] as num?)?.toDouble() ?? 1,
      chroma: (row['chroma'] as num?)?.toDouble() ?? 1,
    );
  }

  /// Whether the set carries measured distances at all.
  bool get measured => manifest['distances'] is Map;
}

/// A book's generated music: which bed set plays under which chapter.
///
/// [root] is a workspace, or the reader app's `generated/<book>/` -- the same
/// layout. A root with no palette.json is one whole-book set.
class BookScore {
  BookScore._(this.root, this.boundaries, this.generated, this.arcSize);

  static Future<BookScore> load(String root) async {
    final file = File(p.join(root, 'palette.json'));
    if (!await file.exists()) return BookScore._(root, const [], 1, 0);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final boundaries = json['boundaries'];
    return BookScore._(
      root,
      boundaries is List
          ? [
              for (final b in boundaries)
                Arc.fromJson(b as Map<String, dynamic>),
            ]
          : const [],
      (json['arcs'] as num?)?.toInt() ?? 1,
      (json['arc_size'] as num?)?.toInt() ?? 0,
    );
  }

  final String root;

  /// Where the arcs fall, and which arc's beds each plays.
  final List<Arc> boundaries;

  /// How many arcs have been generated. Reading past them plays the last.
  final int generated;

  /// The older fixed-length scheme; 0 when [boundaries] are used.
  final int arcSize;

  final _sets = <String, Future<BedSet?>>{};

  /// Which arc a chapter is in.
  int arcForChapter(int chapter) {
    if (boundaries.isNotEmpty) {
      return arcIndexFor(boundaries, chapter).clamp(0, boundaries.length - 1);
    }
    return arcSize <= 0 ? 0 : arcOf(chapter, arcSize).clamp(0, generated - 1);
  }

  /// The directory whose beds play under [chapter]: the arc that represents
  /// this one, clamped to what was generated, or the whole-book set when that
  /// arc has no beds yet.
  Future<String> directoryFor(int chapter) async {
    final arc = arcForChapter(chapter);
    final palette = boundaries.isNotEmpty
        ? boundaries[arc].palette.clamp(0, generated - 1)
        : arc;
    final directory = p.join(root, arcDirectory(palette));
    if (await File(p.join(directory, 'manifest.json')).exists()) {
      return directory;
    }
    return root;
  }

  /// The bed set for [chapter], or null if nothing has been generated for
  /// it -- in which case a player plays nothing rather than something wrong.
  Future<BedSet?> setFor(int chapter) async {
    final directory = await directoryFor(chapter);
    return _sets[directory] ??= () async {
      if (!await File(p.join(directory, 'manifest.json')).exists()) {
        return null;
      }
      return BedSet.load(directory);
    }();
  }
}
