// The whole thing on the real Windows build with the real model and real
// audio: open a book from the library, watch it prepare, read it with the
// score running. Run with:
//
//     flutter test integration_test/reading_with_music_test.dart -d windows
//
// Requires Ollama running with qwen2.5:7b.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/page_reader.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a prepared book opens with the music already playing',
    (tester) async {
      final harness = await buildHarness(startAudio: true);
      addTearDown(harness.close);
      final engine = harness.engine;
      final pipeline = harness.pipeline;
      expect(engine.available, isTrue, reason: 'no audio: ${engine.note}');

      await tester.pumpWidget(harness.app);
      await pumpUntil(tester,
          () => find.text('Dracula, chapter I').evaluate().isNotEmpty,
          limit: const Duration(seconds: 30));

      // Tap the book, then look at the moment before it is ready.
      await tester.tap(find.text('Dracula, chapter I'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PageReader), findsNothing,
          reason: 'the book should not open until it has been scored');
      expect(engine.playing, isNull,
          reason: 'music belongs to the open book, not the loading screen');
      expect(find.textContaining('Reading the book'), findsOneWidget);

      final prepared = await pumpUntil(
          tester, () => find.byType(PageReader).evaluate().isNotEmpty);
      debugPrint('[reading] prepared in ${prepared.inMilliseconds}ms');

      // --- The music is there for the first page ---------------------------
      final toSound = await pumpUntil(tester, () => engine.playing != null,
          limit: const Duration(seconds: 10));
      expect(engine.playing, isNotNull,
          reason: 'the point of preparing is that page one is not silent');
      expect(toSound.inSeconds, lessThan(3),
          reason: 'music should follow the first page, not trail it');
      debugPrint('[reading] opened on "${engine.playing}" after '
          '${toSound.inMilliseconds}ms, ${engine.crossfades} cue(s) so far');

      // It fades in rather than arriving whole.
      final atOpen = engine.playingVolume ?? 0;
      await pumpUntil(tester, () => (engine.playingVolume ?? 0) > atOpen,
          limit: const Duration(seconds: 4));
      expect(engine.playingVolume, greaterThan(atOpen),
          reason: 'the opening cue should be rising, not switched on');

      // --- Read forward; record what the score actually did ----------------
      final timeline = <String>[];
      final cuesAtStart = engine.crossfades;
      final readStarted = DateTime.now();
      var lastCue = engine.playing;
      for (var page = 0; page < 14; page++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await pumpUntil(tester, () => pipeline.currentTag != null,
            limit: const Duration(seconds: 25));
        final tag = pipeline.currentTag;
        final cue = engine.playing;
        timeline.add('p${pipeline.position}:${tag?.mood ?? '?'}'
            '${cue == lastCue ? '' : ' ->$cue'}');
        lastCue = cue;
      }
      final readElapsed = DateTime.now().difference(readStarted);
      final changes = engine.crossfades - cuesAtStart;
      debugPrint('[reading] ${timeline.join('  ')}');
      debugPrint('[reading] $changes cue changes over 14 pages in '
          '${readElapsed.inSeconds}s, now on "${engine.playing}" '
          '(${engine.current})');

      expect(engine.crossfades, greaterThan(0),
          reason: 'something has to have been playing');
      // The dwell is the actual guarantee: at most one change per dwell
      // period, however many pages went by.
      final allowed = readElapsed.inMilliseconds ~/
              CueSelector().minDwell.inMilliseconds +
          1;
      expect(changes, lessThanOrEqualTo(allowed),
          reason: 'at most one cue change per '
              '${CueSelector().minDwell.inSeconds}s of reading; $changes in '
              '${readElapsed.inSeconds}s is lurching');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'flipping pages fast does not produce a burst of crossfades',
    (tester) async {
      final harness = await buildHarness(startAudio: true);
      addTearDown(harness.close);
      final engine = harness.engine;
      final pipeline = harness.pipeline;
      expect(engine.available, isTrue, reason: '${engine.note}');

      await tester.pumpWidget(harness.app);
      await openBook(tester, 'Dracula, chapter I');
      await pumpUntil(tester, () => engine.playing != null,
          limit: const Duration(seconds: 30));

      // Read forward far enough that the pages being flipped already have
      // tags -- otherwise the flip crosses no mood boundary and proves
      // nothing about crossfading.
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await pumpUntil(tester, () => pipeline.currentTag != null,
            limit: const Duration(seconds: 25));
      }
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
      }

      final before = engine.crossfades;
      final startedAt = DateTime.now();
      final moods = <String>{};
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 40));
        final tag = pipeline.currentTag;
        if (tag != null) moods.add(tag.mood);
      }
      final elapsed = DateTime.now().difference(startedAt);
      final during = engine.crossfades - before;

      debugPrint('[reading] flipped 40 pages in ${elapsed.inMilliseconds}ms '
          'across ${moods.length} distinct moods ($moods): $during crossfade(s)');

      expect(moods.length, greaterThan(1),
          reason: 'the flip has to cross a mood boundary to prove anything');
      // The dwell is 15s; the flip is far shorter, so at most one change can
      // legitimately land.
      expect(during, lessThanOrEqualTo(1),
          reason: '40 page turns must not become a queue of crossfades');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
