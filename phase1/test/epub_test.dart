// Real ePubs, not synthetic ones. All three fixtures are Project Gutenberg
// files, which is what anyone will try first, and between them they cover the
// awkward parts:
//
//   * Pride and Prejudice keeps 61 chapters in 16 XHTML files, so chapters
//     have to be cut at navigation anchors *inside* a document. Reading one
//     chapter per file would give sixteen twenty-minute "chapters".
//   * A Christmas Carol nests its illustration captions as child navPoints of
//     the staves they sit in. Following those cuts every stave in half.
//   * Alice puts its contents page in the navigation like any other entry.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/book.dart';
import 'package:reader_shell/epub.dart';

void main() {
  EpubBook read(String name) =>
      readEpub(File('test/fixtures/$name').readAsBytesSync());

  test('reads metadata and a cover', () {
    final book = read('alice.epub');
    expect(book.title, "Alice's Adventures in Wonderland");
    expect(book.author, 'Lewis Carroll');
    expect(book.cover, isNotNull, reason: 'the library screen needs it');
    expect(book.cover!.length, greaterThan(1000));
  });

  test('Alice comes out as its twelve chapters, and nothing else', () {
    final book = read('alice.epub');
    expect(book.chapters.length, 12,
        reason: 'got ${book.chapters.map((c) => c.title).toList()}');
    expect(book.chapters.first.title, 'CHAPTER I.');
    expect(book.chapters.last.title, 'CHAPTER XII.');
    expect(book.chapters.first.text.toLowerCase(), contains('rabbit'));
    // The contents page is a navigation entry like any other and must not
    // survive as a chapter.
    expect(book.chapters.map((c) => c.title.toLowerCase()),
        isNot(contains('contents')));
  });

  test('the Carol comes out as five staves, not ten half-staves', () {
    final book = read('christmas_carol.epub');
    expect(book.author, 'Charles Dickens');
    expect(book.chapters.length, 5,
        reason: 'nested illustration navPoints must not cut a stave; '
            'got ${book.chapters.map((c) => c.title).toList()}');
    expect(book.chapters.first.title, 'STAVE ONE.');
    expect(book.chapters.first.text, contains('Marley was dead'));
    // Each stave is substantial; a half-stave would be obvious here.
    for (final stave in book.chapters) {
      expect(stave.text.length, greaterThan(10000), reason: stave.title);
    }
  });

  test('chapters are cut at anchors inside shared documents', () {
    final book = read('pride_and_prejudice.epub');
    expect(book.title, 'Pride and Prejudice');
    expect(book.author, 'Jane Austen');
    // 61 chapters plus the front matter the navigation lists ahead of them.
    expect(book.chapters.length, greaterThanOrEqualTo(61));
    final titles = book.chapters.map((c) => c.title).toList();
    expect(titles, contains('CHAPTER II.'));
    expect(titles, contains('CHAPTER LXI.'));
    // Chapter II lives in the same file as III, IV, V and VI; if the cut were
    // per-file it would swallow them and run to tens of thousands of chars.
    final second = book.chapters.firstWhere((c) => c.title == 'CHAPTER II.');
    expect(second.text.length, lessThan(15000),
        reason: 'chapter II has absorbed its neighbours');
    expect(second.text, contains('Mr. Bennet'));
  });

  test('the Gutenberg licence is not treated as a chapter', () {
    for (final name in [
      'alice.epub',
      'christmas_carol.epub',
      'pride_and_prejudice.epub',
    ]) {
      for (final chapter in read(name).chapters) {
        expect(chapter.text, isNot(contains('START: FULL LICENSE')),
            reason: '$name: "${chapter.title}" is boilerplate, not prose');
      }
    }
  });

  test('extracted chapters split into paragraphs the pipeline can key on', () {
    // The whole cache is keyed by paragraph index, so extraction has to hand
    // the splitter something it can divide into real paragraphs rather than
    // one run-on block. Tags landing on the wrong prose would be silent.
    final chapter = read('alice.epub').chapters.first;
    final split = Book.fromText(chapter.title, chapter.text, source: 'alice/0');

    expect(split.paragraphs.length, greaterThan(5),
        reason: 'a chapter should be many paragraphs, not one');
    for (final paragraph in split.paragraphs) {
      expect(paragraph.length, greaterThanOrEqualTo(Book.minParagraphChars),
          reason: 'short blocks must have been folded forward');
      expect(paragraph, isNot(contains('\n')),
          reason: 'internal whitespace should be collapsed');
    }
    expect(split.paragraphAt(0), 0);
    expect(split.paragraphAt(split.text.length - 1), split.paragraphs.length - 1);
  });

  test('a file that is not an ePub fails with a readable message', () {
    final truncated =
        File('test/fixtures/alice.epub').readAsBytesSync().sublist(0, 200);
    expect(() => readEpub(truncated), throwsA(isA<EpubException>()));
  });
}
