/// EXPERIMENT -- Phase 5, Task 0. Delete once the question is answered.
///
/// Phase 4 measured that the score holds one cue for 20-56 consecutive
/// paragraphs. Mood is too coarse a signal to move the music, so a bigger
/// mood-keyed library would change nothing at all: eight beds or eighty, a
/// constant signal plays a constant bed.
///
/// The proposed fix is a second axis -- one theme, several treatments of it,
/// chosen by something that does move within a held mood. This file is the
/// smallest thing that tests whether that is musical, before anything is built
/// on the assumption that it is.
///
/// Intensity is the axis, because it is the one already measured to move: over
/// the Carol's 56-paragraph stretch on a single cue, the classifier's intensity
/// swings 0.20 to 0.90 while the mood label never changes once.
///
/// Why these numbers
/// -----------------
/// Simulated against those real cached tags, through the same [dominantTag]
/// smoothing the engine already applies:
///
///   * banding on every observation gives **28 changes over 56 paragraphs** --
///     one every two paragraphs. That is the churn that reads as random rather
///     than rich, and it is what this experiment would have measured if the
///     bands were simply wired in.
///   * requiring a band to be seen twice before believing it gives **9 changes
///     over the same 56 paragraphs**, about one per six -- roughly one move
///     every four minutes of reading, which is a score's timescale.
///
/// Two confirmations is already [CueSelector]'s default, so nothing new is
/// needed to get the second number: feeding it treatment keys where it used to
/// get moods reuses the anti-thrash rules unchanged. That is the reason this
/// experiment needs no new selector and no audio changes -- the engine treats
/// the cue key as opaque.
///
/// The Phase 4 baseline over this stretch is 0 changes.
///
/// Where it stands
/// ---------------
/// Provisional. A short listening test found the moves between treatments
/// clean, which rules out the loud failure -- the changes are not jarring and
/// do not read as random at this rate -- but a test that short cannot answer
/// whether the effect survives an hour, which is the timescale that matters.
/// Tasks 2-4 stay blocked on a longer sitting; lib/inspector_panel.dart exists
/// so that second sitting produces evidence rather than another impression.
library;

/// Treatment keys, quietest to heaviest. These are the asset names in
/// assets/music/experiment/, written by tool/make_theme_treatments.py.
const treatmentKeys = [
  'treatment-a', // theme fragment, half speed, Dorian
  'treatment-b', // the theme plain, one voice, Aeolian
  'treatment-c', // theme in thirds over a minor pad, Aeolian
  'treatment-d', // theme an octave down and doubled, Phrygian, pulsing
];

/// Band edges on the classifier's intensity. Even quarters: the simulation
/// above found no reason to prefer anything cleverer, and a tighter middle
/// band moved more often without using more of the ladder.
const treatmentEdges = [0.35, 0.55, 0.75];

/// Which treatment a paragraph's smoothed intensity asks for.
///
/// Takes the classifier's intensity rather than the mapper's `energy`. Energy
/// blends the mood's floor with intensity and is deliberately compressed for
/// volume -- for 'tense' the full 0-1 intensity range becomes 0.35-0.85, and
/// the floor differs per mood, so bands over it would mean something different
/// in every mood. Intensity is the signal; energy is one use of it.
String treatmentFor(double intensity) {
  for (var i = 0; i < treatmentEdges.length; i++) {
    if (intensity < treatmentEdges[i]) return treatmentKeys[i];
  }
  return treatmentKeys.last;
}
