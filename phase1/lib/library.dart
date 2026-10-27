import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'arcs.dart';
import 'book.dart';
import 'epub.dart';
import 'ollama_client.dart';

/// The books someone has imported, their chapters, and where they left off.
///
/// A separate database from the mood cache on purpose. This is the reader's own
/// data and losing it means losing their books; the cache is derived, and
/// deleting it costs only the time to classify again. Keeping them apart means
/// the cache can be cleared — for a model change, say — without touching the
/// library.
class Library {
  Library._(this._db);

  final Database _db;

  static Future<Library> inMemory() async {
    sqfliteFfiInit();
    return Library._(await _openAt(inMemoryDatabasePath));
  }

  /// A database at an explicit path.
  ///
  /// Tests that need a Library *and* a MoodCache at once cannot use
  /// [inMemory]: sqflite_common_ffi shares one in-memory database per process,
  /// so the second store to open finds the first one's schema and its own
  /// tables are never created.
  static Future<Library> at(String path) async {
    sqfliteFfiInit();
    return Library._(await _openAt(path));
  }

  static Future<Database> _openAt(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        // 2: the theme sample is drawn from across the book rather than off
        // the front. See themeSample.
        // 4 added a chapter_moods table holding a scattered sample of each
        // chapter's moods; 5 drops it again. Scattered paragraphs cannot be
        // windowed, so they can never say what would *sound* -- see
        // lib/played.dart -- and an arc is now classified whole into the mood
        // cache instead, which answers both questions and leaves the arc ready
        // to read with no classifier wait.
        version: 5,
        onUpgrade: (db, from, to) async {
          if (from < 2) await _resampleThemes(db);
          if (from < 3) await db.execute(_chapterBreaksTable);
          if (from >= 4 && from < 5) {
            await db.execute('DROP TABLE IF EXISTS chapter_moods');
          }
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE books (
              id            TEXT PRIMARY KEY,
              title         TEXT NOT NULL,
              author        TEXT,
              cover         BLOB,
              chapter_count INTEGER NOT NULL,
              added_at      INTEGER NOT NULL,
              theme_sample  TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE chapters (
              book_id TEXT NOT NULL,
              idx     INTEGER NOT NULL,
              title   TEXT NOT NULL,
              body    TEXT NOT NULL,
              PRIMARY KEY (book_id, idx)
            )
          ''');
          await db.execute('''
            CREATE TABLE progress (
              book_id         TEXT PRIMARY KEY,
              chapter_index   INTEGER NOT NULL,
              paragraph_index INTEGER NOT NULL,
              updated_at      INTEGER NOT NULL
            )
          ''');
          await db.execute(_chapterBreaksTable);
          // Preferences live here rather than in a separate store because they
          // are the same kind of thing as the library: the reader's own
          // choices, which should survive clearing the derived cache.
          await db.execute('''
            CREATE TABLE settings (
              name  TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
      ),
    );
  }

  /// Where each chapter sits in the story, as scored by the arc scan.
  ///
  /// One row per chapter *scanned*, not per chapter: the scan runs ahead of the
  /// reader rather than over the whole book at import, so this fills in as
  /// reading goes. Held as scores rather than as boundaries because choosing
  /// boundaries from scores is arithmetic -- changing the arc length range
  /// re-cuts the book with no model calls at all.
  static const _chapterBreaksTable = '''
    CREATE TABLE IF NOT EXISTS chapter_breaks (
      book_id     TEXT NOT NULL,
      idx         INTEGER NOT NULL,
      break_score REAL NOT NULL,
      situation   TEXT NOT NULL,
      hard        INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (book_id, idx)
    )
  ''';

  /// Stable identity for a file: a hash of its bytes. Importing the same ePub
  /// twice is then the same book rather than a duplicate.
  static String idForBytes(Uint8List bytes) =>
      sha256.convert(bytes).toString().substring(0, 16);

  Future<bool> has(String id) async {
    final rows = await _db.query('books',
        columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty;
  }

  Future<List<LibraryEntry>> entries() async {
    final rows = await _db.rawQuery('''
      SELECT b.id, b.title, b.author, b.cover, b.chapter_count, b.added_at,
             p.chapter_index, p.paragraph_index
      FROM books b LEFT JOIN progress p ON p.book_id = b.id
      ORDER BY b.added_at DESC
    ''');
    return [
      for (final row in rows)
        LibraryEntry(
          id: row['id'] as String,
          title: row['title'] as String,
          author: row['author'] as String?,
          cover: row['cover'] as Uint8List?,
          chapterCount: row['chapter_count'] as int,
          addedAt:
              DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
          chapterIndex: (row['chapter_index'] as int?) ?? 0,
          paragraphIndex: (row['paragraph_index'] as int?) ?? 0,
          started: row['chapter_index'] != null,
        ),
    ];
  }

  /// Store an ePub. Returns the book's id.
  Future<String> addEpub(EpubBook book, Uint8List bytes) =>
      _add(
        id: idForBytes(bytes),
        title: book.title,
        author: book.author,
        cover: book.cover,
        chapters: [
          for (final chapter in book.chapters) (chapter.title, chapter.text),
        ],
      );

  /// Store a single-chapter plain text, for the bundled samples.
  Future<String> addPlainText({
    required String id,
    required String title,
    required String text,
    String? author,
  }) =>
      _add(id: id, title: title, author: author, chapters: [(title, text)]);

  /// How many places in the book the sample is drawn from.
  ///
  /// A trade: more excerpts cover more of the book, shorter ones stop reading
  /// as prose. Twenty-four of `maxThemeChars / 24` is about 1,600 characters
  /// each -- a few paragraphs, enough to have a mood.
  static const themeSlices = 24;

  /// What the theme pass reads: a sample drawn from across the whole book.
  ///
  /// Taking the first [maxThemeChars] instead, which is what this did, is
  /// fine for a novel and wrong for anything long. The test book is 16.8M
  /// characters over 2,364 chapters, so 40,000 from the front
  /// is **0.24% of the book, all of it the opening five chapters** -- and the
  /// theme derived from it is quoted in every paragraph prompt and in every
  /// prompt the music generator ever sees. A serial that changes register over
  /// hundreds of chapters would be scored for its first afternoon, forever.
  ///
  /// Excerpts are joined with an explicit gap marker rather than run together,
  /// because silently concatenating distant text invites the model to read it
  /// as continuous and infer a shape that is not there.
  /// [budget] is how many characters the sample may occupy. It exists because
  /// an arc's sample shares the prompt with a summary of what happens in that
  /// arc, and the prompt truncates at [maxThemeChars] -- so whatever the
  /// summary takes has to come out of the sample rather than off the end.
  static String themeSample(List<String> bodies, {int budget = maxThemeChars}) {
    if (bodies.isEmpty) return '';
    final total = bodies.fold<int>(0, (n, b) => n + b.length);
    // A book that fits entirely is not a sample, and stays byte-for-byte what
    // it always was.
    if (total <= budget) return bodies.join('\n');

    const separator = '\n\n[...]\n\n';
    final slices = min(bodies.length, themeSlices);
    // The markers come out of the budget, not on top of it: the prompt
    // truncates at maxThemeChars, so anything over the cap would silently cost
    // the end of the last excerpt -- the one taken from the end of the book,
    // which is the half this change exists to include.
    final each =
        (budget - separator.length * (slices - 1)) ~/ slices;
    final parts = <String>[];
    for (var i = 0; i < slices; i++) {
      // Evenly spaced, with the first and last chapters always included: the
      // ends of a book are where its register is most likely to differ.
      final at = slices == 1
          ? 0
          : (i * (bodies.length - 1) / (slices - 1)).round();
      final body = bodies[at];
      parts.add(body.length <= each ? body : body.substring(0, each));
    }
    return parts.join(separator);
  }

  /// Recompute the stored sample for every book.
  ///
  /// Runs on the schema upgrade that introduced spread sampling, so books
  /// imported before it get the better sample without being imported again.
  /// The theme cached against the old sample invalidates itself, because
  /// [Book.themeKey] folds in a hash of what the theme was computed from.
  static Future<void> _resampleThemes(DatabaseExecutor db) async {
    final books = await db.query('books', columns: ['id']);
    for (final book in books) {
      final id = book['id'] as String;
      final rows = await db.query('chapters',
          columns: ['body'], where: 'book_id = ?', whereArgs: [id],
          orderBy: 'idx');
      final sample = themeSample([for (final r in rows) r['body'] as String]);
      await db.update('books', {'theme_sample': sample},
          where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<String> _add({
    required String id,
    required String title,
    required String? author,
    required List<(String, String)> chapters,
    Uint8List? cover,
  }) async {
    final sample = themeSample([for (final (_, body) in chapters) body]);

    await _db.transaction((txn) async {
      await txn.insert('books', {
        'id': id,
        'title': title,
        'author': author,
        'cover': cover,
        'chapter_count': chapters.length,
        'added_at': DateTime.now().millisecondsSinceEpoch,
        'theme_sample': sample,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete('chapters', where: 'book_id = ?', whereArgs: [id]);
      for (var i = 0; i < chapters.length; i++) {
        await txn.insert('chapters', {
          'book_id': id,
          'idx': i,
          'title': chapters[i].$1,
          'body': chapters[i].$2,
        });
      }
    });
    return id;
  }

  Future<List<String>> chapterTitles(String bookId) async {
    final rows = await _db.query('chapters',
        columns: ['title'],
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'idx');
    return [for (final row in rows) row['title'] as String];
  }

  /// One chapter, ready for the pipeline.
  ///
  /// [Book.themeKey] is the *book* id, so every chapter shares one theme —
  /// sixty chapters would otherwise mean sixty theme passes and sixty
  /// different themes, and the theme is quoted in every paragraph prompt.
  Future<Book?> chapter(String bookId, int index) async {
    final rows = await _db.query('chapters',
        where: 'book_id = ? AND idx = ?', whereArgs: [bookId, index], limit: 1);
    if (rows.isEmpty) return null;
    final sample = await _db.query('books',
        columns: ['theme_sample'],
        where: 'id = ?',
        whereArgs: [bookId],
        limit: 1);
    return Book.fromText(
      rows.first['title'] as String,
      rows.first['body'] as String,
      source: '$bookId#$index',
      themeKey: bookId,
      themeText:
          sample.isEmpty ? null : sample.first['theme_sample'] as String,
    );
  }

  /// Every chapter of a book, in order, as (title, body).
  ///
  /// For the watermark clean, which has to see the whole book at once: a stamp
  /// is only recognisable by the fact that it repeats across chapters.
  Future<List<(String, String)>> chapterBodies(String bookId) async {
    final rows = await _db.query('chapters',
        columns: ['title', 'body'],
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'idx');
    return [
      for (final row in rows) (row['title'] as String, row['body'] as String),
    ];
  }

  /// Rewrite a book's chapter bodies in place.
  ///
  /// The theme sample is derived from the bodies, so it is recomputed here --
  /// leaving it would have the theme pass reading text the book no longer
  /// contains. Chapter count and titles are untouched: this exists for edits
  /// that change the words, not the structure, and it refuses anything else.
  /// Returns the indices whose text actually changed.
  ///
  /// Which chapters changed matters more than it looks. A chapter's tags are
  /// cached under a key folding a hash of its prose, so rewriting a chapter
  /// makes its tags unreachable and the caller deletes them. Rewriting a
  /// chapter to *the same bytes* does not — and a watermark pass over a
  /// 2,364-chapter book touches a handful of them. Reporting only the ones
  /// that moved is what stops the caller throwing away the rest, which on
  /// this book was 2,891 classified paragraphs and forty minutes of GPU.
  Future<List<int>> replaceChapterBodies(
    String bookId,
    List<String> bodies,
  ) async {
    final existing = await chapterBodies(bookId);
    if (existing.length != bodies.length) {
      throw ArgumentError('expected ${existing.length} chapters, '
          'got ${bodies.length}');
    }
    final changed = [
      for (var i = 0; i < bodies.length; i++)
        if (existing[i].$2 != bodies[i]) i,
    ];
    if (changed.isEmpty) return changed;
    await _db.transaction((txn) async {
      for (final i in changed) {
        await txn.update('chapters', {'body': bodies[i]},
            where: 'book_id = ? AND idx = ?', whereArgs: [bookId, i]);
      }
      // The sample is drawn across the whole book, so any change moves it.
      await txn.update('books', {'theme_sample': themeSample(bodies)},
          where: 'id = ?', whereArgs: [bookId]);
    });
    return changed;
  }

  /// A slice of chapters as (index, title, body), for the arc scan.
  ///
  /// Ranged rather than whole-book on purpose: this book's 2,364 bodies are
  /// 18 MB, and the scanner only ever needs the hundred or so ahead of the
  /// reader.
  Future<List<(int, String, String)>> chapterRange(
    String bookId,
    int from,
    int to,
  ) async {
    if (to <= from) return const [];
    final rows = await _db.query('chapters',
        columns: ['idx', 'title', 'body'],
        where: 'book_id = ? AND idx >= ? AND idx < ?',
        whereArgs: [bookId, from, to],
        orderBy: 'idx');
    return [
      for (final row in rows)
        (row['idx'] as int, row['title'] as String, row['body'] as String),
    ];
  }

  Future<void> putChapterBreaks(
    String bookId,
    Iterable<ChapterBreak> breaks,
  ) async {
    if (breaks.isEmpty) return;
    await _db.transaction((txn) async {
      for (final b in breaks) {
        await txn.insert(
          'chapter_breaks',
          {
            'book_id': bookId,
            'idx': b.index,
            'break_score': b.score,
            'situation': b.situation,
            'hard': b.hard ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<ChapterBreak>> chapterBreaks(String bookId) async {
    final rows = await _db.query('chapter_breaks',
        where: 'book_id = ?', whereArgs: [bookId], orderBy: 'idx');
    return [
      for (final row in rows)
        ChapterBreak(
          index: row['idx'] as int,
          score: (row['break_score'] as num).toDouble(),
          situation: row['situation'] as String,
          hard: (row['hard'] as int) != 0,
        ),
    ];
  }

  /// The first chapter that has **not** been scored, counting from 0.
  ///
  /// Contiguous rather than a maximum: a gap in the middle would let
  /// [chooseArcs] cut at a chapter nothing had looked at, so the scan is only
  /// trustworthy up to its first hole.
  Future<int> scannedThrough(String bookId) async {
    final rows = await _db.query('chapter_breaks',
        columns: ['idx'], where: 'book_id = ?', whereArgs: [bookId],
        orderBy: 'idx');
    var next = 0;
    for (final row in rows) {
      if (row['idx'] as int != next) break;
      next++;
    }
    return next;
  }

  Future<void> saveProgress(
    String bookId,
    int chapterIndex,
    int paragraphIndex,
  ) async {
    await _db.insert(
      'progress',
      {
        'book_id': bookId,
        'chapter_index': chapterIndex,
        'paragraph_index': paragraphIndex,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> remove(String bookId) async {
    await _db.transaction((txn) async {
      await txn.delete('chapters', where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('progress', where: 'book_id = ?', whereArgs: [bookId]);
      // The derived scans go with it. Without this a removed and re-imported
      // book keeps the old scores under the same id -- the id is a hash of the
      // file's bytes, so it is the same book, but "remove" should mean removed.
      await txn.delete('chapter_breaks',
          where: 'book_id = ?', whereArgs: [bookId]);
      await txn.delete('books', where: 'id = ?', whereArgs: [bookId]);
    });
  }

  Future<Map<String, String>> loadSettings() async {
    final rows = await _db.query('settings');
    return {
      for (final row in rows) row['name'] as String: row['value'] as String,
    };
  }

  Future<void> saveSetting(String name, String value) async {
    await _db.insert(
      'settings',
      {'name': name, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() => _db.close();
}

class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.title,
    required this.author,
    required this.cover,
    required this.chapterCount,
    required this.addedAt,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.started,
  });

  final String id;
  final String title;
  final String? author;
  final Uint8List? cover;
  final int chapterCount;
  final DateTime addedAt;

  /// Where the reader left off. Zero when they have not started.
  final int chapterIndex;
  final int paragraphIndex;
  final bool started;

  String get subtitle {
    final who = author ?? 'Unknown author';
    if (!started) {
      return chapterCount == 1 ? who : '$who · $chapterCount chapters';
    }
    return '$who · chapter ${chapterIndex + 1} of $chapterCount';
  }
}

/// Every chapter of a book caches its tags under a key starting with this, so
/// removing the book can take its tags with it.
String bookKeyPrefix(String bookId) => '$bookId#';
