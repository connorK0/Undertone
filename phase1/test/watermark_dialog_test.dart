// The dialog is where the guarantee actually lives: the rules in
// watermark.dart only make the list short enough to read, and a person reading
// it is what makes the removal safe. So what is tested here is that saying no
// works -- in both of the ways a reader can say it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/watermark.dart';
import 'package:reader_shell/watermark_dialog.dart';

const _found = [
  Watermark(
    canonical: 'read more at freewebnovel.com',
    sample: 'Read more at freewebnovel.com',
    occurrences: 24,
    chapters: 12,
    reason: 'repeats, and contains a web address',
    inline: false,
  ),
  Watermark(
    canonical: 'latest chapters at example.org',
    sample: 'Latest chapters at example.org',
    occurrences: 12,
    chapters: 12,
    reason: 'repeats, and contains a web address',
    inline: true,
  ),
];

/// The dialog, open, with its answer still pending.
///
/// The future must not be awaited inside onPressed: the dialog is only
/// interactive while it is unresolved, and awaiting a guarded tester call from
/// inside another one is an error.
class OpenDialog {
  Future<Set<String>?>? result;
}

Future<OpenDialog> open(WidgetTester tester) async {
  final dialog = OpenDialog();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => dialog.result = confirmWatermarks(
              context,
              title: 'A Downloaded Book',
              found: _found,
              totalChars: 400000,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return dialog;
}

void main() {
  testWidgets('shows the text, the count and the share of the book',
      (tester) async {
    final dialog = await open(tester);

    // The literal line, not the canonical key, because the key is unreadable.
    expect(find.text('Read more at freewebnovel.com'), findsOneWidget);
    expect(find.textContaining('24 times in 12 chapters'), findsOneWidget);
    // And that cutting into a paragraph is called out as different.
    expect(find.textContaining('end of a paragraph'), findsOneWidget);
    expect(find.textContaining('% of the book'), findsOneWidget);

    await tester.tap(find.text('Keep everything'));
    await tester.pumpAndSettle();
    await dialog.result;
  });

  testWidgets('"Keep everything" removes nothing', (tester) async {
    final dialog = await open(tester);
    await tester.tap(find.text('Keep everything'));
    await tester.pumpAndSettle();
    expect(await dialog.result, isNull,
        reason: 'null means leave the book alone');
  });

  testWidgets('unchecking one leaves it in the book', (tester) async {
    // The case that matters. Everything is checked to begin with, because the
    // list is evidence-backed -- but a reader who recognises one of these as
    // something the author wrote has to be able to keep it, and have that
    // actually happen.
    final dialog = await open(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove selected'));
    await tester.pumpAndSettle();

    expect(await dialog.result, {_found[1].canonical},
        reason: 'only the one still ticked');
  });

  testWidgets('with nothing ticked there is nothing to press', (tester) async {
    final dialog = await open(tester);

    for (final checkbox in find.byType(Checkbox).evaluate().toList()) {
      await tester.tap(find.byWidget(checkbox.widget));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('left exactly as it is'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'removing nothing is not an action',
    );

    await tester.tap(find.text('Keep everything'));
    await tester.pumpAndSettle();
    await dialog.result;
  });
}
