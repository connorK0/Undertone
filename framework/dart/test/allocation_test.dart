import 'package:test/test.dart';
import 'package:music_book_core/music_book_core.dart';

/// Nine chapters of the test book, banded with the engine's own
/// edges. Real cached tags rather than a made-up shape, because the whole point
/// of the change is that the real shape is nothing like uniform.
const measured = {
  'tense-2': 76,
  'tense-3': 73,
  'tense-1': 35,
  'calm-0': 30,
  'melancholic-1': 15,
  'neutral-0': 15,
  'tense-0': 11,
  'ominous-3': 9,
  'melancholic-2': 8,
  'ominous-2': 7,
  'triumphant-3': 4,
  'ominous-1': 3,
  'triumphant-2': 3,
  'melancholic-3': 2,
  'romantic-1': 2,
  'melancholic-0': 2,
  'calm-1': 2,
  'triumphant-1': 2,
  'romantic-0': 1,
  'romantic-2': 1,
};

int total(Map<String, int> plan) => plan.values.fold(0, (a, b) => a + b);

void main() {
  _floorBand();
  _floorAndWeights();
  group('histogramOf', () {
    test('counts in the vocabulary the engine asks for', () {
      final counts = histogramOf([
        ('tense', 0.9),
        ('tense', 0.8),
        ('calm', 0.1),
      ]);
      expect(counts, {'tense-1': 2, 'calm-0': 1});
    });

    test('bands agree with the selector', () {
      for (final intensity in [0.0, 0.3, 0.64, 0.65, 0.8, 1.0]) {
        final counts = histogramOf([('tense', intensity)]);
        expect(counts.keys.single, 'tense-${bandFor(intensity)}');
      }
    });

    test('empty in, empty out', () {
      expect(histogramOf([]), isEmpty);
    });
  });

  group('allocate', () {
    test('spends the whole budget and no more', () {
      expect(total(allocate(measured)), defaultBudget);
      for (final budget in [1, 5, 8, 12, 32, 64]) {
        expect(total(allocate(measured, budget: budget)), budget,
            reason: 'budget $budget');
      }
    });

    test('gives the most-heard cue the most beds', () {
      final plan = allocate(measured);
      // tense-2 and tense-3 are a quarter of the book each; between them they
      // should hold about half the set.
      expect(plan['tense-2']! + plan['tense-3']!, greaterThanOrEqualTo(14));
      expect(plan['tense-2'], greaterThan(1));
      expect(plan['tense-3'], greaterThan(1));
    });

    test('every mood that occurs keeps a bed', () {
      final plan = allocate(measured);
      final moods = {for (final cue in measured.keys) moodOf(cue)};
      final covered = {for (final cue in plan.keys) moodOf(cue)};
      expect(covered, containsAll(moods));
    });

    test('romantic survives on 1.3% by taking one from tense', () {
      final plan = allocate(measured);
      expect(plan.keys.where((c) => moodOf(c) == 'romantic'), hasLength(1));
      // Its most-observed band, not band 0.
      expect(plan['romantic-1'], 1);
    });

    test('a cue nobody reaches gets nothing', () {
      final plan = allocate(measured);
      // romantic-0 and romantic-2 are one tag each; the band fallback covers
      // them from romantic-1.
      expect(plan.containsKey('romantic-0'), isFalse);
      expect(plan.containsKey('romantic-2'), isFalse);
    });

    test('a mood absent from the histogram is planned out', () {
      expect(allocate(measured).keys.any((c) => moodOf(c) == 'whimsical'),
          isFalse);
    });

    test('never allocates to a cue with no observations', () {
      final plan = allocate({...measured, 'whimsical-2': 0});
      expect(plan.containsKey('whimsical-2'), isFalse);
    });

    test('a uniform histogram allocates uniformly', () {
      final flat = {for (final mood in ['tense', 'calm', 'ominous']) '$mood-1': 10};
      expect(allocate(flat, budget: 6), {'tense-1': 2, 'calm-1': 2, 'ominous-1': 2});
    });

    test('is stable across map orderings', () {
      final shuffled = Map.fromEntries(measured.entries.toList().reversed);
      expect(allocate(shuffled), allocate(measured));
    });

    test('a budget below the mood count serves the commonest moods', () {
      final plan = allocate(measured, budget: 3);
      expect(total(plan), 3);
      // Tense is two thirds of the book; it cannot be the one left out.
      expect(plan.keys.any((c) => moodOf(c) == 'tense'), isTrue);
    });

    test('degenerate inputs', () {
      expect(allocate({}), isEmpty);
      expect(allocate(measured, budget: 0), isEmpty);
      expect(allocate(measured, budget: -1), isEmpty);
      expect(allocate({'tense-1': 1}), {'tense-1': defaultBudget});
    });
  });


  group('variantFile', () {
    test('variant 0 keeps the plain name so old sets still read', () {
      expect(variantFile('tense-2', 0), 'tense-2.wav');
    });

    test('later variants are suffixed', () {
      expect(variantFile('tense-2', 1), 'tense-2-v1.wav');
      expect(variantFile('tense-2', 7), 'tense-2-v7.wav');
    });
  });
}

