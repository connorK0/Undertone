import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:reader_shell/book.dart';
import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/inspector_panel.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/ollama_client.dart';

/// Answers instantly with a known theme and a mood that alternates, so the
/// panel has something real to show without needing Ollama.
http.Client fakeOllama() => MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final properties =
          (body['format'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      final user = (body['messages'] as List).last['content'] as String;

      Object payload;
      if (properties.containsKey('overall_theme')) {
        payload = {
          'overall_theme': 'brooding coastal mystery',
          'instrumentation': 'solo cello, low piano',
          'genre_seed': 'cinematic-noir',
        };
      } else {
        final indices = RegExp(r'^\[(\d+)\]$', multiLine: true)
            .allMatches(user)
            .map((m) => int.parse(m.group(1)!));
        payload = {
          'paragraphs': [
            for (final i in indices)
              {
                'index': i,
                'mood': i.isEven ? 'tense' : 'calm',
                'intensity': i.isEven ? 0.8 : 0.2,
                'reason': 'because paragraph $i says so',
              },
          ],
        };
      }
      return http.Response(
        jsonEncode({
          'message': {'content': jsonEncode(payload)}
        }),
        200,
      );
    });

Book testBook() => Book(
      title: 'Test Chapter',
      source: 'test.txt',
      paragraphs: List.generate(
        20,
        (i) => 'Paragraph $i. The lamplighter walked his round once more, and '
            'the fog came down over the harbour wall.',
      ),
    );

void main() {
  late MoodCache cache;
  late MoodPipeline pipeline;
  late MusicEngine engine;

  setUp(() async {
    cache = await MoodCache.inMemory();
    pipeline = MoodPipeline(client: OllamaClient(client: fakeOllama()), cache: cache);
    // Eager, so the panel has a committed cue and a history to show without
    // the test having to wait out a dwell.
    engine = MusicEngine(
      selector: CueSelector(minDwell: Duration.zero, confirmations: 1),
    );
  });

  tearDown(() async {
    engine.dispose();
    await cache.close();
  });

  /// The panel is a lazy ListView, so anything below the fold is never built
  /// and `find` cannot see it. A tall surface puts every section on screen at
  /// once, which is what these tests are about.
  Future<void> show(WidgetTester tester, [MusicEngine? which]) async {
    await tester.binding.setSurfaceSize(const Size(520, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InspectorPanel(
          pipeline: pipeline,
          engine: which ?? engine,
          title: 'Test Chapter',
          chapter: 0,
          chapterCount: 3,
        ),
      ),
    ));
    await tester.pump();
  }

  /// Unmount, so the panel's polling timer is cancelled before the test ends.
  Future<void> hide(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  /// The value shown against one label. Needed because the same word appears
  /// in several places on purpose -- 'calm' is both the cue being played and
  /// the mood it came from -- so a bare text search cannot tell them apart.
  Finder valueOf(String label, String value) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
        matching: find.text(value),
      );

  testWidgets('shows the chain from book to cue', (tester) async {
    // The classifier round trip has to run outside the fake clock. A widget
    // test's zone does not fire timers unless the tester pumps, and the http
    // client's own timeout is one -- so awaiting the pipeline here without
    // runAsync waits forever. (test/pipeline_test.dart gets away with plain
    // awaits because it uses test(), which has no fake clock.)
    await tester.runAsync(() async {
      await pipeline.setBook(testBook());
      await pipeline.settled;
    });

    // open() records the window, picks a cue and logs it, all synchronously,
    // so there is nothing further to wait for.
    engine.attach(pipeline);
    engine.open();

    await show(tester);

    // The theme, which is upstream of every tag.
    expect(find.text('brooding coastal mystery'), findsOneWidget);
    expect(find.text('cinematic-noir'), findsOneWidget);

    // The classifier's own justification -- carried since Phase 1 and never
    // shown to anyone until now.
    expect(find.textContaining('because paragraph 0 says so'), findsOneWidget);

    // The window the cue was actually decided over, with its weights.
    expect(find.textContaining('×1.00'), findsOneWidget);
    expect(find.textContaining('×0.50'), findsOneWidget);

    // The lineage line, which is the whole path from book down to file rather
    // than five rows the reader has to join up themselves.
    // Calm: the fixture alternates tense and calm, and since SUMMARY 9.43
    // a calm paragraph's vote counts minorityWeight times, so the window
    // (tense, calm, tense, calm) is calm's.
    expect(find.textContaining('  →  calm'), findsOneWidget,
        reason: 'the branch line should compose theme -> cue');

    // And every section is present rather than silently empty.
    for (final heading in ['BOOK', 'CLASSIFIER', 'CUE SELECTION', 'MUSIC']) {
      expect(find.text(heading), findsOneWidget, reason: '$heading is missing');
    }
    await hide(tester);
    // open() started the idle timer; close it so no timer outlives the test.
    await engine.close();
  });

  testWidgets('says what a pending change is waiting for', (tester) async {
    // The state most in need of explaining: a new mood has been seen but the
    // music has not moved yet, and nothing on screen says why.
    final waiting = MusicEngine(
      selector: CueSelector(minDwell: const Duration(minutes: 5), confirmations: 3),
    );
    addTearDown(waiting.dispose);
    final theme = BookTheme(
      overallTheme: 'brooding coastal mystery',
      instrumentation: 'solo cello',
      genreSeed: 'cinematic-noir',
    );

    await waiting.observe(
        paragraphIndex: 0, params: mapToMusicParams('calm', 0.2, theme));
    await waiting.observe(
        paragraphIndex: 1, params: mapToMusicParams('tense', 0.8, theme));

    await show(tester, waiting);

    expect(valueOf('playing cue', 'calm'), findsOneWidget,
        reason: 'calm is still playing');
    expect(find.textContaining('tense  (1 of 3 paragraphs)'), findsOneWidget,
        reason: 'the panel should say how far a change has got');
    expect(find.textContaining('dwell blocks a change'), findsOneWidget,
        reason: 'and that the dwell is the other thing holding it');
    await hide(tester);
  });

  testWidgets('logs cue changes with the mood behind them', (tester) async {
    final theme = BookTheme(
      overallTheme: 'brooding coastal mystery',
      instrumentation: 'solo cello',
      genreSeed: 'cinematic-noir',
    );
    await engine.observe(
        paragraphIndex: 3, params: mapToMusicParams('calm', 0.2, theme));
    await engine.observe(
        paragraphIndex: 4, params: mapToMusicParams('tense', 0.8, theme));

    await show(tester);

    expect(engine.history.length, 2);
    expect(find.textContaining('p4  tense'), findsOneWidget);
    expect(find.textContaining('p3  calm'), findsOneWidget);
    await hide(tester);
  });
}
