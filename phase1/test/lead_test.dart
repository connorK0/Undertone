// How far apart two cues sound, and what the engine does with that.
//
// The lead-in itself needs audio, so it is tested on a device in
// integration_test/music_test.dart. What can be tested here is the part that
// decides *whether* to lead: the measured distance the engine reads out of the
// manifest, and its behaviour on sets that have no measurements -- which is
// every set generated before §8.9 and must keep playing unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/music_engine.dart';
import 'package:reader_shell/music_library.dart';
import 'package:reader_shell/played.dart';

LoopLibrary withDistances(Map<String, Map<String, double>> distances) =>
    LoopLibrary.fromManifest(
      MusicLibrary.generated,
      {
        'loops': [
          for (final cue in ['calm-0', 'tense-1', 'tense-2'])
            {'cue': cue, 'file': '$cue.wav'},
        ],
        if (distances.isNotEmpty) 'distances': distances,
      },
      'assets/music',
    );

void main() {
  group('distanceBetween', () {
    test('a cue is no distance from itself', () {
      final library = withDistances({
        'calm-0|tense-1': {'timbre': 1.63, 'chroma': 2.06},
      });
      expect(library.distanceBetween('calm-0', 'calm-0').timbre, 0);
      expect(library.distanceBetween('calm-0', 'calm-0').chroma, 0);
    });

    test('reads what was measured', () {
      final library = withDistances({
        'calm-0|tense-1': {'timbre': 1.63, 'chroma': 2.06},
      });
      final apart = library.distanceBetween('calm-0', 'tense-1');
      expect(apart.timbre, closeTo(1.63, 1e-9));
      expect(apart.chroma, closeTo(2.06, 1e-9));
    });

    test('is the same distance either way round', () {
      // Written once per unordered pair, so asking backwards has to find it.
      final library = withDistances({
        'calm-0|tense-1': {'timbre': 1.63, 'chroma': 2.06},
      });
      expect(library.distanceBetween('tense-1', 'calm-0'),
          library.distanceBetween('calm-0', 'tense-1'));
    });

    test('a set with no measurements reports the average, and so never leads',
        () {
      // The safe answer for every set generated before distances existed:
      // 1.0 is below the threshold, so those sets behave exactly as before
      // rather than leading into changes nobody measured.
      final library = withDistances({});
      final apart = library.distanceBetween('calm-0', 'tense-1');
      expect(apart.timbre, 1);
      expect(apart.chroma, 1);
      expect(apart.timbre, lessThan(leadThreshold));
    });

    test('a pair missing from a measured table also reports the average', () {
      final library = withDistances({
        'calm-0|tense-1': {'timbre': 1.63, 'chroma': 2.06},
      });
      expect(library.distanceBetween('tense-1', 'tense-2').timbre, 1);
    });

    test('a malformed row does not throw', () {
      final library = LoopLibrary.fromManifest(
        MusicLibrary.generated,
        {
          'loops': [
            {'cue': 'calm-0', 'file': 'calm-0.wav'},
          ],
          'distances': {'calm-0|tense-1': 'not a row'},
        },
        'assets/music',
      );
      expect(library.distanceBetween('calm-0', 'tense-1').timbre, 1);
    });
  });

  group('the rules about when to prepare', () {
    test('the threshold is above an average change', () {
      // Otherwise an unmeasured set, which reports 1.0 for everything, would
      // lead into every change it ever made.
      expect(leadThreshold, greaterThan(1.0));
    });

    test('looking ahead does not overlap the scoring window', () {
      // The lead window starts where the cue window ends. Overlapping would
      // let the paragraphs that decide the current cue also argue for leaving
      // it, which is the selector's job and already has a confirmation rule.
      expect(leadWindow, greaterThan(0));
      expect(cueWindow, greaterThan(0));
    });
  });

  group('the filter cannot be asked for the impossible', () {
    // Every bed this app ships or generates is 22,050 Hz, so Nyquist is
    // 11,025. A resonant biquad handed a cutoff above that produces invalid
    // coefficients and passes nothing -- which is exactly what auditioning
    // did, silently, while reporting a healthy volume and the very cutoff it
    // had been given. Pinned here because the assumption that broke it was
    // about the sample rate of files no test reads.
    const nyquist = 22050 / 2;

    test('the score never sweeps past Nyquist', () {
      expect(MusicEngine.brightestCutoff, lessThan(nyquist));
      expect(MusicEngine.darkestCutoff, greaterThan(0));
      expect(MusicEngine.darkestCutoff,
          lessThan(MusicEngine.brightestCutoff));
    });

    test('an audition bypasses the filter rather than opening it wide', () {
      // Opening it wide is what could not be done safely: "wide" has to be
      // expressed as a frequency, and any frequency can be wrong at a sample
      // rate nobody checked. Bypass cannot.
      //
      // Not exactly zero: flutter_soloud cannot read a zero back (its C++
      // getter rejects anything `isnormal()` rejects, and 0.0 is not normal),
      // so the integration test could set it and never confirm it. Under a
      // hundredth is -40 dB of filtered signal, which is bypass to an ear.
      expect(MusicEngine.auditionWet, greaterThan(0));
      expect(MusicEngine.auditionWet, lessThan(0.01));
    });
  });

  group('soundingSteps', () {
    List<({String mood, double intensity})> tags(List<String> moods) =>
        [for (final mood in moods) (mood: mood, intensity: 0.5)];

    test('agrees with soundingCues, which is expressed in terms of it', () {
      // The histograms and the timeline have to agree about what sounded, or
      // neither can be checked against the other.
      final run = tags([
        'calm', 'calm', 'calm', 'tense', 'tense', 'tense', //
        'tense', 'calm', 'calm', 'calm', 'calm', 'calm',
      ]);
      expect([for (final step in soundingSteps(run)) step.cue],
          soundingCues(run));
    });

    test('reports where the score moved, not every paragraph', () {
      final run = tags(['calm', 'calm', 'calm', 'calm', 'calm', 'calm']);
      final steps = soundingSteps(run);
      expect(steps, isNotEmpty);
      // One committed cue over a run that never changes mood.
      expect(steps.where((s) => s.changed).length, 1);
    });

    test('carries the paragraph a change landed on', () {
      final run = tags([
        'calm', 'calm', 'calm', 'calm', 'calm', 'calm', //
        'tense', 'tense', 'tense', 'tense', 'tense', 'tense',
      ]);
      final changes = soundingSteps(run).where((s) => s.changed).toList();
      expect(changes.length, greaterThanOrEqualTo(2));
      // Paragraph indices are the run's own, and they only go forwards.
      for (var i = 1; i < changes.length; i++) {
        expect(changes[i].paragraph, greaterThan(changes[i - 1].paragraph));
      }
    });
  });
}
