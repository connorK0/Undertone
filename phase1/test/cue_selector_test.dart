// The anti-thrash rule. A score that switches cue every page turn would be
// worse than silence, and it is the failure this phase is most likely to have,
// so the rule is pinned here rather than tuned by ear alone.

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/cue_selector.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  CueSelector fresh() => CueSelector(
        minDwell: const Duration(seconds: 15),
        confirmations: 2,
      );

  CueDecision? observe(
    CueSelector selector,
    int index,
    String mood, {
    double energy = 0.5,
    Duration at = Duration.zero,
  }) =>
      selector.observe(
        paragraphIndex: index,
        mood: mood,
        energy: energy,
        now: t0.add(at),
      );

  test('the first tag starts a cue at once, so an opened book is not silent',
      () {
    final selector = fresh();
    final decision = observe(selector, 0, 'calm', energy: 0.4);
    expect(decision, isNotNull);
    expect(decision!.changed, isTrue);
    expect(decision.mood, 'calm');
    expect(decision.energy, 0.4);
  });

  test('one odd paragraph between two calm ones never changes the cue', () {
    final selector = fresh();
    observe(selector, 0, 'calm');
    // Well past the dwell, so only the confirmation rule is in play.
    final spike = observe(selector, 1, 'tense', at: const Duration(minutes: 1));
    final back = observe(selector, 2, 'calm', at: const Duration(minutes: 2));

    expect(spike!.changed, isFalse, reason: 'a single paragraph is not a scene');
    expect(spike.mood, 'calm');
    expect(back!.changed, isFalse);
    expect(selector.mood, 'calm');
  });

  test('a sustained change is believed on the second paragraph', () {
    final selector = fresh();
    observe(selector, 0, 'calm');

    // Check the intermediate state before the second observation runs -- once
    // the change commits, the candidate is cleared and this would pass
    // vacuously.
    final first = observe(selector, 1, 'ominous', at: const Duration(seconds: 30));
    expect(first!.changed, isFalse);
    expect(selector.pending, 'ominous', reason: 'counting, not yet believed');

    final second = observe(selector, 2, 'ominous',
        energy: 0.62, at: const Duration(seconds: 60));
    expect(second!.changed, isTrue);
    expect(second.mood, 'ominous');
    expect(second.energy, 0.62);
    expect(selector.pending, isNull);
  });

  test('flipping pages fast cannot produce a burst of crossfades', () {
    final selector = fresh();
    observe(selector, 0, 'calm');

    // Thirty pages in six seconds, all tagged differently from the cue.
    var changes = 0;
    for (var i = 1; i <= 30; i++) {
      final decision = observe(selector, i, 'tense',
          at: Duration(milliseconds: 200 * i));
      if (decision!.changed) changes++;
    }
    expect(changes, 0,
        reason: 'the dwell had not elapsed, so nothing should have switched');
    expect(selector.mood, 'calm');

    // Keep flipping past the dwell: exactly one change, not a queue of them.
    for (var i = 31; i <= 120; i++) {
      final decision = observe(selector, i, 'tense',
          at: Duration(milliseconds: 200 * i));
      if (decision!.changed) changes++;
    }
    expect(changes, 1);
    expect(selector.mood, 'tense');
  });

  test('repeat notifications for one paragraph do not confirm a change', () {
    final selector = fresh();
    observe(selector, 0, 'calm');

    // The pipeline notifies whenever a batch lands, not only when the reader
    // moves, so the same paragraph is seen many times over.
    for (var i = 0; i < 8; i++) {
      final decision = observe(selector, 1, 'tense',
          at: Duration(seconds: 30 + i));
      expect(decision!.changed, isFalse,
          reason: 'one paragraph cannot confirm itself by being re-notified');
    }
    expect(selector.mood, 'calm');

    // A second, genuinely different paragraph is what confirms it.
    final moved = observe(selector, 2, 'tense', at: const Duration(seconds: 45));
    expect(moved!.changed, isTrue);
  });

  test('loudness follows the playing mood, not the one arguing for a change',
      () {
    final selector = fresh();
    observe(selector, 0, 'calm', energy: 0.30);
    final quieter = observe(selector, 1, 'calm',
        energy: 0.22, at: const Duration(seconds: 30));
    expect(quieter!.changed, isFalse);
    expect(quieter.energy, 0.22, reason: 'intensity moves within a mood');

    // A tense paragraph is loud, but it is not what is playing.
    final loud = observe(selector, 2, 'tense',
        energy: 0.85, at: const Duration(seconds: 60));
    expect(loud!.changed, isFalse);
    expect(loud.energy, 0.22,
        reason: 'the calm bed must not swell because a tense page went by');
  });

  group('dominantTag', () {
    ({String mood, double intensity}) p(String mood, [double intensity = 0.5]) =>
        (mood: mood, intensity: intensity);

    test('a lone paragraph does not outvote the stretch around it', () {
      // The real shape of the problem: Dracula's tags flicker paragraph to
      // paragraph, and a single 'whimsical' in a dark scene must not score it.
      final dominant = dominantTag([
        p('ominous'),
        p('whimsical'),
        p('ominous'),
        p('ominous'),
      ]);
      expect(dominant!.mood, 'ominous');
    });

    test('the nearest paragraphs weigh most', () {
      // Two 'calm' further away do not outweigh the two 'tense' under the eye.
      final dominant = dominantTag([
        p('tense'),
        p('tense'),
        p('calm'),
        p('calm'),
      ]);
      expect(dominant!.mood, 'tense');
    });

    test('a real change of scene still turns the cue', () {
      // Neutral rather than a minority mood on screen: a gentle paragraph
      // there is boosted (see below), and that is the point of the boost.
      final dominant = dominantTag([
        p('neutral'),
        p('ominous'),
        p('ominous'),
        p('ominous'),
      ]);
      expect(dominant!.mood, 'ominous',
          reason: 'three paragraphs of a new mood is a scene, not a flicker');
    });

    test('a gentle paragraph on screen outvotes three that are not', () {
      // SUMMARY 9.43: gentle moods come in short stretches, and without the
      // boost a stretch needed three paragraphs to be heard at all.
      final dominant = dominantTag([
        p('calm', 0.2),
        p('tense', 0.9),
        p('tense', 0.9),
        p('tense', 0.9),
      ]);
      expect(dominant!.mood, 'calm');
      expect(dominant.intensity, 0.2,
          reason: 'the boost changes the vote, never the intensity');
    });

    test('dread is not boosted', () {
      final dominant = dominantTag([
        p('ominous'),
        p('tense'),
        p('tense'),
        p('tense'),
      ]);
      expect(dominant!.mood, 'tense');
    });

    test('intensity is averaged over the paragraphs that chose the mood', () {
      final dominant = dominantTag([
        p('tense', 0.8),
        p('calm', 0.1),
        p('tense', 0.4),
      ]);
      expect(dominant!.mood, 'tense');
      // Weights 1 and 1/3: (0.8 + 0.4/3) / (1 + 1/3).
      expect(dominant.intensity, closeTo(0.7, 0.001));
    });

    test('a tie goes to the paragraph on screen', () {
      final dominant = dominantTag([p('melancholic'), p('romantic')]);
      expect(dominant!.mood, 'melancholic');
    });

    test('an empty window has no opinion', () {
      expect(dominantTag([]), isNull);
    });
  });

  test('reset forgets the cue, so a new book starts fresh', () {
    final selector = fresh();
    observe(selector, 0, 'calm');
    selector.reset();
    expect(selector.mood, isNull);

    final decision = observe(selector, 0, 'ominous', at: const Duration(hours: 1));
    expect(decision!.changed, isTrue,
        reason: 'a new book starts its cue immediately, with no dwell to serve');
    expect(decision.mood, 'ominous');
  });
}
