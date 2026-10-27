import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ollama_client.dart';

/// Mood tags on disk, so re-reading a book costs nothing.
///
/// Rows are keyed by book and by model. The book key folds in a hash of the
/// text, so editing a chapter starts fresh instead of serving tags written
/// against the old wording; the model column is there because Phase 0 already
/// hit the bug where switching models quietly served the previous one's tags.
///
/// For tags the model column also carries the prompt's version ([tagModel]),
/// for the same reason: a reworded prompt must not be served the old one's
/// tags. Tags under an older version stay in the file, unreachable.
class MoodCache {
  MoodCache._(this._db);

  final Database _db;

  /// A database at an explicit path.
  ///
  /// The only way in, and deliberately: everything here runs on a plain Dart
  /// VM, so tools and (eventually) a server can use it. The app's own location
  /// lives in app_stores.dart, which is where path_provider is allowed.
  static Future<MoodCache> at(String path) async {
    sqfliteFfiInit();
    return MoodCache._(await _openAt(path));
  }

  /// For tests: a database that never touches disk.
  static Future<MoodCache> inMemory() async {
    sqfliteFfiInit();
    return MoodCache._(await _openAt(inMemoryDatabasePath));
  }

  static Future<Database> _openAt(String path) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE themes (
              book_key        TEXT NOT NULL,
              model           TEXT NOT NULL,
              overall_theme   TEXT NOT NULL,
              instrumentation TEXT NOT NULL,
              genre_seed      TEXT NOT NULL,
              theme_id        TEXT NOT NULL,
              PRIMARY KEY (book_key, model)
            )
          ''');
          await db.execute('''
            CREATE TABLE tags (
              book_key        TEXT NOT NULL,
              model           TEXT NOT NULL,
              paragraph_index INTEGER NOT NULL,
              mood            TEXT NOT NULL,
              intensity       REAL NOT NULL,
              reason          TEXT NOT NULL,
              PRIMARY KEY (book_key, model, paragraph_index)
            )
          ''');
        },
      ),
    );
  }

  Future<BookTheme?> theme(String bookKey) async {
    final rows = await _db.query(
      'themes',
      where: 'book_key = ? AND model = ?',
      whereArgs: [bookKey, ollamaModel],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return BookTheme(
      overallTheme: row['overall_theme'] as String,
      instrumentation: row['instrumentation'] as String,
      genreSeed: row['genre_seed'] as String,
      themeId: row['theme_id'] as String,
    );
  }

  Future<void> putTheme(String bookKey, BookTheme theme) async {
    await _db.insert(
      'themes',
      {
        'book_key': bookKey,
        'model': ollamaModel,
        'overall_theme': theme.overallTheme,
        'instrumentation': theme.instrumentation,
        'genre_seed': theme.genreSeed,
        'theme_id': theme.themeId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Forget everything cached for a book: its theme, and the tags of every
  /// chapter. Removing a book from the library must not leave its tags behind
  /// to be served to whatever later happens to hash to the same key.
  ///
  /// Chapter keys are `<bookId>#<n>-<hash>`, so the prefix match catches them
  /// all; the theme is keyed on the book id alone.
  Future<int> forgetBook(String bookId, String chapterKeyPrefix) async {
    final tags = await forgetTags(chapterKeyPrefix);
    await _db.delete('themes', where: 'book_key = ?', whereArgs: [bookId]);
    return tags;
  }

  /// Drop every tag for a book, keeping its theme.
  ///
  /// For an edit to the text. Book keys fold in a hash of the prose, so edited
  /// chapters would find no tags anyway and simply be classified again -- but
  /// the old rows would stay behind forever, under a key nothing can reach.
  /// The theme is keyed on the book id alone and survives.
  Future<int> forgetTags(String chapterKeyPrefix) {
    final escaped =
        chapterKeyPrefix.replaceAll('%', r'\%').replaceAll('_', r'\_');
    return _db.delete(
      'tags',
      where: "book_key LIKE ? ESCAPE '\\'",
      whereArgs: ['$escaped%'],
    );
  }

  /// Every tag known for this book. Chapters are small enough that loading
  /// them all once beats querying per paragraph.
  Future<Map<int, MoodTag>> tags(String bookKey) async {
    final rows = await _db.query(
      'tags',
      where: 'book_key = ? AND model = ?',
      whereArgs: [bookKey, tagModel],
    );
    return {
      for (final row in rows)
        row['paragraph_index'] as int: MoodTag(
          mood: row['mood'] as String,
          intensity: row['intensity'] as double,
          reason: row['reason'] as String,
        ),
    };
  }

  Future<void> putTags(String bookKey, Map<int, MoodTag> tags) async {
    final batch = _db.batch();
    for (final entry in tags.entries) {
      batch.insert(
        'tags',
        {
          'book_key': bookKey,
          'model': tagModel,
          'paragraph_index': entry.key,
          'mood': entry.value.mood,
          'intensity': entry.value.intensity,
          'reason': entry.value.reason,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() => _db.close();
}
