// The percentage on the app bar.
//
// It is a number the reader will check against their own sense of where they
// are, so the ends matter more than the middle: opening a book must read 0,
// and nothing before the last page of the last chapter may read 100.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/reader_screen.dart';

ReadingPosition page(int page, int of, {int paragraph = 0}) => ReadingPosition(
      paragraphIndex: paragraph,
      mode: ReadingMode.pages,
      reason: 'page turn',
      page: page,
      pageCount: of,
    );

ReadingPosition scrolled(int paragraph) => ReadingPosition(
      paragraphIndex: paragraph,
      mode: ReadingMode.scroll,
      reason: 'scroll settled',
    );

void main() {
  test('opening a book is zero, not one chapter in', () {
    expect(bookProgress(chapter: 0, chapterCount: 12), 0);
    expect(
      bookProgress(chapter: 0, chapterCount: 12, position: page(1, 34)),
      0,
      reason: 'page 1 of 34 is the start of the chapter, not 1/34 into it',
    );
  });

  test('chapters and pages both move it', () {
    // Half way through chapter 7 of 12.
    final half = bookProgress(
        chapter: 6, chapterCount: 12, position: page(18, 34));
    expect(half, closeTo((6 + 17 / 34) / 12, 1e-9));

    // A chapter turn moves it by exactly one chapter's worth.
    final next = bookProgress(chapter: 7, chapterCount: 12, position: page(1, 34));
    expect(next - bookProgress(chapter: 6, chapterCount: 12, position: page(1, 34)),
        closeTo(1 / 12, 1e-9));
  });

  test('the last page of the last chapter is under 100%, and reads as 100', () {
    final end = bookProgress(
        chapter: 861, chapterCount: 862, position: page(34, 34));
    expect(end, lessThan(1.0));
    expect((100 * end).toStringAsFixed(0), '100');
  });

  test('scrolling uses paragraphs, since it has no pages', () {
    expect(
      bookProgress(
        chapter: 1,
        chapterCount: 4,
        position: scrolled(18),
        paragraphCount: 36,
      ),
      closeTo((1 + 0.5) / 4, 1e-9),
    );
  });

  test('a serial with hundreds of chapters still moves within one', () {
    // The reason the within-chapter part exists at all: on 862 chapters, a
    // whole chapter is barely a tenth of a percent, so without it the number
    // would sit still for an entire sitting.
    final start = bookProgress(
        chapter: 400, chapterCount: 862, position: page(1, 40));
    final end = bookProgress(
        chapter: 400, chapterCount: 862, position: page(40, 40));
    expect(end, greaterThan(start));
    expect(end - start, closeTo((39 / 40) / 862, 1e-9));
  });

  test('nothing divides by zero', () {
    expect(bookProgress(chapter: 0, chapterCount: 0), 0);
    expect(bookProgress(chapter: 3, chapterCount: 4, position: page(1, 0)),
        closeTo(3 / 4, 1e-9));
    expect(
      bookProgress(
          chapter: 3, chapterCount: 4, position: scrolled(9), paragraphCount: 0),
      closeTo(3 / 4, 1e-9),
    );
  });

  test('it never leaves 0..1', () {
    // Progress saved against a book that has since been re-imported shorter is
    // the realistic way this goes out of range.
    expect(bookProgress(chapter: 99, chapterCount: 4), 1.0);
    expect(
      bookProgress(chapter: 3, chapterCount: 4, position: page(99, 10)),
      1.0,
    );
  });
}
