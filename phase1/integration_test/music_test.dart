// The audio itself, on the real Windows build. Run with:
//
//     flutter test integration_test/music_test.dart -d windows
//
// Needs no Ollama -- it drives the engine directly with mapped parameters.
//
// This is the only place the audio path is actually exercised: `flutter test`
// is headless, so there the engine reports unavailable and no-ops. What can be
// checked without ears is whether the device comes up, whether every mood's
// file decodes and plays, and whether a mood change is a *fade* -- both beds
// sounding, the new one climbing from silence -- rather than a cut. That last
// one is the difference between a score and a jump-scare, and it is measurable.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/experiment_treatments.dart';
import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/music_library.dart';
import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/ollama_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final theme = BookTheme(
    overallTheme: 'Mystery and Gothic',
    instrumentation: 'low strings, distant choir',
    genreSeed: 'gothic-orchestral',
  );

  /// A selector that never resists, so these tests measure the audio rather
  /// than the anti-thrash rule. That rule has its own tests in test/.
  CueSelector eager() =>
      CueSelector(minDwell: Duration.zero, confirmations: 1);

  /// An engine with the intro ramp out of the way.
  ///
  /// The ramp is a real part of how the score sounds -- 6.9 dB brought up over
  /// the first sixteen paragraphs, behind a twenty-second first fade -- but it
  /// is not what these tests are about, and one that waits 800ms to look at a
  /// bed twenty seconds into arriving measures nothing at all. It gets its own
  /// test at the bottom of this file; its arithmetic is covered headless in
  /// test/music_warmup_test.dart.
  MusicEngine steady({
    Duration crossfade = const Duration(milliseconds: 500),
    Duration energyFade = const Duration(milliseconds: 1500),
  }) =>
      MusicEngine(
        selector: eager(),
        crossfade: crossfade,
        energyFade: energyFade,
        firstFade: const Duration(milliseconds: 400),
        warmupParagraphs: 0,
      );

  testWidgets('every mood has a loop that decodes and plays', (tester) async {
    await tester.runAsync(() async {
      final engine = steady();
      await engine.start();
      expect(engine.available, isTrue,
          reason: 'no audio device came up: ${engine.note}');
      expect(engine.library, MusicLibrary.generated);

      var paragraph = 0;
      for (final mood in moodParams.keys) {
        await engine.observe(
          paragraphIndex: paragraph++,
          params: mapToMusicParams(mood, 0.6, theme),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(engine.playing, mood,
            reason: 'the $mood loop should be sounding; it did not load');
        expect(engine.playingVolume, greaterThan(0.0),
            reason: '$mood is playing but silent');
      }
      debugPrint('[music-test] all ${moodParams.length} generated loops played');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a mood change crossfades rather than cutting', (tester) async {
    await tester.runAsync(() async {
      final engine = steady(crossfade: const Duration(seconds: 2));
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('calm', 0.5, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      final settled = engine.playingVolume!;
      expect(settled, greaterThan(0.3), reason: 'the first cue faded in');
      expect(engine.voices, 1, reason: 'one bed before the change');

      // Change the mood, then look at the moment just after.
      await engine.observe(
        paragraphIndex: 1,
        params: mapToMusicParams('tense', 0.8, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final earlyVolume = engine.playingVolume!;
      final voicesDuring = engine.voices;

      await Future<void>.delayed(const Duration(milliseconds: 2600));
      final finalVolume = engine.playingVolume!;
      final voicesAfter = engine.voices;

      debugPrint('[music-test] crossfade: incoming $earlyVolume -> $finalVolume, '
          'voices $voicesDuring -> $voicesAfter');

      expect(voicesDuring, 2,
          reason: 'the outgoing bed must still be sounding; a cut leaves one');
      expect(earlyVolume, lessThan(finalVolume * 0.75),
          reason: 'the incoming bed must climb from silence, not arrive whole');
      expect(voicesAfter, 1,
          reason: 'the old bed is stopped once its fade has finished');
      expect(engine.playing, 'tense');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('intensity opens the bed up, not just its volume', (tester) async {
    await tester.runAsync(() async {
      // The score spends long stretches on one cue -- 56 paragraphs in stave I
      // of the Carol -- while the classifier's intensity swings the whole way
      // from 0.3 to 1.0 underneath it. Volume alone renders that as about 3 dB,
      // which is why such a stretch sounds like a held chord. The low-pass has
      // to make it audible.
      final engine = steady(
        crossfade: const Duration(milliseconds: 400),
        energyFade: const Duration(milliseconds: 400),
      );
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('tense', 0.30, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final darkCutoff = engine.cutoff!;
      final quietGain = engine.playingVolume!;

      await engine.observe(
        paragraphIndex: 1,
        params: mapToMusicParams('tense', 1.0, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final brightCutoff = engine.cutoff!;
      final loudGain = engine.playingVolume!;

      debugPrint('[music-test] intensity 0.30 -> 1.00: cutoff '
          '${darkCutoff.round()} -> ${brightCutoff.round()} Hz, gain '
          '${quietGain.toStringAsFixed(2)} -> ${loudGain.toStringAsFixed(2)} '
          '(${(20 * (math.log(loudGain / quietGain) / math.ln10)).toStringAsFixed(1)} dB)');

      expect(engine.playing, 'tense', reason: 'same mood, so no crossfade');
      expect(engine.crossfades, 1, reason: 'intensity must not restart the bed');
      expect(brightCutoff, greaterThan(darkCutoff * 1.8),
          reason: 'the intensity range has to be an audible change');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the licensed library is playable too', (tester) async {
    await tester.runAsync(() async {
      // Proves the swap in music_library.dart is real, and that the downloaded
      // CC0/CC-BY files decode. It says nothing about how they sound, which is
      // exactly why they are not the default.
      final library = await LoopLibrary.load(MusicLibrary.licensed);
      expect(library.missing(moodParams.keys), isEmpty,
          reason: 'every mood needs a licensed loop as well');
      expect(library.attributions, isNotEmpty,
          reason: 'the CC-BY files must carry a credit line');
      debugPrint('[music-test] licensed credits: '
          '${library.attributions.values.join(' | ')}');
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a book with generated beds plays its own, from disk',
      (tester) async {
    await tester.runAsync(() async {
      // Generated beds are real files under the app's support directory, not
      // bundled assets, so this is the only test that exercises loadFile at
      // all. Skipped rather than failed when nothing has been generated:
      // tool/generate_beds.py needs a GPU and half an hour, and a fresh
      // checkout has no reason to have run it.
      const bookId = 'sample-dracula_ch1';
      if (!await LoopLibrary.hasGenerated(bookId)) {
        debugPrint('[music-test] no generated beds for $bookId; run '
            'tool/generate_beds.py --install $bookId. Skipping.');
        return;
      }

      final engine = steady(crossfade: const Duration(milliseconds: 400));
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      await engine.useLibrary(MusicLibrary.perBook, bookId: bookId);
      expect(engine.library, MusicLibrary.perBook,
          reason: 'it should not have fallen back');
      expect(engine.bookId, bookId);

      var paragraph = 0;
      for (final mood in moodParams.keys) {
        await engine.observe(
          paragraphIndex: paragraph++,
          params: mapToMusicParams(mood, 0.6, theme),
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(engine.playing, mood,
            reason: 'the generated $mood bed did not load from disk');
        expect(engine.playingVolume, greaterThan(0.0),
            reason: '$mood is playing but silent');
      }
      debugPrint('[music-test] all ${moodParams.length} generated beds for '
          '$bookId played from ${engine.playingAsset}');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('auditioning plays one bed on its own and gives the audio back',
      (tester) async {
    await tester.runAsync(() async {
      // The shipped set, so this runs on a fresh checkout: it has one bed per
      // mood, which is enough to prove the mechanism. Take counts above one
      // only exist in a generated, allocated set.
      final engine = steady(crossfade: const Duration(milliseconds: 400));
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      // Get the score playing something, so there is audio to take away.
      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('tense', 0.6, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(engine.playing, 'tense');
      expect(engine.auditioning, isNull);

      final beds = engine.beds;
      expect(beds, isNotEmpty, reason: 'the loaded set should list its beds');
      expect(beds.values.every((v) => v.isNotEmpty), isTrue);

      // Audition a different cue than the score chose, so "it played" cannot
      // be the score still playing.
      const other = 'calm';
      expect(beds.containsKey(other), isTrue);
      await engine.audition(other, 1);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(engine.auditioning?.cue, other);
      expect(engine.auditioning?.take, 1);
      expect(engine.playing, other);
      expect(engine.playingVolume, greaterThan(0.0),
          reason: 'auditioning but silent');
      expect(engine.filterWet, closeTo(MusicEngine.auditionWet, 0.001),
          reason: 'the audition should not be shaped by the score filter');
      // The assertion that matters, and the one this test used to lack: a
      // filter set to an impossible frequency reports that frequency back
      // quite happily while passing no audio, so only the *level coming out*
      // says the bed is really sounding.
      expect(engine.voices, greaterThan(0),
          reason: 'auditioning but no voice is running');

      // The score keeps deciding underneath, and must not grab the audio back.
      await engine.observe(
        paragraphIndex: 1,
        params: mapToMusicParams('ominous', 0.9, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(engine.auditioning?.cue, other,
          reason: 'the score interrupted an audition');
      expect(engine.playing, other);

      // And gives it back where the prose actually is, not where it left off.
      await engine.stopAudition();
      expect(engine.auditioning, isNull);
      await engine.observe(
        paragraphIndex: 2,
        params: mapToMusicParams('ominous', 0.9, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(engine.playing, 'ominous',
          reason: 'the score should resume on the current cue, not the old one');
      expect(engine.playingVolume, greaterThan(0.0));
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('auditioning a take that does not exist changes nothing',
      (tester) async {
    await tester.runAsync(() async {
      final engine = steady();
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');
      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('tense', 0.6, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      await engine.audition('tense', 99);
      await engine.audition('no-such-cue', 1);
      await engine.audition('tense', 0);
      expect(engine.auditioning, isNull);
      expect(engine.playing, 'tense',
          reason: 'a bad audition must not take the audio');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('every take of a real generated set plays', (tester) async {
    await tester.runAsync(() async {
      // The shipped set has one bed per cue, so the tests above prove the
      // mechanism but never touch the case that matters most: a
      // generated, allocated set where a cue owns up to ten takes and the
      // files are on disk rather than in the bundle. Skipped where that set
      // has not been generated, which is every machine but the one it was
      // made on.
      const book = '98068df9f6f3e739';
      if (!await LoopLibrary.hasGenerated(book)) {
        markTestSkipped('no generated set for $book here');
        return;
      }
      final engine = steady();
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      await engine.useLibrary(MusicLibrary.perBook, bookId: book);
      expect(engine.library, MusicLibrary.perBook,
          reason: 'the generated set should have loaded');

      final beds = engine.beds;
      expect(beds, isNotEmpty, reason: 'the set should list its beds');
      final most = beds.entries
          .reduce((a, b) => a.value.length >= b.value.length ? a : b);
      expect(most.value.length, greaterThan(1),
          reason: 'an allocated set should give some cue more than one bed');

      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('tense', 0.6, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));

      // Every take, not just the first: take 1 is the file the score already
      // plays, so it is the only one that could pass by accident.
      for (var take = 1; take <= most.value.length; take++) {
        await engine.audition(most.key, take);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(engine.auditionProblem, isNull,
            reason: 'take $take of ${most.key} declined');
        expect(engine.auditioning?.take, take);
        expect(engine.playingVolume, greaterThan(0.0),
            reason: 'take $take of ${most.key} started but is silent');
      }

      await engine.stopAudition();
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('a book with no generated beds falls back rather than going '
      'silent', (tester) async {
    await tester.runAsync(() async {
      // The case that matters for anyone who imported a book before generation
      // existed. Playing nothing would be worse than playing the shared set.
      final engine = steady();
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      await engine.useLibrary(MusicLibrary.perBook,
          bookId: 'no-such-book-anywhere');
      expect(engine.library, activeLibrary,
          reason: 'it should fall back to the shipped set');
      expect(engine.bookId, isNull);

      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('tense', 0.6, theme),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(engine.playing, 'tense', reason: 'it still has to make a sound');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('the score arrives slowly and sits back until you have read in',
      (tester) async {
    await tester.runAsync(() async {
      // The one thing listening tests asked for: the music was welcome once
      // immersed, and before that it was another thing in the room. Both
      // halves of the answer are measured here on the real device,
      // because both are claims about loudness and neither is visible in the
      // arithmetic alone: that the first bed *arrives* over twenty seconds
      // rather than two and a half, and that it then climbs about 6.9 dB as
      // the reader gets through the opening paragraphs.
      //
      // Four warm-up paragraphs rather than sixteen, so this costs half a
      // minute instead of two. The shape is the same; only the step size
      // differs.
      final engine = MusicEngine(
        selector: eager(),
        energyFade: const Duration(milliseconds: 300),
        warmupParagraphs: 4,
      );
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');

      const params = ('calm', 0.6);
      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams(params.$1, params.$2, theme),
      );

      // A second and a bit into a twenty-second fade is a few per cent of the
      // way up. At the old 2.5s crossfade it would be most of the way there,
      // which is what "the music switched on" sounds like.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      final arriving = engine.playingVolume!;

      await Future<void>.delayed(const Duration(seconds: 20));
      final floor = engine.playingVolume!;
      // Not warmupFloor: observing paragraph 0 is one paragraph read, which
      // with a four-paragraph ramp is already a quarter of the way up. At the
      // shipped sixteen it would be 1/16 and the difference would not show,
      // which is exactly how a test like this comes to pass by luck.
      final floorWarmth = engine.warmth;
      expect(arriving, lessThan(floor * 0.3),
          reason: 'the first bed must still be arriving after 1.3s: '
              '$arriving against a settled $floor');

      // Now read. Same mood and same intensity throughout, so the only thing
      // that can move the level is the warm-up.
      for (var i = 1; i <= engine.warmupParagraphs; i++) {
        await engine.observe(
          paragraphIndex: i,
          params: mapToMusicParams(params.$1, params.$2, theme),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final settled = engine.playingVolume!;
      final dB = 20 * (math.log(settled / floor) / math.ln10);

      final wanted = 1 / floorWarmth;
      debugPrint('[music-test] warm-up: $floor -> $settled '
          '(${dB.toStringAsFixed(1)} dB over ${engine.warmupParagraphs} '
          'paragraphs, wanted ${(20 * math.log(wanted) / math.ln10)
              .toStringAsFixed(1)}), ${engine.crossfades} crossfade(s)');

      expect(engine.crossfades, 1,
          reason: 'the warm-up is a level change, never a new cue');
      expect(engine.playing, 'calm');
      // The audible ratio has to be the ratio of the two warmths the engine
      // reported. Tight, because both ends are fully settled faders -- the
      // slack is for the sample rate of a wall clock, not for the arithmetic.
      expect(settled / floor, closeTo(wanted, 0.12),
          reason: '${dB.toStringAsFixed(1)} dB, wanted '
              '${(20 * math.log(wanted) / math.ln10).toStringAsFixed(1)}');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  // EXPERIMENT -- Phase 5, Task 0. Delete with lib/experiment_treatments.dart.
  //
  // Not a judgement about whether the treatments sound good; nothing here can
  // tell. It exists so that the verdict a human gives is a verdict about the
  // music rather than about four files that failed to decode. Phase 3 shipped
  // a full set of passing audio tests over beds nobody could hear, and the
  // lesson was that "the numbers are fine" is not the same as "it plays".
  testWidgets('EXPERIMENT: four treatments of one theme, on one mood',
      (tester) async {
    await tester.runAsync(() async {
      final engine = steady(crossfade: const Duration(milliseconds: 600));
      await engine.start();
      expect(engine.available, isTrue, reason: '${engine.note}');
      await engine.useLibrary(MusicLibrary.experiment);
      expect(engine.library, MusicLibrary.experiment);

      var paragraph = 0;
      final played = <String>[];
      for (final intensity in [0.20, 0.45, 0.65, 0.90]) {
        // The mood never changes. Under the old keying that is one cue for all
        // four observations -- which is precisely the stretch this phase is
        // about.
        await engine.observe(
          paragraphIndex: paragraph++,
          params: mapToMusicParams('tense', intensity, theme),
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(engine.playing, treatmentFor(intensity),
            reason: 'intensity $intensity should ask for '
                '${treatmentFor(intensity)}; it did not load');
        expect(engine.playingVolume, greaterThan(0.0),
            reason: '${engine.playing} is playing but silent');
        played.add(engine.playing!);
      }

      expect(played.toSet().length, 4,
          reason: 'the same mood produced four different cues: $played');
      expect(engine.crossfades, 4, reason: 'each one faded in: $played');
      debugPrint('[experiment] one mood, four cues by intensity: '
          '${played.join(' -> ')}');
      engine.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
