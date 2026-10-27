import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:reader_shell/book.dart';
import 'package:reader_shell/mood_cache.dart';
import 'package:reader_shell/mood_pipeline.dart';
import 'package:reader_shell/ollama_client.dart';

Book testBook([int paragraphs = 40]) => Book(
      title: 'Test',
      source: 'test.txt',
      paragraphs: List.generate(
        paragraphs,
        (i) => 'Paragraph $i. It was a dark and interesting night, number $i, '
            'and the lamplighter walked his round once more.',
      ),
    );

/// The chapter after [testBook]. Different prose, so it hashes to a different
/// cache key and the fake can tell which chapter a call was about.
Book nextChapter([int paragraphs = 40]) => Book(
      title: 'Test, chapter two',
      source: 'test.txt#2',
      paragraphs: List.generate(
        paragraphs,
        (i) => 'Chapter two, paragraph $i. The tide went out and left the '
            'harbour bare, number $i, and the boats leaned on the mud.',
      ),
    );

/// One recorded call to Ollama.
class Call {
  Call(this.kind, this.indices, [this.chapter = 'one']);
  final String kind; // 'theme' or 'paragraphs'
  final List<int> indices;

  /// Which chapter's prose this call carried, so the warm-up can be told
  /// apart from the reader's own window -- both use indices from 0.
  final String chapter;

  @override
  String toString() => kind == 'theme'
      ? 'theme'
      : 'paragraphs ${indices.first}-${indices.last} of $chapter';
}

/// A fake Ollama that answers instantly, or waits on a gate you control.
class FakeOllama {
  FakeOllama();

  final calls = <Call>[];

  /// When set, paragraph calls block until it completes.
  Completer<void>? gate;

  /// When true, every call fails as if nothing is listening.
  bool down = false;

  /// Indices to leave out of the reply, as a model that ignores part of the
  /// schema would. Nothing may spin waiting for these to arrive.
  Set<int> drop = {};

  http.Client get client => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final schema = body['format'] as Map<String, dynamic>;
        final properties = schema['properties'] as Map<String, dynamic>;
        final user = (body['messages'] as List).last['content'] as String;

        if (down) throw http.ClientException('Connection refused');

        if (properties.containsKey('overall_theme')) {
          calls.add(Call('theme', const []));
          return _reply({
            'overall_theme': 'brooding coastal mystery',
            'instrumentation': 'solo cello, low piano',
            'genre_seed': 'cinematic-noir',
          });
        }

        final indices = RegExp(r'^\[(\d+)\]$', multiLine: true)
            .allMatches(user)
            .map((m) => int.parse(m.group(1)!))
            .toList();
        calls.add(Call('paragraphs', indices,
            user.contains('Chapter two') ? 'two' : 'one'));
        if (gate != null) await gate!.future;
        return _reply({
          'paragraphs': [
            for (final i in indices)
              if (!drop.contains(i))
              {
                'index': i,
                'mood': moods[i % moods.length],
                'intensity': (i % 10) / 10,
                'reason': 'reason $i',
              },
          ],
        });
      });

  http.Response _reply(Object json) => http.Response(
        jsonEncode({
          'message': {'content': jsonEncode(json)},
        }),
        200,
      );

  List<Call> get paragraphCalls =>
      calls.where((c) => c.kind == 'paragraphs').toList();
  int get themeCalls => calls.where((c) => c.kind == 'theme').length;
}

