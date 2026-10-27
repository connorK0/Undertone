// Shared setup for the integration tests.
//
// Since Phase 4 the app opens on a library rather than straight into a reader,
// so every one of these tests has to build the same four stores and then walk
// the same two taps to get to prose. That belongs in one place.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/library.dart';
import 'package:reader_shell/main.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/mood_trigger.dart';
import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/ollama_client.dart';
import 'package:reader_shell/page_reader.dart';
import 'package:reader_shell/settings.dart';

class Harness {
  Harness({
    required this.library,
    required this.cache,
    required this.pipeline,
    required this.engine,
    required this.settings,
  });

  final Library library;
  final MoodCache cache;
  final MoodPipeline pipeline;
  final MusicEngine engine;
  final Settings settings;

  Widget get app => ReaderApp(
        library: library,
        cache: cache,
        pipeline: pipeline,
        engine: engine,
        settings: settings,
      );

  Future<void> close() async {
    engine.dispose();
    await pipeline.settled;
    await cache.close();
    await library.close();
  }
}

/// Builds the app's stores on disk under build/, with the bundled samples
/// seeded. Not in memory: sqflite_common_ffi shares a single in-memory
/// database per process, so a Library and a MoodCache opened together would be
/// the same database and one of them would have no tables.
Future<Harness> buildHarness({
  OllamaClient? client,
  bool startAudio = false,
}) async {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final library = await Library.at('build/it_library_$stamp.db');
  await seedSamples(library);
  final settings = Settings(library);
  await settings.load();

  final cache = await MoodCache.at('build/it_cache_$stamp.db');
  final pipeline = MoodPipeline(client: client ?? OllamaClient(), cache: cache);
  moodPipeline = pipeline;

  final engine = MusicEngine();
  if (startAudio) await engine.start();
  engine.attach(pipeline);

  resetMoodTriggerLog();
  return Harness(
    library: library,
    cache: cache,
    pipeline: pipeline,
    engine: engine,
    settings: settings,
  );
}

/// Pumps real frames until [ready], or gives up. Returns how long it took.
Future<Duration> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration limit = const Duration(minutes: 3),
}) async {
  final started = DateTime.now();
  while (!ready() && DateTime.now().difference(started) < limit) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return DateTime.now().difference(started);
}

/// Opens a book from the library and waits for its prose.
///
/// Waiting for "a PageReader" alone is not enough anywhere in these tests: a
/// previous reader can still be mounted for a frame, so the wait returns at
/// once and everything after it measures the wrong book. The app bar title is
/// the reliable signal.
Future<void> openBook(WidgetTester tester, String title) async {
  await pumpUntil(tester, () => find.text(title).evaluate().isNotEmpty,
      limit: const Duration(seconds: 30));
  await tester.tap(find.text(title));
  await tester.pump();
  await pumpUntil(
    tester,
    () =>
        find.byType(PageReader).evaluate().isNotEmpty &&
        find.widgetWithText(AppBar, title).evaluate().isNotEmpty,
  );
}

/// Presses Right until a press registers.
///
/// The reader autofocuses a frame or two after it appears, and a press before
/// that lands on nothing.
Future<void> takeFocus(WidgetTester tester) async {
  final start = lastMoodTrigger.value!.position.page!;
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (lastMoodTrigger.value!.position.page == start &&
      DateTime.now().isBefore(deadline)) {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 50));
  }
}
