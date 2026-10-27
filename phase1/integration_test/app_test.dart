// Drives the real Windows build: real clock, real fonts, real scroll physics.
// Only the input is synthesised. Run with:
//
//     flutter test integration_test/app_test.dart -d windows

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:reader_shell/page_reader.dart';
import 'package:reader_shell/reading_style.dart';
import 'package:reader_shell/scroll_reader.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Real time: long enough that any pending settle timer has fired.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(settleDelay + const Duration(milliseconds: 250));

  testWidgets(
    'triggers fire exactly once per navigation action on Windows',
    (tester) async {
      // Nothing listens on port 1, so the pipeline goes 'unavailable' on its
      // first call and stays out of the way. This test is about trigger
      // timing; the live pipeline has its own test. It doubles as the
      // 'Ollama is not running' case: the app must stay readable, and since
      // Phase 4 that includes importing and opening books.
      final harness = await buildHarness(
        client: OllamaClient(baseUrl: 'http://localhost:1'),
      );
      addTearDown(harness.close);
      await tester.pumpWidget(harness.app);

      // The app opens on the library now, so nothing is being read yet.
      await pumpUntil(tester,
          () => find.text('Dracula, chapter I').evaluate().isNotEmpty,
          limit: const Duration(seconds: 30));
      expect(moodTriggerCount, 0, reason: 'the shelf is not a book');

      await openBook(tester, 'Dracula, chapter I');
      expect(moodTriggerCount, 1, reason: 'opening a book fires once');
      expect(lastMoodTrigger.value!.position.reason, 'opened');
      final pageCount = lastMoodTrigger.value!.position.pageCount!;
      debugPrint('[test] Dracula ch.1 paginated into $pageCount pages');
      expect(pageCount, greaterThan(10));

      // Three deliberate page turns.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(moodTriggerCount, 4);
      expect(lastMoodTrigger.value!.position.page, 4);

      // Five as fast as the event loop allows: one trigger each, none merged.
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      expect(moodTriggerCount, 9, reason: 'fast flipping: one per turn');
      expect(lastMoodTrigger.value!.position.page, 9);

      // A held key: the press turns one page, the auto-repeats turn none.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(moodTriggerCount, 10, reason: 'held key: one turn, not eleven');
      expect(lastMoodTrigger.value!.position.page, 10);

      // Scroll mode. Switching is a fresh reader, so it announces itself.
      await tester.tap(find.text('Scroll'));
      await tester.pumpAndSettle();
      await pumpUntil(
          tester, () => find.byType(ScrollReader).evaluate().isNotEmpty);
      await tester.pump();
      expect(moodTriggerCount, 11);
      expect(lastMoodTrigger.value!.position.reason, 'opened');
      final list = find.byType(ScrollReader);

      // One slow scroll, then a pause: one trigger.
      await tester.drag(list, const Offset(0, -240));
      await settle(tester);
      expect(moodTriggerCount, 12);
      expect(lastMoodTrigger.value!.position.reason, 'scroll settled');
      expect(lastMoodTrigger.value!.position.paragraphIndex, greaterThan(0));

      // A burst of eight drags inside the settle window: nothing during,
      // exactly one after.
      for (var i = 0; i < 8; i++) {
        await tester.drag(list, const Offset(0, -160));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(moodTriggerCount, 12, reason: 'still moving: no trigger yet');
      await settle(tester);
      expect(moodTriggerCount, 13, reason: 'burst of scrolling: one trigger');

      // A fling: dozens of ballistic frames, one trigger after it stops.
      await tester.fling(list, const Offset(0, -500), 2500);
      await tester.pumpAndSettle();
      await settle(tester);
      expect(moodTriggerCount, 14, reason: 'fling: one trigger');

      // Mouse wheel: the way a desktop reader actually scrolls. Every tick is
      // its own start/update/end; twelve ticks must collapse to one trigger.
      final mouse = TestPointer(7, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(tester.getCenter(list)));
      for (var i = 0; i < 12; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 80)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(moodTriggerCount, 14, reason: 'wheel ticks: no trigger mid-scroll');
      await settle(tester);
      expect(moodTriggerCount, 15, reason: 'wheel ticks: one trigger once idle');
      final paragraph = lastMoodTrigger.value!.position.paragraphIndex;

      // Idle: nothing more fires on its own.
      await settle(tester);
      expect(moodTriggerCount, 15);

      // Ollama was never reachable, yet every navigation worked and the
      // banner says so rather than the app crashing or hanging.
      expect(harness.pipeline.status, PipelineStatus.unavailable);
      expect(harness.pipeline.currentTag, isNull);
      expect(find.textContaining('Mood tagging unavailable'), findsOneWidget);
      expect(
          find.byType(PageReader).evaluate().length +
              find.byType(ScrollReader).evaluate().length,
          1);

      debugPrint(
        '[test] 15 triggers: 1 book open, 9 page turns (1 from a held key), '
        '1 mode switch, 4 settled scrolls; final position paragraph $paragraph; '
        'readable throughout with Ollama unreachable',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
