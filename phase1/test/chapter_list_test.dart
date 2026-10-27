// Getting to any chapter of a long book.
//
// The arrows in the app bar are fine for a twelve-chapter novel and useless
// for a serial with 862: chapter 3 to chapter 400 is 397 taps. What is tested
// here is the part that makes the list usable at that size -- filtering by the
// number someone actually types, and opening where they already are.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/chapter_list.dart';

List<String> chapters(int n) => [for (var i = 1; i <= n; i++) 'Chapter $i'];

class Opened {
  Future<int?>? result;
}

Future<Opened> open(
  WidgetTester tester, {
  int count = 862,
  int current = 3,
}) async {
  final opened = Opened();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => opened.result = showChapterList(
              context,
              title: 'A Long Serial',
              chapters: chapters(count),
              current: current,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('says how many chapters there are', (tester) async {
    final dialog = await open(tester);
    expect(find.textContaining('862 chapters'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await dialog.result, isNull);
  });

  testWidgets('opens at the chapter you are on, not at chapter 1',
      (tester) async {
    // On 862 chapters, opening at the top would mean scrolling to find where
    // you already are -- which is most of what the list is for.
    final dialog = await open(tester, current: 400);
    expect(find.text('Chapter 401'), findsOneWidget,
        reason: 'the current chapter should be on screen');
    expect(find.text('Chapter 1'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await dialog.result;
  });

  testWidgets('a typed number finds that chapter', (tester) async {
    final dialog = await open(tester);
    await tester.enterText(find.byType(TextField), '451');
    await tester.pumpAndSettle();

    expect(find.text('Chapter 451'), findsOneWidget);
    // 451, 1451... only the ones that exist, and far fewer than 862.
    expect(find.textContaining('matching'), findsOneWidget);

    await tester.tap(find.text('Chapter 451'));
    await tester.pumpAndSettle();
    expect(await dialog.result, 450, reason: 'chapter 451 is index 450');
  });

  testWidgets('choosing the chapter you are already on still answers',
      (tester) async {
    // The caller decides that this is a no-op; the list should not swallow it.
    final dialog = await open(tester, count: 12, current: 5);
    await tester.tap(find.text('Chapter 6'));
    await tester.pumpAndSettle();
    expect(await dialog.result, 5);
  });

  testWidgets('a filter that matches nothing says so', (tester) async {
    final dialog = await open(tester);
    await tester.enterText(find.byType(TextField), 'epilogue');
    await tester.pumpAndSettle();
    expect(find.text('Nothing by that name.'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await dialog.result;
  });

  testWidgets('works for a short book too', (tester) async {
    // Twelve rows is still more than the dialog shows at once, so this checks
    // that it opens at the top and that the far end is reachable -- not that
    // the whole book is on screen, which it is not.
    final dialog = await open(tester, count: 12, current: 0);
    expect(find.text('12 chapters'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '12');
    await tester.pumpAndSettle();
    expect(find.text('Chapter 12'), findsOneWidget);

    await tester.tap(find.text('Chapter 12'));
    await tester.pumpAndSettle();
    expect(await dialog.result, 11);
  });
}