void main() {
  late FakeOllama fake;
  late MoodCache cache;

  setUp(() async {
    fake = FakeOllama();
    cache = await MoodCache.inMemory();
  });

  tearDown(() => cache.close());

  MoodPipeline build() => MoodPipeline(
        client: OllamaClient(client: fake.client),
        cache: cache,
      );

  group('the next chapter, tagged before the reader turns to it', () {
    test('its opening lands in the cache', () async {
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(nextChapter());
      await pipeline.settled;

      final warmed = await cache.tags(nextChapter().key);
      expect(warmed, hasLength(MoodPipeline.warmAhead));
      expect(warmed.keys, containsAll([0, 1, 2]));
    });

    test('but only after the reader\'s own window is covered', () async {
      // The whole point. This runs on spare time; it must never be the reason
      // the paragraph under the reader is still untagged.
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(nextChapter());
      await pipeline.settled;

      final order = fake.paragraphCalls.map((c) => c.chapter).toList();
      final firstTwo = order.indexOf('two');
      expect(firstTwo, greaterThan(0), reason: 'chapter one goes first');
      expect(order.sublist(0, firstTwo), everyElement('one'));

      final covered = fake.paragraphCalls
          .where((c) => c.chapter == 'one')
          .expand((c) => c.indices)
          .toSet();
      expect(covered, containsAll(
          [for (var i = 0; i <= MoodPipeline.lookahead; i++) i]));
    });

    test('so turning the page to it costs no calls at all', () async {
      // The bug this fixes: reaching the end of a chapter and waiting for a
      // cold classify pass before the next one could be read.
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(nextChapter());
      await pipeline.settled;

      final before = fake.paragraphCalls.length;
      await pipeline.setBook(nextChapter());
      expect(pipeline.tagAt(0), isNotNull, reason: 'ready on the first frame');
      await pipeline.settled;

      expect(fake.paragraphCalls.length, before,
          reason: 'the opening window was already cached');
    });

    test('a short final chapter is warmed whole, not padded', () async {
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(nextChapter(3));
      await pipeline.settled;

      expect(await cache.tags(nextChapter(3).key), hasLength(3));
    });

    test('the last chapter has nothing after it', () async {
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(null);
      await pipeline.settled;

      expect(fake.paragraphCalls.every((c) => c.chapter == 'one'), isTrue);
    });

    test('an index the model never echoes does not spin', () async {
      // Asked for six, answered five, for ever -- the trap the arc scanner
      // hit. Everything asked for is marked done, not merely what came back.
      fake.drop = {2, 5};
      final pipeline = build();
      await pipeline.setBook(testBook());
      await pipeline.prepareNext(nextChapter());
      await pipeline.settled;

      final onTwo = fake.paragraphCalls.where((c) => c.chapter == 'two');
      expect(onTwo, hasLength(lessThanOrEqualTo(3)),
          reason: 'warmAhead / batchSize rounded up, and no more');
    });
  });

  test('theme is fetched once, before any paragraph call', () async {
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pipeline.settled;

    expect(fake.calls.first.kind, 'theme');
    expect(fake.themeCalls, 1);
    expect(pipeline.theme!.overallTheme, 'brooding coastal mystery');
    expect(pipeline.theme!.themeId, startsWith('brooding-coastal-mystery-'));
    expect(fake.paragraphCalls, isNotEmpty);
  });

  test('fills only the lookahead window, in batches, then stops', () async {
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pipeline.settled;

    // Window is position..position+lookahead inclusive = 9 paragraphs,
    // delivered as batches of at most batchSize.
    final tagged = fake.paragraphCalls.expand((c) => c.indices).toSet();
    expect(tagged, {for (var i = 0; i <= MoodPipeline.lookahead; i++) i});
    expect(fake.paragraphCalls.first.indices.length, MoodPipeline.batchSize);
    for (final call in fake.paragraphCalls) {
      expect(call.indices.length, lessThanOrEqualTo(MoodPipeline.batchSize));
    }
    expect(pipeline.status, PipelineStatus.idle);
    expect(pipeline.currentTag, isNotNull);
    expect(pipeline.currentSource, 'fresh');
  });

  test('moving forward asks only for what is not already known', () async {
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pipeline.settled;
    final before = fake.paragraphCalls.expand((c) => c.indices).toSet();

    pipeline.onPosition(4);
    await pipeline.settled;
    final after = fake.paragraphCalls.expand((c) => c.indices).toList();

    // Nothing already tagged was requested a second time.
    expect(after.length, after.toSet().length, reason: 'no index requested twice');
    // Derived from the constant rather than written out: the reader moved to
    // paragraph 4, so the window now reaches 4 + lookahead, and everything up
    // to the old edge is already known. Hard-coding the four indices meant
    // this failed the moment the lookahead grew, which told us nothing about
    // whether the *behaviour* was still right.
    const edge = MoodPipeline.lookahead;
    expect(after.toSet().difference(before),
        {for (var i = edge + 1; i <= 4 + edge; i++) i});
  });

  test('a burst of positions during a call makes no duplicate requests',
      () async {
    fake.gate = Completer<void>();
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pumpEventQueue(times: 20);

    // One batch is out and blocked. Hammer the pipeline with positions
    // inside that batch's range.
    expect(fake.paragraphCalls.length, 1);
    for (var i = 0; i < 20; i++) {
      pipeline.onPosition(i % MoodPipeline.batchSize);
    }
    await pumpEventQueue(times: 20);
    expect(fake.paragraphCalls.length, 1, reason: 'still just the one call');

    fake.gate!.complete();
    fake.gate = null;
    await pipeline.settled;

    final all = fake.paragraphCalls.expand((c) => c.indices).toList();
    expect(all.length, all.toSet().length, reason: 'no index fetched twice');
  });

  test('jumping ahead mid-call re-prioritises the next batch', () async {
    fake.gate = Completer<void>();
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pumpEventQueue(times: 20);
    expect(fake.paragraphCalls.single.indices.first, 0);

    // The reader skips to paragraph 30 while the first batch is in flight.
    pipeline.onPosition(30);
    fake.gate!.complete();
    fake.gate = null;
    await pipeline.settled;

    // The next batch starts where the reader now is, not where they were.
    expect(fake.paragraphCalls[1].indices.first, 30);
    expect(pipeline.currentTag, isNotNull);
  });

  test('a second run on the same book makes no calls at all', () async {
    final first = build();
    await first.setBook(testBook());
    await first.settled;
    final callsAfterFirstRun = fake.calls.length;
    expect(callsAfterFirstRun, greaterThan(1));

    // A fresh pipeline over the same cache, as if the app were restarted.
    final second = build();
    await second.setBook(testBook());
    await second.settled;

    expect(fake.calls.length, callsAfterFirstRun, reason: 'nothing re-fetched');
    expect(second.theme!.overallTheme, 'brooding coastal mystery');
    expect(second.currentTag, isNotNull);
    expect(second.currentSource, 'cache');
  });

  test('editing the text starts a fresh cache rather than reusing tags',
      () async {
    final original = testBook();
    final firstRun = build();
    await firstRun.setBook(original);
    await firstRun.settled;
    final callsBefore = fake.calls.length;

    final edited = Book.fromText(
      'Test',
      'A completely different chapter that shares nothing with the first one, '
      'long enough to be its own paragraph and then some.',
      source: 'test.txt',
    );
    expect(edited.key, isNot(original.key));
    final pipeline = build();
    await pipeline.setBook(edited);
    await pipeline.settled;

    expect(fake.calls.length, greaterThan(callsBefore));
    expect(pipeline.currentSource, 'fresh');
  });

  test('Ollama down: status says so, reading is unaffected, next move retries',
      () async {
    fake.down = true;
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pipeline.settled;

    expect(pipeline.status, PipelineStatus.unavailable);
    expect(pipeline.note, contains("isn't running"));
    expect(pipeline.currentTag, isNull);
    expect(pipeline.theme, isNull);

    // Ollama comes back; the next trigger picks up without a restart.
    fake.down = false;
    pipeline.onPosition(2);
    await pipeline.settled;

    expect(pipeline.status, PipelineStatus.idle);
    expect(pipeline.theme, isNotNull);
    expect(pipeline.currentTag, isNotNull);
  });

  test('tags survive a mid-book failure and resume from cache', () async {
    final pipeline = build();
    await pipeline.setBook(testBook());
    await pipeline.settled;
    final tagsBefore = pipeline.tagCount;

    fake.down = true;
    pipeline.onPosition(20);
    await pipeline.settled;
    expect(pipeline.status, PipelineStatus.unavailable);

    // What was already tagged is still on disk for the next run.
    final resumed = build();
    fake.down = false;
    await resumed.setBook(testBook());
    await resumed.settled;
    expect(resumed.tagCount, greaterThanOrEqualTo(tagsBefore));
  });

  test('flicking through fifty pages does not queue fifty batches', () async {
    // Someone skimming produces a trigger every few hundred milliseconds. The
    // pipeline must not commit work for every page they pass through: calls
    // run one at a time and the next batch is chosen when the previous one
    // finishes, from wherever the reader has got to by then.
    final pipeline = build();
    final book = testBook(200);
    await pipeline.setBook(book);
    await pipeline.settled;

    final before = fake.paragraphCalls.length;
    fake.gate = Completer<void>(); // hold the next call open
    pipeline.onPosition(1); // starts a batch, which now blocks

    for (var page = 2; page <= 50; page++) {
      pipeline.onPosition(page);
    }
    fake.gate!.complete();
    fake.gate = null;
    await pipeline.settled;

    final issued = fake.paragraphCalls.skip(before).toList();
    expect(issued.length, lessThanOrEqualTo(4),
        reason: '49 page turns became ${issued.length} batches: $issued');

    // What it did classify is where the reader actually stopped, not the
    // pages they flicked past.
    expect(pipeline.tagAt(50), isNotNull,
        reason: 'the page they landed on should be tagged');
    expect(issued.last.indices.last, greaterThanOrEqualTo(50));
  });
}
