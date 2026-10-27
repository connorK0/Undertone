/// A book workspace: one directory holding everything the pipeline knows about
/// one book, as plain JSON a host can read without this package.
///
///     workspace.json      what book this is (id, title, format version)
///     chapters.json       the text, already split into paragraphs
///     breaks.json         how much each chapter starts a new storyline
///     arcs.json           where the arcs fall, and which share a bed set
///     themes.json         the book's musical theme, and each arc's
///     tags/ch-NNNNN.json  mood + intensity per paragraph, one file a chapter
///     allocation.json     how many beds each cue of each set gets
///     arc-NNN/            a generated bed set: manifest.json + audio
///     palette.json        how a player finds the set for a chapter
///
/// The last three are the same files, in the same shapes, that the reader app
/// keeps under `generated/<book>/` -- so a workspace's bed sets play in the app,
/// and the Python generator writes into either without knowing which.
/// FORMAT.md at the framework root is the contract.
///
/// Every stage reads what the one before wrote and writes one file of its own,
/// so any stage can be re-run, resumed, or done by something else entirely: a
/// host with its own classifier can write tags/ and skip ours.
///
/// Files are written atomically -- to a temporary name, then renamed -- because
/// every stage is long and resumable, and a stage killed mid-write must leave
/// the previous file rather than half of a new one.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'arcs.dart';
import 'book.dart';
import 'epub.dart';
import 'tagging.dart';

/// Bumped when a file's shape changes incompatibly. A workspace records the
/// version it was written with; [Workspace.open] refuses a newer one.
const workspaceFormat = 1;

/// Short hex digest: enough to tell two texts apart, short enough to read.
String digestOf(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);

class WorkspaceChapter {
  const WorkspaceChapter({
    required this.index,
    required this.title,
    required this.paragraphs,
  });

  final int index;
  final String title;

  /// Split by [Book.fromText]'s rule, once, at ingest -- so paragraph `i`
  /// means the same text to every stage and every host that reads the file.
  final List<String> paragraphs;

  /// The chapter as one string, paragraphs separated by a blank line.
  String get body => paragraphs.join('\n\n');

  /// What a chapter's tags are valid for. Tags written against other text
  /// are stale and are not served.
  String get digest => digestOf(body);

  Map<String, dynamic> toJson() =>
      {'index': index, 'title': title, 'paragraphs': paragraphs};

  static WorkspaceChapter fromJson(Map<String, dynamic> json) =>
      WorkspaceChapter(
        index: (json['index'] as num).toInt(),
        title: json['title'] as String? ?? '',
        paragraphs: [for (final p in json['paragraphs'] as List) p as String],
      );
}

/// A theme and what it was computed from, so a re-cut arc re-themes and an
/// unchanged one does not.
class StoredTheme {
  const StoredTheme(this.theme, {required this.sample, this.backend = ''});

  final BookTheme theme;

  /// [digestOf] the text the theme pass read.
  final String sample;
  final String backend;

  Map<String, dynamic> toJson() =>
      {...theme.toJson(), 'sample': sample, 'backend': backend};

  static StoredTheme fromJson(Map<String, dynamic> json) => StoredTheme(
        BookTheme.fromJson(json),
        sample: json['sample'] as String? ?? '',
        backend: json['backend'] as String? ?? '',
      );
}

