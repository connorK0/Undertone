import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/book.dart';
import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/page_reader.dart';
import 'package:reader_shell/reading_style.dart';
import 'package:reader_shell/scroll_reader.dart';

/// Enough prose to scroll and page through: sixty paragraphs, varied length.
Book longBook() => Book(
      title: 'Test',
      paragraphs: List.generate(
        60,
        (i) => 'Paragraph $i. '
            '${List.filled(8 + (i * 7) % 20, 'the lamplighter walked his round').join(' ')}.',
      ),
    );

Widget host(Widget reader) => MaterialApp(home: Scaffold(body: reader));

/// The settle timer plus a little, so a pending debounce has fired.
final afterSettle = settleDelay + const Duration(milliseconds: 50);

void main() {
  setUp(resetMoodTriggerLog);

  group('scroll mode', () {
    testWidgets('opening fires once, at paragraph 0', (tester) async {
      await tester.pumpWidget(host(ScrollReader(book: longBook())));
      await tester.pump();
      expect(moodTriggerCount, 1);
      expect(lastMoodTrigger.value!.position.reason, 'opened');
      expect(lastMoodTrigger.value!.position.paragraphIndex, 0);
    });

    testWidgets('a burst of scrolling settles into exactly one trigger',
        (tester) async {
      await tester.pumpWidget(host(ScrollReader(book: longBook())));
      await tester.pump();
      expect(moodTriggerCount, 1);

      // Five quick drags, each well inside the settle window of the last.
      for (var i = 0; i < 5; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -250));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(moodTriggerCount, 1, reason: 'nothing fires while still moving');

      await tester.pump(afterSettle);
      expect(moodTriggerCount, 2, reason: 'one firing once settled');
      final position = lastMoodTrigger.value!.position;
      expect(position.reason, 'scroll settled');
      expect(position.mode, ReadingMode.scroll);
      expect(position.paragraphIndex, greaterThan(0));

      // Settled and idle: nothing more.
      await tester.pump(afterSettle);
      expect(moodTriggerCount, 2);
    });

    testWidgets('a fling fires once, after the momentum ends', (tester) async {
      await tester.pumpWidget(host(ScrollReader(book: longBook())));
      await tester.pump();

      await tester.fling(find.byType(ListView), const Offset(0, -600), 2500);
      // Ballistic scrolling emits an update every frame; none of them fire.
      await tester.pump(const Duration(milliseconds: 100));
      expect(moodTriggerCount, 1);
      await tester.pumpAndSettle();
      await tester.pump(afterSettle);
      expect(moodTriggerCount, 2);
      expect(lastMoodTrigger.value!.position.paragraphIndex, greaterThan(0));
    });

    testWidgets('scrolling back to the top reports paragraph 0',
        (tester) async {
      await tester.pumpWidget(host(ScrollReader(book: longBook())));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      // In the app a frame renders within a few ms of the last scroll event,
      // long before the settle timer. The test clock elapses time before it
      // renders, so pump the frame explicitly or the timer measures a layout
      // that predates the drag.
      await tester.pump();
      await tester.pump(afterSettle);
      expect(lastMoodTrigger.value!.position.paragraphIndex, greaterThan(0));

      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pump();
      await tester.pump(afterSettle);
      expect(moodTriggerCount, 3);
      expect(lastMoodTrigger.value!.position.paragraphIndex, 0);
    });
  });

  group('pages mode', () {
    testWidgets('opening fires once, on page 1 of several', (tester) async {
      await tester.pumpWidget(host(PageReader(book: longBook())));
      await tester.pump();
      expect(moodTriggerCount, 1);
      final position = lastMoodTrigger.value!.position;
      expect(position.reason, 'opened');
      expect(position.page, 1);
      expect(position.pageCount, greaterThan(3));
      expect(position.paragraphIndex, 0);
    });

    testWidgets('each deliberate key press turns one page and fires once',
        (tester) async {
      await tester.pumpWidget(host(PageReader(book: longBook())));
      await tester.pump();

      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      expect(moodTriggerCount, 4);
      expect(lastMoodTrigger.value!.position.page, 4);
      expect(lastMoodTrigger.value!.position.reason, 'page turn');
      expect(find.text('Page 4 of ${lastMoodTrigger.value!.position.pageCount}'),
          findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(moodTriggerCount, 5);
      expect(lastMoodTrigger.value!.position.page, 3);
    });

    testWidgets('a held key (auto-repeat) does not flip pages', (tester) async {
      await tester.pumpWidget(host(PageReader(book: longBook())));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(moodTriggerCount, 2, reason: 'the press counts, the repeats do not');
      expect(lastMoodTrigger.value!.position.page, 2);
    });

    testWidgets('tapping the right half turns forward, the left half back',
        (tester) async {
      await tester.pumpWidget(host(PageReader(book: longBook())));
      await tester.pump();

      final page = find.byType(ClipRect).first;
      final rect = tester.getRect(page);
      await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
      await tester.pump();
      expect(lastMoodTrigger.value!.position.page, 2);
      await tester.tapAt(Offset(rect.left + 20, rect.center.dy));
      await tester.pump();
      expect(lastMoodTrigger.value!.position.page, 1);
      expect(moodTriggerCount, 3);
    });

    testWidgets('the page paragraph index advances through the book',
        (tester) async {
      final book = longBook();
      await tester.pumpWidget(host(PageReader(book: book)));
      await tester.pump();
      final count = lastMoodTrigger.value!.position.pageCount!;

      var lastParagraph = -1;
      for (var i = 1; i < count; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        final paragraph = lastMoodTrigger.value!.position.paragraphIndex;
        expect(paragraph, greaterThanOrEqualTo(lastParagraph));
        lastParagraph = paragraph;
      }
      expect(lastMoodTrigger.value!.position.page, count);
      expect(lastParagraph, greaterThan(book.paragraphs.length ~/ 2));

      // Past the last page: no turn, no trigger.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(moodTriggerCount, count);
    });

    testWidgets('back from the first page is the previous chapter',
        (tester) async {
      var previous = 0;
      await tester.pumpWidget(host(PageReader(
        book: longBook(),
        onPreviousChapter: () => previous++,
      )));
      await tester.pump();

      // The key, the left half of the page, and the bar's own button.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      final rect = tester.getRect(find.byType(ClipRect).first);
      await tester.tapAt(Offset(rect.left + 20, rect.center.dy));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(previous, 3);
      expect(moodTriggerCount, 1, reason: 'no page turned inside this chapter');
    });

    testWidgets('on the first chapter, back from the first page does nothing',
        (tester) async {
      await tester.pumpWidget(host(PageReader(book: longBook())));
      await tester.pump();
      final back = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_left));
      expect(back.onPressed, isNull);
    });

    testWidgets('a chapter entered by turning back opens on its last page',
        (tester) async {
      await tester.pumpWidget(
          host(PageReader(book: longBook(), startAtEnd: true)));
      await tester.pump();
      final position = lastMoodTrigger.value!.position;
      expect(position.reason, 'opened');
      expect(position.page, position.pageCount);
      expect(find.text('Page ${position.pageCount} of ${position.pageCount}'),
          findsOneWidget);
    });
  });

  group('pagination', () {
    testWidgets('every character lands on exactly one page, in order',
        (tester) async {
      final book = longBook();
      final pages = paginate(
        book.text,
        defaultReadingStyle.textStyle,
        const Size(640, 480),
        TextScaler.noScaling,
      );
      expect(pages.length, greaterThan(3));
      expect(pages.first.start, 0);
      expect(pages.last.end, book.text.length);
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start, greaterThan(pages[i - 1].start));
        // The gap between pages is only ever the newline that ended a line.
        expect(pages[i].start - pages[i - 1].end, inInclusiveRange(0, 2));
      }
    });
  });
}
