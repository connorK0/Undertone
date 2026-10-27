import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/epub.dart';
import 'package:reader_shell/library.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:reader_shell/watermark.dart';

void main() {
  // sqflite_common_ffi shares one in-memory database across a process, so a
  // Library and a MoodCache opened at the same time are the *same* database
  // and the second one's tables are never created. Each test therefore opens
  // exactly one store and closes it before the next begins.
  Future<Library> openLibrary() async {
    final library = await Library.inMemory();
    addTearDown(library.close);
    return library;
  }

  Future<(Library, String)> withAlice() async {
    final library = await openLibrary();
    final bytes = File('test/fixtures/alice.epub').readAsBytesSync();
    return (library, await library.addEpub(readEpub(bytes), bytes));
  }

  test('an imported book shows up with its metadata and cover', () async {
    final (library, id) = await withAlice();
    final entries = await library.entries();

    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.id, id);
    expect(entry.title, "Alice's Adventures in Wonderland");
    expect(entry.author, 'Lewis Carroll');
    expect(entry.cover, isNotNull);
    expect(entry.chapterCount, 12);
    expect(entry.started, isFalse);
    expect(entry.subtitle, contains('12 chapters'));
  });

  test('importing the same file twice is the same book, not two', () async {
    final (library, first) = await withAlice();
    final bytes = File('test/fixtures/alice.epub').readAsBytesSync();
    final second = await library.addEpub(readEpub(bytes), bytes);
    expect(second, first, reason: 'the id is a hash of the bytes');
    expect(await library.entries(), hasLength(1));
    expect(await library.has(first), isTrue);
  });

  test('chapters of one book share a theme key and the book-wide sample',
      () async {
    // Otherwise a sixty-chapter novel pays for sixty theme passes and gets
    // sixty different themes -- and the theme is quoted in every paragraph
    // prompt, so the book would drift in register as you read it.
    final (library, id) = await withAlice();
    final first = (await library.chapter(id, 0))!;
    final tenth = (await library.chapter(id, 9))!;

    // One key for the whole book, and it names the book -- but it also folds
    // in a hash of the sample, so a theme cached against a different sample
    // cannot be served for this one.
    expect(first.themeKey, tenth.themeKey);
    expect(first.themeKey, startsWith('$id-'));
    expect(first.themeText, tenth.themeText);
    expect(first.key, isNot(tenth.key), reason: 'tags are still per chapter');

    // The theme reads the book, not the chapter that happens to be open.
    expect(first.themeText.length, greaterThan(first.text.length));
    expect(first.themeText.length, lessThanOrEqualTo(maxThemeChars));
  });

  test('chapter keys are namespaced by book, so two books cannot collide',
      () async {
    final (library, id) = await withAlice();
    final chapter = (await library.chapter(id, 3))!;
    expect(chapter.key, startsWith(bookKeyPrefix(id)));
    expect(chapter.title, 'CHAPTER IV.');
  });

  test('reading position survives, and is reported in the library', () async {
    final (library, id) = await withAlice();
    await library.saveProgress(id, 4, 37);

    final entry = (await library.entries()).single;
    expect(entry.started, isTrue);
    expect(entry.chapterIndex, 4);
    expect(entry.paragraphIndex, 37);
    expect(entry.subtitle, contains('chapter 5 of 12'));
  });

  test('removing a book takes its chapters and its place in it', () async {
    final (library, id) = await withAlice();
    await library.saveProgress(id, 2, 5);
    await library.remove(id);

    expect(await library.entries(), isEmpty);
    expect(await library.has(id), isFalse);
    expect(await library.chapter(id, 0), isNull);
    expect(await library.chapterTitles(id), isEmpty);
  });

  test('removing a book takes its cached tags too', () async {
    final cache = await MoodCache.inMemory();
    addTearDown(cache.close);
    const gone = 'deadbeef';
    const kept = 'cafebabe';

    for (final id in [gone, kept]) {
      await cache.putTheme(
        id,
        BookTheme(
          overallTheme: 'Something $id',
          instrumentation: 'strings',
          genreSeed: 'seed',
        ),
      );
      for (var chapter = 0; chapter < 3; chapter++) {
        await cache.putTags('$id#$chapter-abc123', {
          0: const MoodTag(mood: 'calm', intensity: 0.4, reason: 'x'),
        });
      }
    }

    final removed = await cache.forgetBook(gone, bookKeyPrefix(gone));
    expect(removed, 3, reason: 'one tag in each of three chapters');
    expect(await cache.theme(gone), isNull);

    // The other book is untouched.
    expect(await cache.theme(kept), isNotNull);
    for (var chapter = 0; chapter < 3; chapter++) {
      expect(await cache.tags('$kept#$chapter-abc123'), isNotEmpty);
      expect(await cache.tags('$gone#$chapter-abc123'), isEmpty);
    }
  });

  test('a bundled plain-text sample is a one-chapter book', () async {
    final library = await openLibrary();
    final id = await library.addPlainText(
      id: 'sample-dracula',
      title: 'Dracula, chapter I',
      text: File('assets/books/dracula_ch1.txt').readAsStringSync(),
    );
    final entry = (await library.entries()).single;
    expect(entry.chapterCount, 1);
    expect(entry.subtitle, isNot(contains('chapters')));

    final chapter = (await library.chapter(id, 0))!;
    expect(chapter.paragraphs.length, 36, reason: 'same split as before');
    expect(chapter.themeKey, startsWith('$id-'));
  });

  group('watermark clean on a stored book', () {
    test('chapter bodies come back in order, and go back in', () async {
      final (library, id) = await withAlice();
      final before = await library.chapterBodies(id);
      expect(before, hasLength(12));
      expect(before.first.$1, isNotEmpty, reason: 'titles come with them');

      await library.replaceChapterBodies(
        id,
        [for (final (_, body) in before) body],
      );
      expect(await library.chapterBodies(id), before,
          reason: 'writing them back unchanged changes nothing');
    });

    test('it refuses a list that is not the book', () async {
      // The one way this could destroy a book is by writing the wrong number
      // of chapters into it, so that is checked rather than assumed.
      final (library, id) = await withAlice();
      expect(() => library.replaceChapterBodies(id, ['just the one']),
          throwsArgumentError);
      expect(await library.chapterBodies(id), hasLength(12));
    });

    test('a real book survives being stamped and cleaned, exactly', () async {
      // End to end on twelve chapters of actual prose: stamp every chapter,
      // let the detector find it on its own, remove what it found, and require
      // the result to be the original book character for character. Anything
      // this feature gets wrong on Alice shows up here as a diff.
      final (library, id) = await withAlice();
      final original = await library.chapterBodies(id);

      const stamp = 'Read more at: freewebnovel.com';
      await library.replaceChapterBodies(
        id,
        [
          for (final (_, body) in original) '$stamp\n\n$body\n\n$stamp',
        ],
      );

      final stamped = [
        for (final (_, body) in await library.chapterBodies(id)) body,
      ];
      final found = findWatermarks(stamped);
      expect(found, hasLength(1));
      expect(found.single.occurrences, 24, reason: 'twice in each of twelve');
      expect(found.single.chapters, 12);

      final keys = {found.single.canonical};
      await library.replaceChapterBodies(
        id,
        [for (final body in stamped) removeWatermarks(body, keys)],
      );
      expect(await library.chapterBodies(id), original);
    });

    test('Alice has nothing in her that looks like a watermark', () async {
      // The negative case on real prose. Twelve chapters of Carroll, a
      // Gutenberg text with its own front matter and headings, and the
      // detector has to come back with nothing at all.
      final (library, id) = await withAlice();
      final bodies = [
        for (final (_, body) in await library.chapterBodies(id)) body,
      ];
      expect(findWatermarks(bodies), isEmpty);
    });
  });

  group('the theme sample', () {
    test('a book that fits is sampled whole, as it always was', () async {
      // Every bundled chapter is well under the cap, so nothing about the
      // short-book case may change.
      final library = await openLibrary();
      final text = File('assets/books/dracula_ch1.txt').readAsStringSync();
      final id = await library.addPlainText(
          id: 'sample-dracula', title: 'Dracula', text: text);
      final chapter = (await library.chapter(id, 0))!;
      expect(chapter.themeText.trim(), text.trim());
      expect(chapter.themeText, isNot(contains('[...]')));
    });

    test('a long book is sampled from end to end, not off the front', () async {
      // The bug this fixes: 40,000 characters taken from the front of a
      // 2,364-chapter serial is 0.24% of it, all from the opening, and that
      // theme is quoted in every paragraph prompt and every generation prompt.
      final library = await openLibrary();
      // 300 chapters, each naming itself, each far larger than one slice.
      final id = await library.addEpub(
        EpubBook(
          title: 'A Serial',
          author: null,
          chapters: [
            for (var i = 0; i < 300; i++)
              EpubChapter(
                title: 'Chapter $i',
                text: 'MARKER$i. ${'filler text for chapter $i. ' * 200}',
              ),
          ],
        ),
        Uint8List.fromList(utf8.encode('a-serial')),
      );

      final sample = (await library.chapter(id, 0))!.themeText;
      expect(sample.length, lessThanOrEqualTo(maxThemeChars));

      // Both ends of the book are in it, and so is the middle.
      expect(sample, contains('MARKER0.'));
      expect(sample, contains('MARKER299.'));
      final seen = [
        for (var i = 0; i < 300; i++)
          if (sample.contains('MARKER$i.')) i,
      ];
      expect(seen.length, Library.themeSlices,
          reason: 'one excerpt per slice, evenly spaced: $seen');
      expect(seen.last - seen.first, greaterThan(280),
          reason: 'the excerpts span the book: $seen');

      // Evenly spaced rather than clustered.
      final gaps = [
        for (var i = 1; i < seen.length; i++) seen[i] - seen[i - 1],
      ];
      expect(gaps.reduce((a, b) => a > b ? a : b) -
              gaps.reduce((a, b) => a < b ? a : b),
          lessThanOrEqualTo(1),
          reason: 'gaps should all be the same: $gaps');
      expect(sample, contains('[...]'), reason: 'the gaps are marked');
    });

    test('a changed sample invalidates the theme cached against it', () async {
      // The same trick the tag cache uses on the prose. Without it, a book
      // resampled by the migration would go on being served the theme worked
      // out from its first five chapters.
      final library = await openLibrary();
      final id = await library.addEpub(
        EpubBook(
          title: 'A Serial',
          author: null,
          chapters: [
            for (var i = 0; i < 40; i++)
              EpubChapter(title: 'C$i', text: 'body $i. ${'x' * 3000}'),
          ],
        ),
        Uint8List.fromList(utf8.encode('serial-2')),
      );
      final before = (await library.chapter(id, 0))!.themeKey;

      await library.replaceChapterBodies(
        id,
        [for (var i = 0; i < 40; i++) 'CHANGED $i. ${'y' * 3000}'],
      );
      final after = (await library.chapter(id, 0))!.themeKey;
      expect(after, isNot(before));
      expect(after, startsWith('$id-'));
    });
  });

    test('replacing bodies reports only the chapters that changed', () async {
      // The watermark pass rewrites every chapter and changes a handful. The
      // caller deletes the tags of whatever comes back, so reporting the
      // untouched ones would throw away work that is still perfectly
      // reachable -- on the real book, 2,891 classified paragraphs and about
      // forty minutes of GPU.
      final (library, id) = await withAlice();
      final before = await library.chapterBodies(id);

      final edited = [for (final (_, body) in before) body];
      edited[1] = '${edited[1]} edited';
      expect(await library.replaceChapterBodies(id, edited), [1]);

      expect(await library.replaceChapterBodies(id, edited), isEmpty,
          reason: 'writing the same bodies back changes no chapter');
    });
}
