// What the score would actually do over a whole chapter, without reading one.
//
//     flutter test test_live/cue_timeline_test.dart
//
// Requires Ollama with qwen2.5:7b. Classifies every bundled chapter, then
// replays the tags through the real dominantTag and CueSelector at reading
// pace and prints the cue the reader would hear at each paragraph.
//
// This exists because the honest question of the phase -- does the music help
// -- takes forty minutes a chapter to answer by reading, and the first thing
// you need to know is much cheaper: does this text give the score anything to
// do at all? A chapter the classifier hears as one mood throughout will sound
// like one held chord no matter how good the engine is, and that is a property
// of the book, not a bug to chase in the audio.
//
// Results are cached on disk in build/, so only the first run pays for it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/book.dart';
import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/ollama_client.dart';

const books = {
  'christmas_carol_stave1.txt': 'A Christmas Carol, stave I',
  'dracula_ch1.txt': 'Dracula, chapter I',
  'alice_ch1.txt': 'Alice in Wonderland, chapter I',
  'chapter1.txt': "The Lamplighter's Round",
};

/// Roughly how long a reader spends on a paragraph. Well past the cue's 15s
/// dwell, so what this measures is the confirmation rule and the prose --
/// which is what a real reader experiences.
const readingPace = Duration(seconds: 40);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('live: the cue timeline of every bundled chapter', (tester) async {
    await tester.runAsync(() async {
      final report = StringBuffer();
      final cache = await MoodCache.at('build/cue_timeline.db');
      final client = OllamaClient();

      for (final entry in books.entries) {
        final raw = File('assets/books/${entry.key}').readAsStringSync();
        final book = Book.fromText(entry.value, raw, source: entry.key);
        final pipeline = MoodPipeline(client: client, cache: cache);
        await pipeline.setBook(book);

        // Walk the whole chapter so every paragraph gets a tag.
        for (var p = 0; p < book.paragraphs.length; p++) {
          pipeline.onPosition(p);
          await pipeline.settled;
          if (pipeline.status == PipelineStatus.unavailable) {
            fail('Ollama unavailable: ${pipeline.note}');
          }
        }
        final theme = pipeline.theme!;

        // Replay through the real cue logic at reading pace.
        final selector = CueSelector();
        var clock = DateTime(2026, 1, 1, 12);
        final rows = <String>[];
        final cues = <String>[];
        var changes = 0;

        for (var p = 0; p < book.paragraphs.length; p++) {
          final window = <({String mood, double intensity})>[];
          for (var i = p; i < p + MusicEngine.cueWindow; i++) {
            final tag = pipeline.tagAt(i);
            if (tag == null) break;
            window.add((mood: tag.mood, intensity: tag.intensity));
          }
          final dominant = dominantTag(window);
          if (dominant == null) continue;

          final params =
              mapToMusicParams(dominant.mood, dominant.intensity, theme);
          final decision = selector.observe(
            paragraphIndex: p,
            mood: params.sourceMood,
            energy: params.energy,
            now: clock,
          )!;
          if (decision.changed) changes++;
          cues.add(decision.mood);
          rows.add('${p.toString().padLeft(3)}  '
              '${pipeline.tagAt(p)!.mood.padRight(11)} '
              '-> ${dominant.mood.padRight(11)} '
              '${decision.changed ? '** ' : '   '}${decision.mood}');
          clock = clock.add(readingPace);
        }

        // Longest stretch on one cue: the number that decides whether it feels
        // like a score or like a held chord.
        var longest = 0, run = 0;
        for (var i = 0; i < cues.length; i++) {
          run = (i > 0 && cues[i] == cues[i - 1]) ? run + 1 : 1;
          if (run > longest) longest = run;
        }
        final minutes = cues.length * readingPace.inSeconds / 60;

        report
          ..writeln('=== ${entry.value} ===')
          ..writeln('theme "${theme.overallTheme}" / ${theme.genreSeed}')
          ..writeln('${book.paragraphs.length} paragraphs, '
              '~${minutes.toStringAsFixed(0)} min of reading')
          ..writeln('distinct tags: ${{
            for (var p = 0; p < book.paragraphs.length; p++)
              pipeline.tagAt(p)!.mood
          }.join(', ')}')
          ..writeln('cues used:     ${cues.toSet().join(', ')}')
          ..writeln('$changes cue change(s) -- one every '
              '${(minutes / (changes == 0 ? 1 : changes)).toStringAsFixed(1)} min; '
              'longest unbroken stretch $longest paragraphs')
          ..writeln(rows.join('\n'))
          ..writeln();

        debugPrint('[timeline] ${entry.value}: $changes changes over '
            '${cues.length} paragraphs (~${minutes.toStringAsFixed(0)} min), '
            'longest stretch $longest, cues ${cues.toSet().join('/')}');
      }

      File('build/cue_timeline.txt').writeAsStringSync(report.toString());
      debugPrint('[timeline] full report in build/cue_timeline.txt');
      await cache.close();
    });
  }, timeout: const Timeout(Duration(minutes: 30)));
}
