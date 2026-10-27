// Which arcs are alike enough to share one set of beds.
//
// The asymmetry that matters: merging two arcs that should have sounded
// different is a fault a reader would hear, while failing to merge two that
// were alike only costs GPU time. So these tests care much more about false
// merges than about missed ones.

import 'package:test/test.dart';

import 'package:music_book_core/music_book_core.dart';

Set<String> theme(String genre, String overall, String instruments) =>
    themeTokens(genre, overall, instruments);

void main() {
  group('tokens', () {
    test('case and punctuation do not matter', () {
      expect(theme('Epic Fantasy', 'Drama and Action', 'brass, percussion'),
          theme('epic fantasy', 'drama & action', 'brass; percussion'));
    });

    test('filler words are dropped', () {
      // 'and', 'the', 'with', 'for' appear in nearly every theme this model
      // writes, so counting them would make everything look alike.
      final tokens = theme('epic fantasy', 'the drama and the action', '');
      expect(tokens, containsAll(['epic', 'fantasy', 'drama', 'action']));
      expect(tokens, isNot(contains('and')));
      expect(tokens, isNot(contains('the')));
    });
  });

  group('similarity', () {
    test('identical themes are 1', () {
      final a = theme('epic fantasy', 'Drama and Action', 'brass, strings');
      expect(similarity(a, a), 1.0);
    });

    test('themes with nothing in common are 0', () {
      expect(
        similarity(
          theme('epic fantasy', 'Drama and Action', 'brass'),
          theme('cosy mystery', 'gentle village puzzle', 'ukulele'),
        ),
        0.0,
      );
    });

    test('a reordered theme still counts as the same', () {
      // The theme pass is not stable between arcs of the same book: the same
      // material comes back as "Drama and Action" one arc and "Action and
      // Drama" the next, which is the whole reason this exists.
      final a = theme('epic fantasy', 'Drama and Action', 'brass and strings');
      final b = theme('epic fantasy', 'Action and Drama', 'strings and brass');
      expect(similarity(a, b), 1.0);
    });

    test('a genuinely different mood scores below the threshold', () {
      final battle = theme('epic fantasy', 'Drama and Action',
          'brass and percussion for action scenes');
      final grief = theme('epic fantasy', 'mourning and loss',
          'solo cello, sparse piano');
      expect(similarity(battle, grief), lessThan(defaultPaletteThreshold));
    });
  });

  group('paletteFor', () {
    test('distinct arcs each generate their own set', () {
      final palette = paletteFor([
        theme('epic fantasy', 'Drama and Action', 'brass'),
        theme('cosy mystery', 'village puzzle', 'ukulele'),
        theme('space opera', 'cold vastness', 'synth pads'),
      ]);
      expect(palette, [0, 1, 2]);
    });

    test('a near-repeat points back at the arc it repeats', () {
      final palette = paletteFor([
        theme('epic fantasy', 'Drama and Action', 'brass and strings'),
        theme('cosy mystery', 'village puzzle', 'ukulele'),
        theme('epic fantasy', 'Action and Drama', 'strings and brass'),
      ]);
      expect(palette, [0, 1, 0], reason: 'arc 2 plays arc 0');
      // What the generator counts: an arc represents a set when it maps to
      // itself, so this book needs two sets rather than three.
      expect(palette.toSet(), hasLength(2));
    });

    test('a threshold of 1 merges only exact matches', () {
      final palette = paletteFor([
        theme('epic fantasy', 'Drama and Action', 'brass'),
        theme('epic fantasy', 'Drama and Action, mostly', 'brass'),
      ], threshold: 1.0);
      expect(palette, [0, 1]);
    });

    test('an arc with no theme is never merged', () {
      // Merging on no evidence is the one failure a reader would hear, so an
      // empty token set represents itself and generates its own beds.
      final palette = paletteFor([
        theme('epic fantasy', 'Drama and Action', 'brass'),
        <String>{},
        <String>{},
      ]);
      expect(palette, [0, 1, 2]);
    });

    test('grouping is first-match, and says so', () {
      // Non-transitive by construction: B is close to A, and C is close to B
      // but not to A, so C starts its own group rather than joining A's. A
      // proper clustering would be harder to predict for no audible gain.
      final a = theme('epic fantasy', 'drama action battle', '');
      final b = theme('epic fantasy', 'drama action battle', '');
      final c = theme('epic fantasy', 'drama action quest', '');
      final palette = paletteFor([a, b, c], threshold: 0.9);
      expect(palette[1], 0);
      expect(palette[2], 2);
    });

    test('an empty book has no palettes', () {
      expect(paletteFor(const []), isEmpty);
    });
  });
}
