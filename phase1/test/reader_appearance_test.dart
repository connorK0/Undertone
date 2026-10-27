// Changing the look of the page has to re-cut the page breaks.
//
// This is the one failure mode in the appearance work that is not obvious by
// looking: PageReader caches its page ranges against the window size, because
// re-laying out a whole chapter on every frame is not free. A font change at
// an unchanged window size therefore looked like "nothing to do" -- and the
// symptom is not an exception but text quietly running off the bottom of the
// page, or a page ending halfway up. So it is tested rather than trusted.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/book.dart';
import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/page_reader.dart';
import 'package:reader_shell/reading_style.dart';

Book longBook() => Book(
      title: 'Test',
      paragraphs: List.generate(
        60,
        (i) => 'Paragraph $i. '
            '${List.filled(8 + (i * 7) % 20, 'the lamplighter walked his round').join(' ')}.',
      ),
    );

Widget host(Widget reader) => MaterialApp(home: Scaffold(body: reader));

/// The page bar reads "Page 1 of N"; N is how the chapter was cut.
int pageCount(WidgetTester tester) {
  final text = tester
      .widgetList<Text>(find.textContaining('Page '))
      .map((t) => t.data!)
      .firstWhere((t) => t.contains(' of '));
  return int.parse(text.split(' of ').last);
}

void main() {
  setUp(resetMoodTriggerLog);

  testWidgets('a bigger font re-cuts the chapter into more pages',
      (tester) async {
    final book = longBook();
    await tester.pumpWidget(
      host(PageReader(book: book, style: const ReadingStyle(fontSize: 15))),
    );
    await tester.pumpAndSettle();
    final small = pageCount(tester);

    // Same widget, same window, only the style differs -- exactly the case the
    // size-keyed cache used to miss.
    await tester.pumpWidget(
      host(PageReader(book: book, style: const ReadingStyle(fontSize: 26))),
    );
    await tester.pumpAndSettle();
    final large = pageCount(tester);

    expect(large, greaterThan(small),
        reason: 'larger type must mean more pages; got $small then $large');
  });

  testWidgets('looser line spacing re-cuts it too', (tester) async {
    // Spacing changes the line height without changing the font size, so a
    // cache keyed on the size alone would also have missed this one.
    final book = longBook();
    await tester.pumpWidget(host(PageReader(
      book: book,
      style: const ReadingStyle(spacing: LineSpacing.compact),
    )));
    await tester.pumpAndSettle();
    final compact = pageCount(tester);

    await tester.pumpWidget(host(PageReader(
      book: book,
      style: const ReadingStyle(spacing: LineSpacing.relaxed),
    )));
    await tester.pumpAndSettle();
    expect(pageCount(tester), greaterThan(compact));
  });

  testWidgets('changing the look keeps your place', (tester) async {
    // The reader holds a character offset, not a page number, precisely so
    // that re-cutting the pages does not send you back to the beginning.
    final book = longBook();
    await tester.pumpWidget(host(PageReader(book: book)));
    await tester.pump();

    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    final before = lastMoodTrigger.value!.position.paragraphIndex;
    expect(before, greaterThan(0), reason: 'the test needs to have moved');

    await tester.pumpWidget(host(PageReader(
      book: book,
      style: const ReadingStyle(fontSize: 24),
    )));
    await tester.pump();

    // One more turn reports from the freshly cut pages. Bigger type means
    // fewer paragraphs to a page, so this lands within a paragraph or two of
    // where it was -- and nowhere near the start, which is what losing the
    // anchor would look like.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final after = lastMoodTrigger.value!.position.paragraphIndex;
    expect(after, closeTo(before, 3),
        reason: 'was at paragraph $before, resized to paragraph $after');
  });

  testWidgets('the page bar knows the count on the frame the chapter opens',
      (tester) async {
    // It did not. Pagination happens inside a LayoutBuilder, and the bar is a
    // sibling built before layout runs, so it was handed a count of zero --
    // "Page 1 of 0", with both its arrows disabled, until some unrelated
    // rebuild came along. Keys and tapping the page still turned, which is why
    // nobody noticed.
    await tester.pumpWidget(host(PageReader(book: longBook())));
    await tester.pump();

    expect(find.textContaining('Page 1 of 0'), findsNothing);
    expect(pageCount(tester), greaterThan(1));

    final next = find.byTooltip('Next page (Right, PageDown, Space)');
    await tester.tap(next);
    await tester.pump();
    expect(lastMoodTrigger.value!.position.page, 2,
        reason: 'the button on the bar has to turn a page');
  });
}
