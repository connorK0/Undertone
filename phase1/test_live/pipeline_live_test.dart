// Hits the real Ollama on this machine. Measures what the pipeline actually
// costs rather than asserting that it works. Requires Ollama running with
// qwen2.5:7b pulled. Run with:
//
//     flutter test test_live/pipeline_live_test.dart
//
// It lives in test_live/ rather than integration_test/ on purpose. Anything
// under integration_test/ is built and run as a real Windows app, which needs
// plugin symlinks, which need Developer Mode. This runs on the Dart VM
// instead and exercises the same pipeline, client and cache against real
// Ollama. It is outside test/ so the default `flutter test` run -- which must
// pass with Ollama closed -- does not pick it up.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/book.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/ollama_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test installs an HttpClient that fails every request. Real Ollama
  // calls are the entire point here, so restore the real one.
  setUpAll(() => HttpOverrides.global = null);

  testWidgets(
    'live: classification keeps ahead of a reader, and caches',
    (tester) async {
      await tester.runAsync(() async {
        final raw = File('assets/books/dracula_ch1.txt').readAsStringSync();
        final book =
            Book.fromText('Dracula, chapter I', raw, source: 'dracula_ch1.txt');
        debugPrint('[live] ${book.paragraphs.length} paragraphs, key ${book.key}');

        final cache = await MoodCache.inMemory(); // a guaranteed cold start
        final client = OllamaClient();
        final pipeline = MoodPipeline(client: client, cache: cache);

        // --- Cold start: nothing cached, reader opens the book -------------
        final coldStart = DateTime.now();
        await pipeline.setBook(book);
        await pipeline.settled;
        final coldMs = DateTime.now().difference(coldStart).inMilliseconds;

        expect(pipeline.theme, isNotNull, reason: 'theme pass must succeed');
        expect(pipeline.currentTag, isNotNull,
            reason: 'paragraph 0 must be tagged once settled');
        debugPrint(
          '[live] cold start: theme + ${pipeline.tagCount} paragraphs in '
          '${(coldMs / 1000).toStringAsFixed(1)}s '
          '(${client.requests} calls) -> "${pipeline.theme!.overallTheme}" / '
          '${pipeline.theme!.genreSeed}',
        );

        // --- Steady state: walk forward like a reader ----------------------
        // At each stop, was the paragraph already tagged when we arrived?
        var ready = 0;
        var waited = 0;
        var worstWaitMs = 0;
        for (var p = 1; p < book.paragraphs.length; p++) {
          pipeline.onPosition(p);
          if (pipeline.currentTag != null) {
            ready++;
          } else {
            waited++;
            final waitStart = DateTime.now();
            await pipeline.settled;
            final waitMs = DateTime.now().difference(waitStart).inMilliseconds;
            worstWaitMs = waitMs > worstWaitMs ? waitMs : worstWaitMs;
            debugPrint('[live] paragraph $p was not ready; waited ${waitMs}ms');
          }
          // A reader is not instant. This is far faster than real reading,
          // which is the point: if it keeps up here it keeps up in practice.
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await pipeline.settled;

        debugPrint(
          '[live] walked ${book.paragraphs.length - 1} paragraphs at 250ms '
          'each: $ready already tagged on arrival, $waited waited'
          '${waited == 0 ? '' : ' (worst ${worstWaitMs}ms)'}; '
          '${client.requests} calls total',
        );
        expect(pipeline.tagCount, book.paragraphs.length,
            reason: 'the whole chapter should end up tagged');

        // --- The tags themselves, to read against the prose ----------------
        final report = StringBuffer()
          ..writeln('theme: ${pipeline.theme!.overallTheme} / '
              '${pipeline.theme!.instrumentation} / '
              '${pipeline.theme!.genreSeed}');
        for (var p = 0; p < book.paragraphs.length; p++) {
          pipeline.onPosition(p);
          final tag = pipeline.currentTag!;
          final text = book.paragraphs[p];
          report.writeln('${p.toString().padLeft(2)}  '
              '${tag.mood.padRight(11)} ${tag.intensity.toStringAsFixed(2)}  '
              '${text.substring(0, text.length < 58 ? text.length : 58)}...');
        }
        debugPrint('[live] tags:\n$report');

        // --- Second run over the same cache: no calls at all ---------------
        final callsBefore = client.requests;
        final reopened = MoodPipeline(client: client, cache: cache);
        await reopened.setBook(book);
        await reopened.settled;
        for (var p = 0; p < book.paragraphs.length; p++) {
          reopened.onPosition(p);
          expect(reopened.currentTag, isNotNull, reason: 'paragraph $p cached');
          expect(reopened.currentSource, 'cache');
        }
        await reopened.settled;
        expect(client.requests, callsBefore,
            reason: 're-reading a tagged book must make no calls');
        debugPrint('[live] re-read whole chapter from cache: 0 new calls');

        // Leave the measurements somewhere readable after the run.
        final out = File('build/live_report.txt');
        final summary = jsonEncode({
          'paragraphs': book.paragraphs.length,
          'cold_start_ms': coldMs,
          'calls': client.requests,
          'ready_on_arrival': ready,
          'waited': waited,
          'worst_wait_ms': worstWaitMs,
        });
        await out.writeAsString('$summary\n\n$report');

        await cache.close();
      });
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
