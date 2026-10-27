// Where a book gets cut, and why there rather than somewhere else.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/arcs.dart';

/// Scores for a book where only the listed chapters look like fresh starts.
List<ChapterBreak> breaksAt(Map<int, double> scores, {Set<int> hard = const {}}) =>
    [
      for (final entry in scores.entries)
        ChapterBreak(
          index: entry.key,
          score: entry.value,
          situation: 'ch ${entry.key}',
          hard: hard.contains(entry.key),
        ),
      for (final index in hard)
        if (!scores.containsKey(index))
          ChapterBreak(
              index: index, score: 1, situation: 'ch $index', hard: true),
    ];

void main() {
  group('division headings', () {
    test('a real heading is recognised in the title or the first line', () {
      expect(isDivisionHeading('Volume Two', 'anything'), isTrue);
      expect(isDivisionHeading('Chapter 90', 'Book III\n\nThe rain...'), isTrue);
      expect(isDivisionHeading('Epilogue', ''), isTrue);
      expect(isDivisionHeading('Volume Two: The Long Winter', ''), isTrue);
      expect(isDivisionHeading('Part 4', ''), isTrue);
    });

    test('prose that merely contains the word is not a heading', () {
      // All three are real: the first two are lines from the book this was
      // built for, and the third is why a bare Roman numeral cannot be matched
      // without anchoring the end of the line too.
      expect(isDivisionHeading('Chapter 201.', 'The volume was heavier than '
          'he had expected, and the binding cracked as he opened it.'), isFalse);
      expect(isDivisionHeading('Chapter 2359.',
          'He set the volume of the amplifier and waited.'), isFalse);
      expect(isDivisionHeading('Chapter 5',
          'Book I loved as a child sat on the shelf.'), isFalse);
    });

    test('the book this was built for has no headings at all', () {
      // 2,364 chapters, every one titled like this. Pass 1 finding nothing is
      // the expected result, not a failure -- which is why pass 2 exists.
      for (final title in ['Chapter 1', 'Chapter 10.', 'Chapter 2364']) {
        expect(isDivisionHeading(title, 'He walked into the hall.'), isFalse,
            reason: title);
      }
    });
  });

  group('chapter digests', () {
    test('a long chapter keeps its opening and its closing', () {
      final body = '${'a' * 500} ${'z' * 500}';
      final digest = chapterDigest('Chapter 7', body, head: 40, tail: 20);
      expect(digest, startsWith('Chapter 7 | '));
      expect(digest, contains('[...]'));
      expect(digest, endsWith('z' * 20));
      expect(digest.length, lessThan(120));
    });

    test('a short chapter is kept whole, with its whitespace flattened', () {
      final digest = chapterDigest('Ch 1', 'one\n\n  two\tthree ');
      expect(digest, 'Ch 1 | one two three');
    });
  });

  group('chooseArcs', () {
    test('a book shorter than the maximum is a single arc', () {
      final arcs = chooseArcs(const [], 60, min: 50, max: 100);
      expect(arcs, hasLength(1));
      expect(arcs.single.start, 0);
      expect(arcs.single.end, 59);
    });

    test('the cut lands on the best-scoring chapter in the window', () {
      // 63 scores highest, and is inside [50, 100).
      final arcs = chooseArcs(
        breaksAt({55: 0.4, 63: 0.9, 71: 0.6, 90: 0.5}),
        160,
        min: 50,
        max: 100,
      );
      expect(arcs, hasLength(2));
      expect(arcs[0].end, 62);
      expect(arcs[1].start, 63);
    });

    test('a high score outside the window cannot pull the cut to it', () {
      // 20 is the obvious story break but a 20-chapter arc costs the same 32
      // beds as a 90-chapter one, so the floor wins and it is ignored.
      final arcs = chooseArcs(breaksAt({20: 1.0, 70: 0.3}), 160, min: 50, max: 100);
      expect(arcs[0].end, 69);
    });

    test('a declared division beats any score in the window', () {
      final arcs = chooseArcs(
        breaksAt({60: 0.95}, hard: {80}),
        200,
        min: 50,
        max: 100,
      );
      expect(arcs[1].start, 80, reason: 'the author said so');
    });

    test('with no scores at all it still cuts, at the floor', () {
      // The arithmetic fallback: a book being read before the scan has caught
      // up still gets arcs, they are just evenly spaced.
      final arcs = chooseArcs(const [], 300, min: 50, max: 100);
      expect(arcs.map((a) => a.start), [0, 50, 100, 150, 200]);
      expect(arcs.last.end, 299);
    });

    test('the tail is never a stub', () {
      // 210 chapters: cutting at 100 would leave 110, then 10. The refusal to
      // leave fewer than `min` is what stops that.
      final arcs = chooseArcs(const [], 210, min: 50, max: 100);
      for (final arc in arcs) {
        expect(arc.length, greaterThanOrEqualTo(50), reason: '$arc');
      }
    });

    test('every chapter belongs to exactly one arc', () {
      // The invariant that actually matters: a gap plays no music and an
      // overlap picks whichever arc was checked first.
      for (final count in [1, 49, 50, 101, 210, 999, 2364]) {
        final arcs = chooseArcs(
          breaksAt({for (var i = 0; i < count; i += 7) i: (i % 13) / 13}),
          count,
          min: 50,
          max: 100,
        );
        expect(arcs.first.start, 0, reason: '$count chapters');
        expect(arcs.last.end, count - 1, reason: '$count chapters');
        for (var i = 1; i < arcs.length; i++) {
          expect(arcs[i].start, arcs[i - 1].end + 1, reason: '$count chapters');
        }
        var covered = 0;
        for (final arc in arcs) {
          covered += arc.length;
          if (arcs.length > 1) {
            expect(arc.length, lessThanOrEqualTo(100), reason: '$arc');
          }
        }
        expect(covered, count, reason: '$count chapters');
      }
    });

    test('the real book comes out at a workable number of arcs', () {
      final arcs = chooseArcs(const [], 2364, min: 50, max: 100);
      expect(arcs.length, inInclusiveRange(24, 48));
      expect(arcIndexFor(arcs, 0), 0);
      expect(arcIndexFor(arcs, 2363), arcs.last.index);
      // Past the end clamps rather than throwing: generation may be behind.
      expect(arcIndexFor(arcs, 99999), arcs.last.index);
    });

    test('an arc is named by the chapter that opens it', () {
      final arcs = chooseArcs(breaksAt({70: 0.9}), 160, min: 50, max: 100);
      expect(arcs[1].title, 'ch 70');
      // With nothing to name it after, the range says so plainly rather than
      // inventing a title.
      expect(arcs[0].title, contains('Chapters 1-'));
    });
  });

  group('scanTargetFor', () {
    test('reaches one full arc past the reader, and no further', () {
      expect(scanTargetFor(0, 2364, max: 100), 101);
      expect(scanTargetFor(500, 2364, max: 100), 601);
    });

    test('stops at the end of the book', () {
      expect(scanTargetFor(2300, 2364, max: 100), 2364);
    });
  });
}
