// What sounds, against what was tagged.
//
// The reason this has its own suite: the gap between the two is the thing that
// decides how a bed set is sized, and it is entirely produced by two pieces of
// smoothing that were each written for a different reason -- dominantTag to
// stop the score lurching, CueSelector to stop page-flipping causing a burst of
// crossfades. Neither was written with allocation in mind, and together they
// mean a mood can be 6% of the book and 0% of what plays.

import 'package:test/test.dart';
import 'package:music_book_core/music_book_core.dart';

/// A run of tags, all at the same intensity so the band never moves and the
/// mood is the only thing under test.
List<({String mood, double intensity})> run(String pattern,
    {double intensity = 0.9}) {
  const moods = {
    't': 'tense',
    'o': 'ominous',
    'c': 'calm',
    'n': 'neutral',
  };
  return [
    for (final letter in pattern.split(''))
      (mood: moods[letter]!, intensity: intensity),
  ];
}

void main() {
  _runs();
  group('soundingCues', () {
    test('a sustained mood sounds', () {
      final sounding = soundingCues(run('tttttttt'));
      expect(sounding, everyElement('tense-1'));
      expect(sounding, hasLength(8));
    });

    test('one entry per paragraph', () {
      for (final length in [1, 4, 9, 40]) {
        expect(soundingCues(run('t' * length)), hasLength(length));
      }
    });

    test('a scattered mood never sounds at all', () {
      // Ominous on every third paragraph, never twice running. This is the
      // measured shape: 18 tagged ominous paragraphs, 0 sounding.
      final sounding = soundingCues(run('ttottottottottot'));
      expect(sounding.any((c) => c.startsWith('ominous')), isFalse);
      expect(sounding, everyElement(startsWith('tense')));
    });

    test('a sustained block of the same mood does sound', () {
      // The same mood, given a scene of its own, reaches the speakers -- which
      // is why the allocation floor is worth paying for.
      final sounding = soundingCues(run('ttttoooooooottttt'));
      expect(sounding.any((c) => c.startsWith('ominous')), isTrue);
    });

    test('the first paragraph commits, so nothing starts silent', () {
      expect(soundingCues(run('cccc')).first, startsWith('calm'));
    });

    test('a change costs two confirmations', () {
      // Four calm, then tense forever. The window looks ahead, so the turn
      // begins before the tense paragraphs arrive; what matters is that the
      // switch is not instant and not never.
      final sounding = soundingCues(run('ccccctttttttttt'));
      final at = sounding.indexWhere((c) => c.startsWith('tense'));
      expect(at, greaterThan(0));
      expect(at, lessThan(sounding.length));
    });

    test('the dwell binds when pages are flipped, not when they are read', () {
      final flipped = soundingCues(run('ccccctttttttttt'),
          perParagraph: const Duration(milliseconds: 200));
      final read = soundingCues(run('ccccctttttttttt'));
      final flippedAt = flipped.indexWhere((c) => c.startsWith('tense'));
      final readAt = read.indexWhere((c) => c.startsWith('tense'));
      expect(readAt, greaterThan(0), reason: 'reading should reach tense');
      expect(flippedAt == -1 || flippedAt >= readAt, isTrue,
          reason: 'the 15s dwell can only delay the change, never hasten it');
    });

    test('an empty run sounds nothing', () {
      expect(soundingCues(const []), isEmpty);
    });
  });

  group('histograms', () {
    test('tagged counts every paragraph, sounding counts what played', () {
      final result = histograms([run('ttottottottottot')]);
      expect(result.tagged['ominous-1'], 5);
      expect(result.sounding['ominous-1'], isNull);
      expect(result.tagged.values.fold(0, (a, b) => a + b), 16);
      expect(result.sounding.values.fold(0, (a, b) => a + b), 16);
    });

    test('separate runs are replayed separately, so no window crosses a hole',
        () {
      // One run ends on ominous, the next opens on it. Joined they would
      // confirm and sound; as separate runs -- which is what a hole between
      // them means -- neither does.
      final joined = histograms([run('tttttto'), run('otttttt')]);
      expect(joined.sounding.keys.any((c) => c.startsWith('ominous')), isFalse);
    });

    test('changes counts cue turns, including the first commit of each run',
        () {
      expect(histograms([run('tttttttt')]).changes, 1);
      expect(histograms([run('tttttttt'), run('cccccccc')]).changes, 2);
    });

    test('no runs, no histogram', () {
      final result = histograms(const []);
      expect(result.tagged, isEmpty);
      expect(result.sounding, isEmpty);
      expect(result.changes, 0);
    });
  });

  // The replay has to count what the engine plays, not what the tags ask
  // for. On arc 0 of the test book the two differed by seven changes and 38
  // distance lookups (SUMMARY §9.24), all of them cues the set had no bed for
  // that the engine resolves to a neighbour.
  group('replaying against the beds a set has', () {
    // Tense at two intensities that land in different bands: 0.3 is band 0,
    // 0.9 is band 1.
    List<({String mood, double intensity})> tense(String bands) => [
          for (final b in bands.split(''))
            (mood: 'tense', intensity: b == 'l' ? 0.3 : 0.9),
        ];

    test('without beds, the raw cue', () {
      final cues = soundingCues(tense('llllllhhhhhh'));
      expect(cues.first, 'tense-0');
      expect(cues.last, 'tense-1');
    });

    test('a cue the set lacks resolves to the bed the engine would play', () {
      final cues = soundingCues(tense('llllllhhhhhh'), beds: {'tense-1'});
      expect(cues.toSet(), {'tense-1'});
    });

    test('so a change to a missing cue is not a change', () {
      // Raw, the tags ask for tense-0 and then tense-1. With only tense-1 on
      // disk both resolve to it, and the engine, already on it, never
      // crossfades: one commit, not two. Counting the raw two would count a
      // crossfade that never happens.
      expect(histograms([tense('llllllhhhhhh')]).changes, 2);
      expect(histograms([tense('llllllhhhhhh')], beds: {'tense-1'}).changes,
          1);
    });

    test('tagged is always the raw cue, whatever the set has', () {
      final result = histograms([tense('llllllhhhhhh')], beds: {'tense-1'});
      expect(result.tagged.keys, containsAll(['tense-0', 'tense-1']));
      expect(result.sounding.keys, ['tense-1']);
    });

    test('resolves exactly as the engine does', () {
      // The rule lives in palette.dart so that both sides call it; this is
      // the pin against someone re-implementing it here.
      for (final intensity in [0.1, 0.4, 0.6, 0.95]) {
        expect(
          soundingCues([(mood: 'tense', intensity: intensity)],
              beds: {'tense-1'}).single,
          resolveCue('tense', intensity,
              banded: true, has: {'tense-1'}.contains),
        );
      }
    });
  });
}

