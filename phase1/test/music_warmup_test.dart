// The warm-up ramp: the score sits back while the reader is still arriving,
// and comes up to level as they read in.
//
// From listening tests, which found the music welcome *once immersed* -- so
// the thing to fix was the beginning. All of it
// is arithmetic on a paragraph count, which is why it can be tested here
// rather than only by ear: `flutter test` is headless, the engine reports
// unavailable, and observe() still runs the whole decision path.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/ollama_client.dart';

void main() {
  final theme = BookTheme(
    overallTheme: 'Mystery and Gothic',
    instrumentation: 'low strings, distant choir',
    genreSeed: 'gothic-orchestral',
  );

  /// Read [count] paragraphs, one observation each, all on the same mood and
  /// intensity so the only thing moving is the warm-up.
  Future<void> read(MusicEngine engine, int count, {int from = 0}) async {
    for (var i = 0; i < count; i++) {
      await engine.observe(
        paragraphIndex: from + i,
        params: mapToMusicParams('calm', 0.5, theme),
      );
    }
  }

  test('the ramp starts at the floor and ends at full level', () async {
    final engine = MusicEngine();
    expect(engine.warmth, MusicEngine.warmupFloor,
        reason: 'nothing read yet, so the score is at its quietest');

    await read(engine, engine.warmupParagraphs);
    expect(engine.warmth, closeTo(1.0, 1e-9),
        reason: 'a settled reader hears the score at full level');

    // Reading on cannot push it past full.
    await read(engine, 40, from: 100);
    expect(engine.warmth, closeTo(1.0, 1e-9));
    engine.dispose();
  });

  test('the whole ramp is 6.9 dB', () {
    final engine = MusicEngine();
    final dB = 20 * math.log(1 / MusicEngine.warmupFloor) / math.ln10;
    expect(dB, closeTo(6.94, 0.01));
    engine.dispose();
  });

  test('no single paragraph is an audible step', () async {
    // The claim the design rests on: the reader gets 6.9 dB without ever
    // hearing it move. About 1 dB is the threshold on a sustained sound, and
    // every step here has to sit under it -- otherwise this is not a warm-up,
    // it is the volume creeping up in front of you.
    final engine = MusicEngine();
    var previous = engine.warmth;
    var worst = 0.0;
    for (var i = 0; i < engine.warmupParagraphs; i++) {
      await read(engine, 1, from: i);
      final step = 20 * math.log(engine.warmth / previous) / math.ln10;
      expect(step, greaterThanOrEqualTo(0.0), reason: 'the ramp never dips');
      worst = math.max(worst, step);
      previous = engine.warmth;
    }
    expect(worst, lessThan(1.0),
        reason: 'worst single step was ${worst.toStringAsFixed(2)} dB');
    engine.dispose();
  });

  test('sitting on one paragraph does not run the ramp out', () async {
    // The pipeline notifies on every batch that lands, not only on movement.
    // Counting those would take a reader who opened the book and made tea to
    // full level without a page being turned.
    final engine = MusicEngine();
    for (var i = 0; i < 50; i++) {
      await engine.observe(
        paragraphIndex: 0,
        params: mapToMusicParams('calm', 0.5, theme),
      );
    }
    // One paragraph *has* been read, so the ramp has taken exactly one step --
    // the point is that fifty notifications about it took one step too.
    expect(engine.paragraphsRead, 1);
    expect(engine.warmth, lessThan(MusicEngine.warmupFloor + 0.01),
        reason: 'still all but at the floor: ${engine.warmth}');
    engine.dispose();
  });

  test('a chapter turn keeps the ramp, opening a book restarts it', () async {
    // close() is called by preparation between chapters. By then the reader is
    // as immersed as they are going to get, and dipping the level would read
    // as the volume drifting on its own.
    final engine = MusicEngine();
    await read(engine, engine.warmupParagraphs);
    expect(engine.warmth, closeTo(1.0, 1e-9));

    await engine.close();
    expect(engine.warmth, closeTo(1.0, 1e-9),
        reason: 'a chapter turn is not a new reading session');

    // Paragraph numbers restart with the chapter, so paragraph 0 of the next
    // one still has to count as movement.
    engine.restartWarmup();
    expect(engine.warmth, MusicEngine.warmupFloor);
    await read(engine, 1);
    expect(engine.paragraphsRead, 1);
    engine.dispose();
  });

  test('a zero-paragraph warm-up is simply off', () async {
    // The escape hatch, and the divide-by-zero guard in one.
    final engine = MusicEngine(warmupParagraphs: 0);
    expect(engine.warmth, 1.0);
    await read(engine, 3);
    expect(engine.warmth, 1.0);
    engine.dispose();
  });
}
