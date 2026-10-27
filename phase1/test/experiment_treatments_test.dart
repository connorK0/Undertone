// EXPERIMENT -- Phase 5, Task 0. Delete with lib/experiment_treatments.dart.
//
// This test exists to record a measurement rather than to guard a feature. The
// claim Phase 5 rests on is that a second axis moves where mood does not, and
// the claim has a number: over the same 56 paragraphs, mood changes the cue
// zero times and intensity-banded treatments change it nine.
//
// The fixture is the real cached classification of stave I of A Christmas
// Carol, paragraphs 0-55 -- the longest single-cue stretch measured in Phase 4.
// Copied out of the cue-timeline cache rather than invented, because the whole
// question is what actual prose does.

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/cue_selector.dart';
import 'package:reader_shell/experiment_treatments.dart';
import 'package:reader_shell/music_engine.dart';

/// (mood, intensity) per paragraph, from the Phase 4 run on stave I.
const carolStretch = <(String, double)>[
  ('tense', 0.7), ('tense', 0.7), ('tense', 0.7), ('tense', 0.7),
  ('tense', 0.7), ('tense', 0.8), ('ominous', 0.8), ('melancholic', 0.6),
  ('tense', 0.5), ('melancholic', 0.7), ('tense', 0.7), ('whimsical', 0.2),
  ('romantic', 0.3), ('tense', 0.3), ('tense', 0.8), ('triumphant', 0.3),
  ('tense', 0.7), ('tense', 0.8), ('tense', 0.7), ('tense', 0.5),
  ('tense', 0.5), ('melancholic', 0.7), ('ominous', 0.7), ('tense', 0.7),
  ('tense', 0.3), ('tense', 0.7), ('tense', 0.5), ('calm', 0.2),
  ('tense', 0.3), ('romantic', 0.2), ('tense', 0.8), ('neutral', 0.2),
  ('ominous', 0.7), ('tense', 0.5), ('tense', 0.3), ('ominous', 0.8),
  ('melancholic', 0.7), ('tense', 0.7), ('tense', 0.7), ('tense', 0.7),
  ('tense', 0.7), ('calm', 0.2), ('melancholic', 0.7), ('tense', 0.7),
  ('ominous', 0.8), ('tense', 0.3), ('calm', 0.2), ('tense', 0.8),
  ('ominous', 0.9), ('ominous', 0.7), ('tense', 0.7), ('tense', 0.7),
  ('tense', 0.7), ('tense', 0.7), ('tense', 0.7), ('melancholic', 0.8),
];

/// The engine's own smoothing, over the same window it uses.
///
/// [boost] is 1.0 for the measurements this file records, which were taken
/// before SUMMARY 9.43 boosted the minority moods' vote; the engine now uses
/// [minorityWeight]. See the last test for what the boost does here.
({String mood, double intensity})? smoothedAt(int position,
    {double boost = 1.0}) {
  final window = <({String mood, double intensity})>[];
  for (var i = position; i < position + MusicEngine.cueWindow; i++) {
    if (i >= carolStretch.length) break;
    window.add((mood: carolStretch[i].$1, intensity: carolStretch[i].$2));
  }
  return dominantTag(window, boost: boost);
}

/// Read the stretch at a realistic pace and count cue changes.
///
/// A paragraph is about 40 seconds of reading, so the 15-second dwell never
/// binds here; what is being measured is the confirmation rule alone.
({int changes, Set<String> used, String timeline}) readThrough(
  String Function(({String mood, double intensity})) cueFor, {
  int confirmations = 2,
  double boost = 1.0,
}) {
  final selector = CueSelector(confirmations: confirmations);
  var now = DateTime(2026);
  var changes = 0;
  final used = <String>{};
  final timeline = StringBuffer();

  for (var p = 0; p < carolStretch.length; p++) {
    final smoothed = smoothedAt(p, boost: boost);
    if (smoothed == null) continue;
    final decision = selector.observe(
      paragraphIndex: p,
      mood: cueFor(smoothed),
      energy: smoothed.intensity,
      now: now,
    );
    now = now.add(const Duration(seconds: 40));
    if (decision == null) continue;
    if (decision.changed) changes++;
    used.add(decision.mood);
    timeline.write(decision.mood.split('-').last[0].toUpperCase());
  }
  return (changes: changes, used: used, timeline: timeline.toString());
}

void main() {
  test('the bands cover the ladder and nothing falls off either end', () {
    expect(treatmentFor(0.0), 'treatment-a');
    expect(treatmentFor(0.2), 'treatment-a');
    expect(treatmentFor(0.35), 'treatment-b', reason: 'edges are inclusive up');
    expect(treatmentFor(0.5), 'treatment-b');
    expect(treatmentFor(0.55), 'treatment-c');
    expect(treatmentFor(0.7), 'treatment-c');
    expect(treatmentFor(0.75), 'treatment-d');
    expect(treatmentFor(1.0), 'treatment-d');
    expect(treatmentEdges.length, treatmentKeys.length - 1);
  });

  test('mood alone does not move the score across this stretch', () {
    // The Phase 4 baseline, and the reason Phase 5 exists. Fifty-six
    // paragraphs of real prose, and the cue is chosen once.
    final run = readThrough((s) => s.mood);

    expect(run.changes, 1, reason: 'only the initial choice: ${run.timeline}');
    expect(run.used, {'tense'},
        reason: 'one cue for the whole stretch, however the tags moved');
  });

  test('intensity-banded treatments move about once every six paragraphs', () {
    final run = readThrough((s) => treatmentFor(s.intensity));

    // Nine changes over 56 paragraphs at roughly 40 seconds each is one move
    // per four minutes of reading. The number is recorded rather than merely
    // bounded, because if a later change moves it, the thing to do is listen
    // again -- not adjust the bound.
    expect(run.changes, 9, reason: 'timeline: ${run.timeline}');
    expect(run.used.length, 4, reason: 'the whole ladder gets used');
  });

  test('without the confirmation rule the same signal churns', () {
    // Why CueSelector is reused rather than replaced. Believing every banded
    // observation gives a change every other paragraph, which is the failure
    // mode the experiment is meant to avoid rather than demonstrate.
    final run = readThrough((s) => treatmentFor(s.intensity), confirmations: 1);

    expect(run.changes, greaterThan(20),
        reason: 'confirmations=1 churns: ${run.timeline}');
  });

  test('with the minority boost, mood alone now moves the score here', () {
    // SUMMARY 9.43. The stretch's melancholic passages, between tense ones,
    // were swallowed by the window; with the engine's boost three of them are
    // heard. Recorded, like the numbers above: if it moves, listen again.
    final run = readThrough((s) => s.mood, boost: minorityWeight);

    expect(run.changes, 6, reason: 'timeline: ${run.timeline}');
    expect(run.used, {'tense', 'melancholic'});
  });
}