void _runs() {
  group('contiguousRuns', () {
    test('chapters join into one run', () {
      expect(
        contiguousRuns([
          ['a', 'b'],
          ['c', 'd'],
        ]),
        [
          ['a', 'b', 'c', 'd']
        ],
      );
    });

    test('a hole breaks the run, the rest carries on', () {
      expect(
        contiguousRuns([
          ['a', 'b', null, 'c', 'd'],
        ]),
        [
          ['a', 'b'],
          ['c', 'd']
        ],
      );
    });

    test('a hole at a chapter boundary breaks only there', () {
      expect(
        contiguousRuns([
          ['a', 'b'],
          [null, 'c'],
          ['d', 'e'],
        ]),
        [
          ['a', 'b'],
          ['c', 'd', 'e']
        ],
      );
    });

    test('runs of one are dropped', () {
      expect(
        contiguousRuns([
          ['a', null, 'b', null, 'c', 'd'],
        ]),
        [
          ['c', 'd']
        ],
      );
    });

    test('minimum is adjustable', () {
      expect(contiguousRuns([['a', null, 'b']], minimum: 1), [
        ['a'],
        ['b']
      ]);
    });

    test('nothing in, nothing out', () {
      expect(contiguousRuns<String>([]), isEmpty);
      expect(contiguousRuns<String>([[], []]), isEmpty);
      expect(contiguousRuns<String>([[null, null]]), isEmpty);
    });
  });
}
