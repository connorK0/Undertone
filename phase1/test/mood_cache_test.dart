// The tag cache's key carries the paragraph prompt's version, so tags written
// under an older wording are never served once the wording changes
// (SUMMARY 9.43).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('tags from an older prompt are not served under the current one',
      () async {
    final dir = await Directory.systemTemp.createTemp('mood_cache_test');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows can hold the file a moment after close; the OS cleans up.
      }
    });
    final path = '${dir.path}${Platform.pathSeparator}mood_cache.db';

    // A cache file as the previous version left it: the model column holding
    // the bare model name.
    var cache = await MoodCache.at(path);
    await cache.close();
    final raw = await databaseFactoryFfi.openDatabase(path);
    await raw.insert('tags', {
      'book_key': 'book#0-abc',
      'model': ollamaModel,
      'paragraph_index': 0,
      'mood': 'tense',
      'intensity': 0.8,
      'reason': 'clear sky',
    });
    await raw.close();

    cache = await MoodCache.at(path);
    expect(await cache.tags('book#0-abc'), isEmpty,
        reason: 'the old wording called this tense; it must be asked again');

    await cache.putTags('book#0-abc', {
      0: const MoodTag(mood: 'neutral', intensity: 0.5, reason: 'clear sky'),
    });
    expect((await cache.tags('book#0-abc'))[0]!.mood, 'neutral');
    await cache.close();
  });

  test('the paragraph request defines every mood the schema allows', () {
    for (final mood in moods) {
      expect(moodDefinitions, contains('- $mood: '), reason: mood);
    }
  });
}
