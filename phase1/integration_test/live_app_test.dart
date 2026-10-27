// The real Windows app against the real model: tags appearing on screen while
// reading, and the UI staying responsive while classification runs. Requires
// Ollama running with qwen2.5:7b. Run with:
//
//     flutter test integration_test/live_app_test.dart -d windows

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/ollama_client.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live: the reader shows real tags and stays responsive',
    (tester) async {
      final harness = await buildHarness(); // fresh stores: a cold start
      addTearDown(harness.close);
      final pipeline = harness.pipeline;
      await tester.pumpWidget(harness.app);

      await openBook(tester, 'Dracula, chapter I');
      await takeFocus(tester);
      final pageBefore = lastMoodTrigger.value!.position.page!;

      // --- The UI must not wait for the model ---------------------------
      expect(pipeline.status,
          anyOf(PipelineStatus.theme, PipelineStatus.classifying,
              PipelineStatus.idle));
      final turnStart = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      final turnMs = DateTime.now().difference(turnStart).inMilliseconds;
      expect(lastMoodTrigger.value!.position.page, pageBefore + 5,
          reason: 'five turns landed while the model was busy');
      expect(turnMs, lessThan(1000),
          reason: 'page turns must not block on classification');
      debugPrint('[live-app] 5 page turns during classification: ${turnMs}ms');

      // Go back to the start and wait for that paragraph to be tagged.
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
      }
      final waited = await pumpUntil(tester, () => pipeline.currentTag != null);
      expect(pipeline.currentTag, isNotNull,
          reason: 'the opening paragraph should get tagged');
      debugPrint(
        '[live-app] first tag on screen after ${waited.inMilliseconds}ms: '
        '${pipeline.currentTag} ("${pipeline.theme!.overallTheme}")',
      );

      // --- The tag is actually rendered, not just held in memory --------
      final tag = pipeline.currentTag!;
      expect(
        find.textContaining('${tag.mood} ${tag.intensity.toStringAsFixed(2)}'),
        findsOneWidget,
        reason: 'the banner shows the mood and intensity',
      );
      expect(find.textContaining('Mood tagging unavailable'), findsNothing);

      // --- Read forward; the banner should track the prose --------------
      final seen = <String>[];
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await pumpUntil(tester, () => pipeline.currentTag != null,
            limit: const Duration(seconds: 60));
        seen.add('p${pipeline.position}:${pipeline.currentTag!.mood}');
        // Exact text is checked once above, while the pipeline is quiet. Here
        // a batch can land between the read and the frame, so assert the
        // weaker invariant: the banner is showing a tag, not a placeholder.
        expect(find.textContaining('Mood tagging unavailable'), findsNothing);
        expect(find.textContaining('not tagged yet'), findsNothing);
      }
      debugPrint('[live-app] read 8 pages, banner tracked: ${seen.join(' ')}');
      expect(pipeline.tagCount, greaterThan(8));

      debugPrint(
        '[live-app] ${pipeline.tagCount} paragraphs tagged, '
        '${pipeline.client.requests} calls, theme '
        '"${pipeline.theme!.overallTheme}" / ${pipeline.theme!.genreSeed}',
      );

      // Let this pipeline finish before the next test starts. A batch left in
      // flight would compete with the next one for the single GPU, and two
      // concurrent requests to a local 7B make both slow enough to time out.
      await pumpUntil(tester, () => pipeline.status == PipelineStatus.idle,
          limit: const Duration(minutes: 3));
      expect(pipeline.status, PipelineStatus.idle);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'live: losing Ollama mid-session degrades, and recovers without a restart',
    (tester) async {
      final harness = await buildHarness();
      addTearDown(harness.close);
      final pipeline = harness.pipeline;
      final client = pipeline.client;
      await tester.pumpWidget(harness.app);

      await openBook(tester, 'Dracula, chapter I');
      await takeFocus(tester);

      // Reading normally, with tags arriving.
      await pumpUntil(tester, () => pipeline.currentTag != null);
      expect(pipeline.currentTag, isNotNull);
      debugPrint('[live-app] before: ${pipeline.currentTag}, '
          '${pipeline.tagCount} tagged');

      // Ollama goes away. Pointing the client at a closed port produces the
      // same connection refusal as stopping the service, without touching
      // this machine's Ollama install.
      client.baseUrl = 'http://localhost:1';
      // Keep reading into untagged territory. An idle pipeline has no reason
      // to contact Ollama, so the outage only surfaces once work is needed.
      // The pages turned here also show navigation is never gated on the
      // pipeline -- each one lands while tagging is failing.
      final pagesDuringOutage = <int>[];
      var turns = 0;
      while (pipeline.status != PipelineStatus.unavailable && turns < 25) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        pagesDuringOutage.add(lastMoodTrigger.value!.position.page!);
        await pumpUntil(
            tester, () => pipeline.status == PipelineStatus.unavailable,
            limit: const Duration(milliseconds: 300));
        turns++;
      }
      // Turning pages is what makes the pipeline try; noticing can take longer
      // than the turning does. A refused connection is instant, but a
      // connection to a closed port is not always refused promptly -- that is
      // the case ollamaTimeout (45s) exists to bound, so allow for it rather
      // than concluding the outage went unnoticed.
      final noticing = await pumpUntil(
          tester, () => pipeline.status == PipelineStatus.unavailable,
          limit: const Duration(seconds: 60));
      debugPrint(
        '[live-app] outage noticed after $turns page turns and a further '
        '${noticing.inMilliseconds}ms; '
        'pages went ${pagesDuringOutage.first}->${pagesDuringOutage.last}',
      );

      expect(pipeline.status, PipelineStatus.unavailable);
      expect(find.textContaining('Mood tagging unavailable'), findsOneWidget);
      expect(pagesDuringOutage.last, greaterThan(pagesDuringOutage.first),
          reason: 'navigation kept working while tagging was down');

      // Bring it back straight away. Every trigger retries, so lingering here
      // just fires more requests at a closed port -- and a second connection
      // to one does not always get refused promptly, which would wedge the
      // serial pump behind a request that only ends on the timeout.
      final tagsWhileDown = pipeline.tagCount;
      final callsWhileDown = client.requests;
      debugPrint(
        '[live-app] baseline at outage: paragraph ${pipeline.position}, '
        '$tagsWhileDown tagged, $callsWhileDown calls',
      );
      client.baseUrl = ollamaUrl;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await pumpUntil(tester, () => pipeline.tagCount > tagsWhileDown,
          limit: const Duration(seconds: 120));

      expect(pipeline.tagCount, greaterThan(tagsWhileDown),
          reason: 'new paragraphs tagged after recovery');
      expect(client.requests, greaterThan(callsWhileDown),
          reason: 'a real call went out after recovery');
      expect(pipeline.status, isNot(PipelineStatus.unavailable));
      expect(find.textContaining('Mood tagging unavailable'), findsNothing);
      debugPrint(
        '[live-app] after recovery: ${pipeline.tagCount} tagged '
        '(was $tagsWhileDown), ${client.requests} calls '
        '(was $callsWhileDown), no app restart',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
