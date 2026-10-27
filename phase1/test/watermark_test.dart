// Watermark detection, and -- much more importantly -- what it refuses to
// touch.
//
// The two mistakes this can make are not the same size. Leaving a stamp in is
// an annoyance; deleting a sentence the author wrote is data loss the reader
// may not notice for a hundred pages. So the negative cases below are the point
// of this file, and any new rule has to be added to them first.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/watermark.dart';

/// A paragraph of ordinary prose, long enough to be a real one.
String prose(int n) =>
    'Paragraph $n. The lamplighter walked his round and the fog came down '
    'over the river, and nobody in the street looked up at him once as he '
    'went by with his ladder on his shoulder.';

/// [count] chapters, each of [paragraphs] paragraphs, with [stamp] applied by
/// [place] to every one of them.
List<String> book({
  int count = 6,
  int paragraphs = 4,
  String? Function(int chapter)? stamp,
  bool atEnd = false,
}) {
  return [
    for (var c = 0; c < count; c++)
      [
        if (!atEnd && stamp?.call(c) != null) stamp!(c)!,
        for (var p = 0; p < paragraphs; p++) prose(c * 100 + p),
        if (atEnd && stamp?.call(c) != null) stamp!(c)!,
      ].join('\n\n'),
  ];
}

void main() {
  group('canonicalise', () {
    test('folds the things that vary between two printings of one stamp', () {
      expect(canonicalise('Read More At: Example.com/chapter-12'),
          canonicalise('read more   at: example.com/chapter-13'));
      expect(canonicalise('  spaced   out  '), 'spaced out');
    });
  });

  group('foldConfusables', () {
    // Ground truth. These are the exact code points of three occurrences of
    // one stamp in a real 862-chapter book -- taken from the file, not
    // constructed here, because a fold checked only against strings this test
    // generated would prove nothing about the real thing. Note that no two are
    // the same string: every occurrence mixes the styles differently, which is
    // the entire point of writing it that way.
    const real = [
      '\u{1D487}\u{1D493}\u{1D486}\u{1D486}\u{1D66C}\u{1D486}\u{1D483}'
          '\u{1D4F7}\u{1D490}\u{1D4FF}\u{1D65A}\u{1D661}.\u{1D484}\u{1D4F8}'
          '\u{1D48E}',
      '\u{1D487}\u{1D4FB}\u{1D4EE}\u{1D4EE}\u{1D66C}\u{1D65A}\u{1D483}'
          '\u{1D48F}\u{1D4F8}\u{1D66B}\u{1D486}\u{1D661}.\u{1D4EC}\u{1D4F8}'
          '\u{1D48E}',
      // This one borrows script small e (U+212F) from Letterlike Symbols,
      // where the maths block leaves a hole.
      '\u{1D4BB}\u{1D45F}\u{1D626}\u{1D626}\u{1D638}\u{212F}\u{1D4B7}'
          '\u{1D45B}\u{1D630}\u{1D4CB}\u{212F}\u{1D62D}.\u{1D624}\u{1D630}'
          '\u{1D62E}',
    ];

    test('reads a real stamp back as plain text', () {
      for (final styled in real) {
        expect(foldConfusables(styled), 'freewebnovel.com');
      }
      // And so all three count as one line rather than three.
      expect(real.map(canonicalise).toSet(), hasLength(1));
    });

    test('every style of every letter comes back', () {
      // The thirteen Latin styles are contiguous runs of 52, so one modulo
      // covers all of them. Checked across the whole block rather than at the
      // couple of points the real samples happen to touch.
      for (var style = 0; style < 13; style++) {
        final base = 0x1D400 + style * 52;
        final upper = String.fromCharCodes(
            [for (var i = 0; i < 26; i++) base + i]);
        final lower = String.fromCharCodes(
            [for (var i = 0; i < 26; i++) base + 26 + i]);
        expect(foldConfusables(upper), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
            reason: 'style $style capitals');
        expect(foldConfusables(lower), 'abcdefghijklmnopqrstuvwxyz',
            reason: 'style $style smalls');
      }
    });

    test('digits, full-width forms and invisible characters', () {
      for (var style = 0; style < 5; style++) {
        final digits = String.fromCharCodes(
            [for (var i = 0; i < 10; i++) 0x1D7CE + style * 10 + i]);
        expect(foldConfusables(digits), '0123456789');
      }
      expect(foldConfusables('ｆｒｅｅ'), 'free');
      // Zero-width characters sprinkled through a word are invisible to a
      // reader and fatal to a literal match.
      expect(foldConfusables('f​r‌ee﻿.com'), 'free.com');
    });

    test('leaves ordinary text exactly alone', () {
      // The fold only ever builds a matching key, but it should still be the
      // identity on anything a book is actually written in.
      const untouched = [
        'The lamplighter walked his round.',
        '"Don\'t," she said — and the door closed.',
        'naïve café résumé … “quoted”',
        'Ω ω π',
      ];
      for (final line in untouched) {
        expect(foldConfusables(line), line);
      }
    });

    test('a stamp in styled characters is found and removed', () {
      // End to end on the shape the real book uses: the stamp appended to a
      // paragraph, in different styles each time.
      final chapters = [
        for (var c = 0; c < 4; c++) '${prose(c)} ${real[c % real.length]}',
      ];
      final found = findWatermarks(chapters);
      expect(found, hasLength(1));
      expect(found.single.canonical, 'freewebnovel.com');
      expect(found.single.occurrences, 4);

      final keys = {found.single.canonical};
      for (var c = 0; c < 4; c++) {
        expect(removeWatermarks(chapters[c], keys), prose(c),
            reason: 'the paragraph survives, the stamp does not');
      }
    });
  });

  group('finds', () {
    test('the plain case: one line stamped on every chapter', () {
      final found = findWatermarks(
        book(stamp: (_) => 'Read more at: novelfull.com'),
      );
      expect(found, hasLength(1));
      expect(found.single.sample, 'Read more at: novelfull.com');
      expect(found.single.occurrences, 6);
      expect(found.single.chapters, 6);
      expect(found.single.inline, isFalse);
    });

    test('a stamp whose chapter number changes each time', () {
      // The reason the counting key masks digits. Matching literally would
      // find six different lines, each appearing once, and flag none of them.
      final found = findWatermarks(
        book(stamp: (c) => 'Read more at example.com/chapter-${c + 1}'),
      );
      expect(found, hasLength(1));
      expect(found.single.occurrences, 6);
    });

    test('a bare URL on its own line', () {
      final found = findWatermarks(book(stamp: (_) => 'www.freewebnovel.com'));
      expect(found.single.occurrences, 6);
      expect(found.single.reason, contains('web address'));
    });

    test('a stamp stuck on the end of a real paragraph', () {
      // The harder case: the block is prose *and* stamp, so removing the block
      // would take a paragraph with it.
      const tail = 'Visit our site at freenovel.com for more chapters.';
      final chapters = [
        for (var c = 0; c < 4; c++)
          [prose(c), '${prose(c + 50)} $tail', prose(c + 90)].join('\n\n'),
      ];
      final found = findWatermarks(chapters);
      expect(found, hasLength(1));
      expect(found.single.inline, isTrue);
      expect(found.single.sample, tail);

      // And removing it leaves the paragraph standing.
      final cleaned = removeWatermarks(chapters.first, {found.single.canonical});
      expect(cleaned, contains(prose(50)));
      expect(cleaned, isNot(contains('freenovel.com')));
      expect(cleaned.split('\n\n'), hasLength(3), reason: 'no block was lost');
    });

    test('two occurrences are enough when there is a URL, three when not', () {
      // A URL is the strongest signal there is, so it buys exactly one
      // occurrence of credit -- and no more than one.
      expect(findWatermarks(book(count: 2, stamp: (_) => 'read more at x.com')),
          hasLength(1));
      expect(findWatermarks(book(count: 2, stamp: (_) => 'Read more chapters')),
          isEmpty);
      expect(findWatermarks(book(count: 3, stamp: (_) => 'Read more chapters')),
          hasLength(1));
    });
  });

  group('refuses', () {
    test('a website the author mentioned once', () {
      final chapters = book();
      chapters[0] = '${chapters[0]}\n\nShe typed www.hollowaypress.com into '
          'the search bar and waited.';
      expect(findWatermarks(chapters), isEmpty,
          reason: 'appearing once is not evidence of anything');
    });

    test('a scene break, however many times it repeats', () {
      expect(findWatermarks(book(stamp: (_) => '* * *')), isEmpty);
      expect(findWatermarks(book(stamp: (_) => '· · ·')), isEmpty);
    });

    test('a refrain, which repeats but is asking nothing of the reader', () {
      expect(
        findWatermarks(book(stamp: (_) => 'And the raven, never flitting, '
            'still is sitting, still is sitting')),
        isEmpty,
      );
    });

    test('a repeated line with no signal at all', () {
      expect(findWatermarks(book(stamp: (_) => 'Chapter')), isEmpty);
      expect(findWatermarks(book(stamp: (_) => '"Yes," he said.')), isEmpty);
    });

    test('anything long enough to be a paragraph', () {
      // The length cap is what makes a mis-fire arithmetically unable to take
      // a paragraph with it, so it holds even when every other rule passes.
      final long = 'Read more at example.com. '
          '${List.filled(6, 'the lamplighter walked his round').join(', ')}.';
      expect(long.length, greaterThan(maxWatermarkChars));
      expect(findWatermarks(book(stamp: (_) => long)), isEmpty);
    });

    test('an ordinary book, which has nothing in it at all', () {
      expect(findWatermarks(book()), isEmpty);
      expect(findWatermarks(book(count: 1, paragraphs: 40)), isEmpty);
      expect(findWatermarks(const []), isEmpty);
      expect(findWatermarks(const ['']), isEmpty);
    });
  });

  group('removal', () {
    test('with nothing confirmed, the text comes back character for character',
        () {
      // A cleaner that quietly reformats a book it found nothing in would be
      // its own kind of data loss.
      for (final chapter in book(stamp: (_) => 'Read more at: novelfull.com')) {
        expect(removeWatermarks(chapter, const {}), chapter);
      }
    });

    test('takes the stamp and leaves every paragraph', () {
      final chapters = book(stamp: (_) => 'Read more at: novelfull.com');
      final marks = findWatermarks(chapters);
      final keys = {for (final m in marks) m.canonical};

      final cleaned = removeWatermarks(chapters.first, keys);
      expect(cleaned, isNot(contains('novelfull')));
      for (var p = 0; p < 4; p++) {
        expect(cleaned, contains(prose(p)));
      }
      expect(cleaned.split('\n\n'), hasLength(4));
    });

    test('removes it wherever it sits', () {
      for (final atEnd in [false, true]) {
        final chapters =
            book(stamp: (_) => 'www.freewebnovel.com', atEnd: atEnd);
        final keys = {for (final m in findWatermarks(chapters)) m.canonical};
        expect(keys, hasLength(1));
        for (final chapter in chapters) {
          expect(removeWatermarks(chapter, keys), isNot(contains('freeweb')));
        }
      }
    });

    test('a confirmed key that is not present changes nothing', () {
      final chapters = book();
      expect(removeWatermarks(chapters.first, {'read more at nowhere.com'}),
          chapters.first);
    });

    test('what it takes out is a rounding error on the book', () {
      // Chapter-sized chapters, deliberately: one stamp is a large share of a
      // four-paragraph fixture and a negligible one of a real chapter, and the
      // claim being made here is about real books. This is the number the
      // import dialog puts in front of the reader before anything is applied.
      final chapters =
          book(count: 20, paragraphs: 25, stamp: (_) => 'Read more at: nov.com');
      final keys = {for (final m in findWatermarks(chapters)) m.canonical};
      final total = chapters.fold<int>(0, (n, c) => n + c.length);
      final removed = removalSize(chapters, keys);

      // 460 of 91135 characters, or 0.5%, on chapters of about 4.5k. Real
      // chapters run three or four times that, so a real book lands nearer
      // 0.15%. Under 1% is the claim being made and the one worth holding.
      expect(removed, greaterThan(0));
      expect(removed / total, lessThan(0.01),
          reason: 'removed $removed of $total characters');
    });
  });

  group('a stamp landing on a short line', () {
    // The lesson from a real book. Of the blocks under 60 characters carrying
    // its stamp, almost all are a line of dialogue or a sound effect with the
    // stamp stuck on the end -- so treating the block as a watermark, which is
    // what the length and repetition rules would otherwise invite, deletes the
    // author's words. Only the stamp may come off.
    const stamp = 'freewebnovel.com';

    List<String> stamped(List<String> lines) => [
          for (final line in lines) '${prose(0)}\n\n$line $stamp\n\n${prose(1)}',
        ];

    test('the line survives and only the stamp is cut', () {
      const lines = [
        '"Sure..."',
        '-Knock! -Knock!',
        'High pressure',
        'That would be total hell.',
      ];
      final chapters = stamped(lines);
      final found = findWatermarks(chapters);
      expect(found.map((m) => m.canonical), contains(stamp));

      final keys = {for (final m in found) m.canonical};
      for (var i = 0; i < lines.length; i++) {
        final cleaned = removeWatermarks(chapters[i], keys);
        expect(cleaned, contains(lines[i]),
            reason: 'the line was the author\'s, not the distributor\'s');
        expect(cleaned, isNot(contains(stamp)));
        expect(cleaned.split('\n\n'), hasLength(3), reason: 'no block lost');
      }
    });

    test('a block that is only the stamp goes entirely', () {
      final chapters = [
        for (var c = 0; c < 4; c++) '${prose(c)}\n\n$stamp\n\n${prose(c + 1)}',
      ];
      final keys = {for (final m in findWatermarks(chapters)) m.canonical};
      final cleaned = removeWatermarks(chapters.first, keys);
      expect(cleaned.split('\n\n'), hasLength(2));
      expect(cleaned, isNot(contains('freewebnovel')));
    });

    test('what is left is kept even when it is only punctuation', () {
      // "*** <stamp>" is most likely the book's own scene break with the stamp
      // landed on it. Keeping the asterisks is the conservative reading, and
      // conservative is the whole brief.
      //
      // The stamp has to be commoner than this one arrangement of it, as it is
      // in a real book -- 187 occurrences against 3 -- or the two are
      // indistinguishable and the whole block is fairly read as the watermark.
      final chapters = [
        for (var c = 0; c < 12; c++)
          [
            '${prose(c)} $stamp',
            if (c < 3) '*** $stamp',
          ].join('\n\n'),
      ];
      final keys = {for (final m in findWatermarks(chapters)) m.canonical};
      expect(keys, {stamp});

      final cleaned = removeWatermarks(chapters.first, keys);
      expect(cleaned, contains('***'));
      expect(cleaned, isNot(contains('freewebnovel')));
    });

    test('no space in front of it is still found', () {
      // Seen in the wild: the stamp welded straight onto a closing quote.
      final chapters = [
        for (var c = 0; c < 4; c++)
          '${prose(c)}\n\n"No"$stamp\n\n${prose(c + 1)}',
      ];
      // It is discovered from the well-formed occurrences elsewhere...
      final keys = {stamp};
      final cleaned = removeWatermarks(chapters.first, keys);
      expect(cleaned, contains('"No"'));
      expect(cleaned, isNot(contains('freewebnovel')));
    });
  });

  group('subsumption', () {
    const stamp = 'freewebnovel.com';

    test('a line that is prose plus the stamp is not offered on its own', () {
      // Otherwise the reader is invited to tick a row that would delete
      // "Bang!" along with the stamp.
      final chapters = [
        for (var c = 0; c < 12; c++)
          [
            '${prose(c)} $stamp',
            if (c < 2) 'Bang! $stamp',
          ].join('\n\n'),
      ];
      final found = findWatermarks(chapters);
      expect(found.map((m) => m.canonical), [stamp],
          reason: 'one row, the stamp itself: ${found.map((m) => m.sample)}');

      // And removing that one key still cleans the "Bang!" line properly.
      final cleaned = removeWatermarks(chapters.first, {stamp});
      expect(cleaned, contains('Bang!'));
      expect(cleaned, isNot(contains('freewebnovel')));
    });

    test('a stamp that always appears whole keeps its full form', () {
      // Here "novelfull.com" is *only* ever the tail of "Read more at:
      // novelfull.com", so the two have identical counts. Dropping the longer
      // one would leave "Read more at:" behind in the book, which is why the
      // rule requires the shorter to be strictly better evidenced.
      final chapters = book(stamp: (_) => 'Read more at: novelfull.com');
      final found = findWatermarks(chapters);
      expect(found.map((m) => m.canonical), contains('read more at: '
          'novelfull.com'));

      final keys = {for (final m in found) m.canonical};
      final cleaned = removeWatermarks(chapters.first, keys);
      expect(cleaned, isNot(contains('Read more at')));
      expect(cleaned, isNot(contains('novelfull')));
    });
  });

  group('trailingSentence', () {
    test('will not cut a block that is nearly all tail', () {
      // Otherwise a short line of two sentences gets treated as a paragraph
      // plus a stamp, and the "paragraph" left behind is four words.
      expect(trailingSentence('Oh no. Read more at example.com'), isNull);
      expect(trailingSentence('${prose(1)} Read more at example.com'),
          'Read more at example.com');
    });

    test('is null when there is no sentence boundary', () {
      expect(trailingSentence('Read more at example.com'), isNull);
      expect(trailingSentence(''), isNull);
    });
  });
}
