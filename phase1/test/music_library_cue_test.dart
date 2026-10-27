// What a loaded set does when it is asked for a cue it does not have.
//
// This is not a hypothetical. A 32-bed banded run takes about two hours and a
// per-arc run many more, and the whole point of the four palette options is to
// pick one that fits the time available -- so a set that was stopped part way
// through is an ordinary thing to be reading against, not an edge case.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/music_library.dart';
import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/palette.dart';

/// A manifest holding exactly [cues], in the shape generate_beds.py writes.
LoopLibrary libraryOf(List<String> cues) => LoopLibrary.fromManifest(
      MusicLibrary.generated,
      {
        'loops': [
          for (final cue in cues)
            {
              'cue': cue,
              'mood': moodOf(cue),
              'band': cue == moodOf(cue) ? null : int.parse(cue.split('-').last),
              'file': '$cue.wav',
            },
        ],
      },
      'assets/music',
    );

void main() {
  variants();
  group('a set describes its own vocabulary', () {
    test('one band anywhere makes the set banded', () {
      // Deliberate: a partly-generated banded run must be *read* as banded, or
      // every cue would resolve to a bare mood that was never generated.
      expect(libraryOf(['tense-0']).banded, isTrue);
      expect(libraryOf(['tense', 'calm']).banded, isFalse);
    });

    test('a mood-keyed set asks for moods, a banded one for bands', () {
      expect(libraryOf(['tense']).cueFor('tense', 0.9), 'tense');
      expect(libraryOf(['tense-0', 'tense-1']).cueFor('tense', 0.9), 'tense-1');
    });
  });

  group('a cue that was never generated', () {
    test('falls back to the other band of the same mood', () {
      // Band 1 wanted, only 0 exists -- and the other way round.
      expect(libraryOf(['tense-0']).cueFor('tense', 1.0), 'tense-0');
      expect(libraryOf(['tense-1']).cueFor('tense', 0.1), 'tense-1');
    });

    test('never reaches past the last band', () {
      // With two bands a tie cannot arise -- no band has a neighbour on each
      // side -- so the quieter-side rule in resolveCue is unexercised here
      // and kept for a wider scale. What can be checked is that the search
      // stops at the scale's ends: a cue named for a band that does not
      // exist is never offered, even if a file by that name were present.
      bool has(String cue) => const {'tense-0', 'tense-2'}.contains(cue);
      expect(resolveCue('tense', 0.9, banded: true, has: has), 'tense-0',
          reason: 'band 1 wanted, 0 exists, 2 is off the scale');
    });

    test('falls back to an unbanded bed of the same mood', () {
      // What an upgraded book looks like: eight mood-keyed beds from the first
      // run, merged with however much of the banded run finished.
      final mixed = libraryOf(['calm', 'tense-0', 'tense-1']);
      expect(mixed.cueFor('calm', 0.9), 'calm');
    });

    test('never falls back to another mood', () {
      // The rule that matters. A calm bed under a tense scene is worse than
      // silence, so an absent mood stays absent and the engine plays nothing.
      final onlyCalm = libraryOf(['calm-0', 'calm-1']);
      final cue = onlyCalm.cueFor('tense', 0.9);
      expect(moodOf(cue), 'tense');
      expect(onlyCalm.assets.containsKey(cue), isFalse);
    });
  });

  group('missing()', () {
    test('a full banded set is missing nothing', () {
      // Judged by mood, not by cue key. Judged by key, a complete 32-bed set
      // would report all eight moods missing.
      final full = libraryOf([
        for (final mood in moodParams.keys)
          for (var band = 0; band < intensityBandNames.length; band++)
            '$mood-$band',
      ]);
      expect(full.missing(moodParams.keys), isEmpty);
    });

    test('a mood with any band at all counts as present', () {
      final partial = libraryOf(['tense-0', 'calm-1']);
      expect(partial.missing(['tense', 'calm']), isEmpty);
      expect(partial.missing(['ominous']), ['ominous']);
    });

    test('the experiment library keeps its lettered keys', () {
      // moodOf only strips a *numeric* tail, so 'treatment-a' survives it.
      final treatments = libraryOf(['treatment-a', 'treatment-b']);
      expect(treatments.missing(['treatment-a', 'treatment-b']), isEmpty);
      expect(treatments.banded, isFalse);
    });
  });
}

/// A manifest where cues own several beds, in the shape generate_beds.py
/// writes once an allocation gives a cue more than one.
LoopLibrary allocated(Map<String, int> beds) => LoopLibrary.fromManifest(
      MusicLibrary.generated,
      {
        'loops': [
          for (final entry in beds.entries)
            for (var v = 0; v < entry.value; v++)
              {
                'cue': entry.key,
                'mood': moodOf(entry.key),
                'band': int.parse(entry.key.split('-').last),
                'variant': v,
                'file': v == 0 ? '${entry.key}.wav' : '${entry.key}-v$v.wav',
              },
        ],
      },
      'assets/music',
    );

void variants() {
  group('a cue can own more than one bed', () {
    test('every variant is kept, in order', () {
      final library = allocated({'tense-2': 3});
      expect(library.variantsOf('tense-2'), [
        'assets/music/tense-2.wav',
        'assets/music/tense-2-v1.wav',
        'assets/music/tense-2-v2.wav',
      ]);
    });

    test('rows out of order still lay down in variant order', () {
      final library = LoopLibrary.fromManifest(
        MusicLibrary.generated,
        {
          'loops': [
            {'cue': 'tense-2', 'band': 2, 'variant': 2, 'file': 'c.wav'},
            {'cue': 'tense-2', 'band': 2, 'variant': 0, 'file': 'a.wav'},
            {'cue': 'tense-2', 'band': 2, 'variant': 1, 'file': 'b.wav'},
          ],
        },
        'd',
      );
      expect(library.variantsOf('tense-2'), ['d/a.wav', 'd/b.wav', 'd/c.wav']);
    });

    test('assets still names the first bed, so old callers are unchanged', () {
      expect(allocated({'tense-2': 3}).assets['tense-2'],
          'assets/music/tense-2.wav');
    });

    test('a set written before variants existed reads as one bed each', () {
      final library = libraryOf(['tense-2', 'calm-0']);
      expect(library.variantsOf('tense-2'), ['assets/music/tense-2.wav']);
      expect(library.variantsOf('calm-0'), ['assets/music/calm-0.wav']);
    });

    test('a cue with no bed has no variants rather than a null one', () {
      expect(allocated({'tense-2': 2}).variantsOf('whimsical-1'), isEmpty);
    });

    test('the band fallback still works over an allocated set', () {
      // The whole reason a cue can be missing: allocate() spends nothing on a
      // band nobody reaches, and cueFor covers it from the same mood.
      final library = allocated({'tense-1': 7, 'romantic-1': 1});
      expect(library.cueFor('tense', 0.1), 'tense-1');
      expect(library.cueFor('romantic', 0.9), 'romantic-1');
    });

    test('a mood with no bed at all is still never covered by another', () {
      final library = allocated({'tense-2': 7});
      expect(moodOf(library.cueFor('calm', 0.1)), isNot('tense'));
    });

    test('one manifest row per cue reaches the inspector', () {
      final library = allocated({'tense-2': 4});
      expect(library.details['tense-2']!['variant'], 0);
    });
  });
}
