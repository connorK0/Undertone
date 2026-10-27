// The two axes a generated set can vary on: how many cues it has, and how
// much of the book one set covers.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/music_params.dart';
import 'package:reader_shell/palette.dart';

void main() {
  group('intensity bands', () {
    test('the edge is where SUMMARY 9.43 measured it', () {
      // Not taste alone. 9.30 measured 0.65 on the first tags; 9.43 replayed
      // 0.65, 0.75 and 0.85 on the reworded prompt's tags, and 0.75 is the
      // one that leaves the peak band the exception (16 % of arcs 0-1) rather
      // than a third of the book or almost never. Moving it is a
      // measurement, not an edit.
      expect(intensityBandEdges, [0.75]);
      expect(intensityBandNames, hasLength(intensityBandEdges.length + 1));
    });

    test('every intensity lands in exactly one band', () {
      expect(bandFor(0.0), 0);
      expect(bandFor(0.74), 0);
      expect(bandFor(0.75), 1, reason: 'an edge belongs to the band above');
      expect(bandFor(1.0), 1);
    });

    test('bands only ever climb', () {
      var last = -1;
      for (var i = 0; i <= 100; i++) {
        final band = bandFor(i / 100);
        expect(band, greaterThanOrEqualTo(last));
        expect(band, inInclusiveRange(0, intensityBandEdges.length));
        last = band;
      }
    });
  });

  group('cue keys', () {
    test('a mood-keyed set asks for the mood, whatever the intensity', () {
      for (final intensity in [0.0, 0.4, 0.9, 1.0]) {
        expect(cueForPalette('tense', intensity, banded: false), 'tense');
      }
    });

    test('a banded set asks for the mood and the band', () {
      expect(cueForPalette('tense', 0.2, banded: true), 'tense-0');
      expect(cueForPalette('tense', 0.9, banded: true), 'tense-1');
    });

    test('the four options differ only in how many cues exist', () {
      // Eight moods, or eight moods times two bands. This is the whole of the
      // size axis, and it is what the GPU time is spent on.
      final moods = {
        for (final mood in moodParams.keys)
          cueForPalette(mood, 0.5, banded: false),
      };
      final banded = <String>{
        for (final mood in moodParams.keys)
          for (final intensity in [0.1, 0.4, 0.6, 0.9])
            cueForPalette(mood, intensity, banded: true),
      };
      expect(moods, hasLength(8));
      expect(banded, hasLength(8 * intensityBandNames.length));
    });

    test('a cue can be read back to its mood', () {
      // The inspector and the cue log both want the mood behind the key.
      for (final mood in moodParams.keys) {
        expect(moodOf(cueForPalette(mood, 0.8, banded: true)), mood);
        expect(moodOf(cueForPalette(mood, 0.8, banded: false)), mood);
      }
      // A mood with a dash in it, and a treatment key, both survive.
      expect(moodOf('treatment-a'), 'treatment-a');
      expect(moodOf('some-mood-2'), 'some-mood');
    });
  });

  group('arcs', () {
    test('no arc size means the whole book is one arc', () {
      for (final chapter in [0, 5, 861, 2363]) {
        expect(arcOf(chapter, 0), 0);
        expect(arcOf(chapter, -1), 0);
      }
    });

    test('chapters fall into arcs of the given size', () {
      expect(arcOf(0, 50), 0);
      expect(arcOf(49, 50), 0);
      expect(arcOf(50, 50), 1);
      expect(arcOf(2363, 50), 47);
    });

    test('arc directories sort in reading order', () {
      // Zero-padded, so a shell listing of 2,364 chapters worth of arcs is in
      // the order they are read rather than 0, 1, 10, 100.
      final names = [for (var i = 0; i < 12; i++) arcDirectory(i * 5)];
      final sorted = [...names]..sort();
      expect(names, sorted);
      expect(arcDirectory(0), 'arc-000');
      expect(arcDirectory(47), 'arc-047');
    });
  });
}