class WorkspaceException implements Exception {
  const WorkspaceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Workspace {
  Workspace._(this.directory, this.info);

  final Directory directory;

  /// workspace.json.
  final Map<String, dynamic> info;

  String get bookId => info['book'] as String;
  String get title => info['title'] as String;
  String? get author => info['author'] as String?;

  String path(String name) => p.join(directory.path, name);

  // --- Creating and opening ----------------------------------------------

  /// A new workspace from chapters of raw text.
  ///
  /// The book id is a digest of the split text, so the same book ingested
  /// twice gets the same id and different editions get different ones.
  static Future<Workspace> create(
    String directory, {
    required String title,
    required List<({String title, String text})> chapters,
    String? author,
    String? source,
  }) async {
    final dir = Directory(directory);
    if (await File(p.join(dir.path, 'workspace.json')).exists()) {
      throw WorkspaceException('$directory already holds a workspace');
    }
    await dir.create(recursive: true);

    final split = [
      for (var i = 0; i < chapters.length; i++)
        WorkspaceChapter(
          index: i,
          title: chapters[i].title,
          paragraphs: Book.fromText(chapters[i].title, chapters[i].text)
              .paragraphs,
        ),
    ].where((c) => c.paragraphs.isNotEmpty).toList();
    // Renumbered after dropping empty chapters, so an index is a position.
    final numbered = [
      for (var i = 0; i < split.length; i++)
        WorkspaceChapter(
            index: i, title: split[i].title, paragraphs: split[i].paragraphs),
    ];
    if (numbered.isEmpty) {
      throw const WorkspaceException('no text in any chapter');
    }

    final info = {
      'format': workspaceFormat,
      'book': digestOf(numbered.map((c) => c.body).join('\n\n\n')),
      'title': title,
      'author': author,
      'source': source,
      'chapters': numbered.length,
      'paragraphs': numbered.fold<int>(0, (n, c) => n + c.paragraphs.length),
      'created': DateTime.now().toUtc().toIso8601String(),
    };
    final ws = Workspace._(dir, info);
    await ws._writeJson('chapters.json', [for (final c in numbered) c.toJson()]);
    await ws._writeJson('workspace.json', info);
    return ws;
  }

  /// A new workspace from an ePub, chaptered by its own navigation.
  static Future<Workspace> fromEpub(String directory, Uint8List bytes,
      {String? source}) async {
    final book = readEpub(bytes);
    return create(
      directory,
      title: book.title,
      author: book.author,
      source: source,
      chapters: [
        for (final c in book.chapters) (title: c.title, text: c.text),
      ],
    );
  }

  static Future<Workspace> open(String directory) async {
    final file = File(p.join(directory, 'workspace.json'));
    if (!await file.exists()) {
      throw WorkspaceException('no workspace at $directory');
    }
    final info = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final format = (info['format'] as num?)?.toInt() ?? 0;
    if (format > workspaceFormat) {
      throw WorkspaceException('$directory is format $format; this build '
          'reads up to $workspaceFormat');
    }
    return Workspace._(Directory(directory), info);
  }

  // --- Text --------------------------------------------------------------

  List<WorkspaceChapter>? _chapters;

  Future<List<WorkspaceChapter>> chapters() async => _chapters ??= [
        for (final c in await _readJson('chapters.json') as List)
          WorkspaceChapter.fromJson(c as Map<String, dynamic>),
      ];

  // --- Chapter breaks ----------------------------------------------------

  Future<Map<int, ChapterBreak>> breaks() async {
    final json = await _readJsonOr('breaks.json');
    if (json == null) return {};
    return {
      for (final raw in json['chapters'] as List)
        (raw['index'] as num).toInt(): ChapterBreak(
          index: (raw['index'] as num).toInt(),
          score: (raw['score'] as num).toDouble(),
          situation: raw['situation'] as String? ?? '',
          hard: raw['hard'] as bool? ?? false,
        ),
    };
  }

  /// Merged into what is there: the scan runs in batches and resumes.
  Future<void> putBreaks(Iterable<ChapterBreak> rows, {String backend = ''})
  async {
    final all = await breaks()..addAll({for (final b in rows) b.index: b});
    final ordered = all.keys.toList()..sort();
    await _writeJson('breaks.json', {
      'backend': backend,
      'chapters': [
        for (final i in ordered)
          {
            'index': i,
            'score': all[i]!.score,
            'situation': all[i]!.situation,
            'hard': all[i]!.hard,
          },
      ],
    });
  }

  /// Chapters scored contiguously from the start -- the scan front.
  Future<int> scannedThrough() async {
    final have = await breaks();
    var n = 0;
    while (have.containsKey(n)) {
      n++;
    }
    return n;
  }

  // --- Arcs --------------------------------------------------------------

  Future<List<Arc>?> arcs() async {
    final json = await _readJsonOr('arcs.json');
    if (json == null) return null;
    return [
      for (final raw in json['arcs'] as List)
        Arc.fromJson(raw as Map<String, dynamic>),
    ];
  }

  /// The length range the arcs were last cut with, from arcs.json.
  Future<({int min, int max})?> arcRange() async {
    final json = await _readJsonOr('arcs.json');
    if (json == null) return null;
    return (
      min: (json['min'] as num?)?.toInt() ?? minArcChapters,
      max: (json['max'] as num?)?.toInt() ?? maxArcChapters,
    );
  }

  /// Same shape as the reader app's `generated/<book>/arcs.json`.
  Future<void> putArcs(
    List<Arc> arcs, {
    required int min,
    required int max,
    required double threshold,
  }) async {
    await _writeJson('arcs.json', {
      'book': bookId,
      'min': min,
      'max': max,
      'threshold': threshold,
      'scanned_through': await scannedThrough(),
      'sets': arcs.where((a) => a.palette == a.index).length,
      'arcs': [for (final arc in arcs) arc.toJson()],
    });
  }

  // --- Themes ------------------------------------------------------------

  Future<StoredTheme?> bookTheme() async {
    final json = await _readJsonOr('themes.json');
    final book = json?['book'];
    return book is Map<String, dynamic> ? StoredTheme.fromJson(book) : null;
  }

  Future<Map<int, StoredTheme>> arcThemes() async {
    final json = await _readJsonOr('themes.json');
    final arcs = json?['arcs'];
    if (arcs is! Map<String, dynamic>) return {};
    return {
      for (final entry in arcs.entries)
        int.parse(entry.key):
            StoredTheme.fromJson(entry.value as Map<String, dynamic>),
    };
  }

  Future<void> putBookTheme(StoredTheme theme) async {
    final json = await _readJsonOr('themes.json') ?? {};
    json['book'] = theme.toJson();
    await _writeJson('themes.json', json);
  }

  Future<void> putArcThemes(Map<int, StoredTheme> themes) async {
    final json = await _readJsonOr('themes.json') ?? {};
    json['arcs'] = {
      for (final entry in themes.entries) '${entry.key}': entry.value.toJson(),
    };
    await _writeJson('themes.json', json);
  }

  // --- Tags --------------------------------------------------------------

  String _tagFile(int chapter) =>
      p.join('tags', 'ch-${chapter.toString().padLeft(5, '0')}.json');

  /// A chapter's tags, by paragraph index. Empty when there are none or when
  /// they were written against different text.
  Future<Map<int, MoodTag>> tags(WorkspaceChapter chapter) async {
    final json = await _readJsonOr(_tagFile(chapter.index));
    if (json == null || json['digest'] != chapter.digest) return {};
    return {
      for (final entry in (json['tags'] as Map<String, dynamic>).entries)
        int.parse(entry.key):
            MoodTag.fromJson(entry.value as Map<String, dynamic>),
    };
  }

  /// Merged into what is there: tagging runs in batches and resumes.
  Future<void> putTags(
    WorkspaceChapter chapter,
    Map<int, MoodTag> tagged, {
    String backend = '',
    String theme = '',
  }) async {
    final all = await tags(chapter)..addAll(tagged);
    final ordered = all.keys.toList()..sort();
    await _writeJson(_tagFile(chapter.index), {
      'chapter': chapter.index,
      'digest': chapter.digest,
      'paragraphs': chapter.paragraphs.length,
      'backend': backend,
      'theme': theme,
      'tags': {for (final i in ordered) '$i': all[i]!.toJson()},
    });
  }

  // --- Allocation --------------------------------------------------------

  Future<Map<String, dynamic>?> allocation() => _readJsonOr('allocation.json');

  Future<void> putAllocation(Map<String, dynamic> json) =>
      _writeJson('allocation.json', json);

  // --- JSON --------------------------------------------------------------

  Future<Object?> _readJson(String name) async =>
      jsonDecode(await File(path(name)).readAsString());

  Future<Map<String, dynamic>?> _readJsonOr(String name) async {
    final file = File(path(name));
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> _writeJson(String name, Object json) async {
    final target = File(path(name));
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
        const JsonEncoder.withIndent(' ').convert(json),
        flush: true);
    await temporary.rename(target.path);
  }
}