void _floorAndWeights() {
  group('weights and floor can be different histograms', () {
    // The measured case: ominous is tagged and never sounds, because it is
    // always scattered and never confirms. See lib/played.dart.
    const tagged = {
      'tense-2': 68, 'tense-3': 72, 'tense-1': 30, 'calm-0': 28,
      'tense-0': 11, 'ominous-3': 9, 'ominous-2': 7, 'ominous-1': 2,
      'melancholic-1': 14, 'melancholic-2': 6, 'neutral-0': 15,
      'triumphant-3': 4, 'romantic-1': 2,
    };
    const sounding = {
      'tense-2': 100, 'tense-3': 85, 'tense-1': 44, 'neutral-0': 18,
      'melancholic-2': 9, 'calm-0': 8, 'triumphant-3': 5, 'tense-0': 4,
    };

    test('a mood that never sounds still keeps a bed', () {
      final plan = allocate(sounding, floor: tagged);
      expect(plan.keys.any((c) => moodOf(c) == 'ominous'), isTrue,
          reason: 'ominous is tagged 6.4% and would otherwise be silent when '
              'a scene finally sustains it');
      expect(plan.keys.any((c) => moodOf(c) == 'romantic'), isTrue);
    });

    test('it lands on the band it was most often tagged at', () {
      // ominous-3 is the commonest tagged ominous band, so that is where the
      // one ominous bed goes.
      expect(allocate(sounding, floor: tagged)['ominous-3'], 1);
    });

    test('without the floor those moods are dropped entirely', () {
      final plan = allocate(sounding);
      expect(plan.keys.any((c) => moodOf(c) == 'ominous'), isFalse);
    });

    test('the weights are still the sounding ones', () {
      final plan = allocate(sounding, floor: tagged);
      // Sounding, tense-2 is 35.8%; tagged it is 24.4%. It should be sized
      // like the former.
      expect(plan['tense-2']!, greaterThan(allocate(tagged)['tense-2']!));
    });

    test('the budget is still exactly spent', () {
      for (final budget in [4, 8, 16, 32, 48]) {
        expect(
            allocate(sounding, floor: tagged, budget: budget)
                .values
                .fold(0, (a, b) => a + b),
            budget,
            reason: 'budget $budget');
      }
    });

    test('a floor naming a mood with no sounding cue at all still fits', () {
      final plan = allocate({'tense-2': 10}, floor: {'whimsical-1': 3},
          budget: 4);
      expect(plan.values.fold(0, (a, b) => a + b), 4);
      expect(plan['whimsical-1'], 1);
    });

    test('omitting the floor is the same as passing the weights', () {
      expect(allocate(sounding), allocate(sounding, floor: sounding));
    });
  });
}

void _floorBand() {
  group('the floor bed lands where the mood is heard', () {
    test('by sounding when the mood sounds at all', () {
      // melancholic sounds most at band 2 and is tagged most at band 1. The
      // measured case from arc 0.
      final plan = allocate(
        {'tense-2': 100, 'melancholic-2': 3, 'melancholic-1': 2},
        floor: {'tense-2': 100, 'melancholic-1': 20, 'melancholic-2': 5},
        budget: 4,
      );
      expect(plan['melancholic-2'], 1);
      expect(plan.containsKey('melancholic-1'), isFalse);
    });

    test('by tagging when the mood never sounds', () {
      final plan = allocate(
        {'tense-2': 100},
        floor: {'tense-2': 100, 'ominous-3': 9, 'ominous-1': 2},
        budget: 4,
      );
      expect(plan['ominous-3'], 1);
      expect(plan.containsKey('ominous-1'), isFalse);
    });

    test('ties still go to the quieter band', () {
      final plan = allocate(
        {'tense-2': 100},
        floor: {'tense-2': 100, 'calm-0': 5, 'calm-3': 5},
        budget: 4,
      );
      expect(plan['calm-0'], 1);
    });

    test('the budget is still exactly spent', () {
      for (final budget in [2, 4, 9, 32]) {
        final plan = allocate(
          {'tense-2': 100, 'melancholic-2': 3},
          floor: {'tense-2': 100, 'melancholic-1': 20, 'ominous-3': 9},
          budget: budget,
        );
        expect(plan.values.fold(0, (a, b) => a + b), budget,
            reason: 'budget $budget');
      }
    });
  });
}
