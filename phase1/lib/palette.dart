/// How big a book's set of beds is, and how a tag picks one out of it.
///
/// Two independent axes, which is what makes four options rather than a list:
///
///   * **size** -- one bed per mood, or one per mood *and intensity band*;
///   * **scope** -- one set for the whole book, or one per arc of it.
///
/// Both cost GPU time in the same currency (about 3.4 minutes per bed,
/// measured), so which of the four to run is a question of how long there is
/// rather than of what is best. Nothing here chooses: the generator writes what
/// it was asked for and records it in the manifest, and the app plays what it
/// finds. A setting that could disagree with what is on disk would be a way to
/// get silence.
library;

/// Where the intensity bands divide, for the banded palettes.
///
/// Two bands, and one edge. There were four (`[0.35, 0.55, 0.75]`), measured
/// in Phase 5 Task 0 for how often they made the score *move* -- and they
/// still would. What they could not do was sound different: SUMMARY §9.24
/// found bands 0-2 held 42 % of the reading time as one indistinguishable
/// cluster, and §9.26-§9.27 found the prompt can reach exactly two registers,
/// dark and bright, whatever it is asked. Four names for two sounds is
/// three crossfades in four that change nothing.
///
/// The edge is measured (§9.30): replaying arc 0 of the test book, 0.65
/// keeps 261 of the four-band 359 cue changes, moves the median hold from
/// 3.3 to 4.0 minutes, and splits tense 41 / 59 between the two bands where
/// 0.55 gives 19 / 81 -- one band that is the whole book and one that is
/// the exception.
///
/// Moved to 0.75 (§9.43) when the paragraph prompt was
/// reworded. Under the new tags 0.65 put the peak band under a third of arcs
/// 0-1, because the model rates most tense paragraphs 0.8. At 0.75 it is
/// about one paragraph in six (16 %), the exception again. 0.85 was measured
/// too and leaves the peak band almost never playing (2 %).
const intensityBandEdges = [0.75];

/// What to call each band where a person will read it.
///
/// The two ends of the old four-band scale, so that "still" and "peak" in an
/// older manifest or an inspector screenshot still mean what they meant.
/// The band *number* is what the engine keys on; a four-band set's band 3
/// and this set's band 1 are both "peak" and both resolve by number.
const intensityBandNames = ['still', 'peak'];

/// Which band an intensity falls in, 0 to [intensityBandEdges.length].
int bandFor(double intensity) {
  var band = 0;
  for (final edge in intensityBandEdges) {
    if (intensity >= edge) band++;
  }
  return band;
}

/// The cue a tag asks for.
///
/// The engine treats this as opaque -- the selector, the crossfade and the
/// filter sweep all work on the key without caring what is in it -- which is
/// why a banded palette needs no new selector and no audio changes at all.
String cueForPalette(String mood, double intensity,
        {required bool banded}) =>
    banded ? '$mood-${bandFor(intensity)}' : mood;

/// The cue a tag asks for, among the beds a set actually has.
///
/// [cueForPalette] names what the tag *wants*; this is what it *gets*. A set
/// stopped part way through generation, or sized by `allocate` to what the arc
/// mostly sounds like, owns beds for some cues and not others -- arc 0 of the
/// test book has twelve of its thirty-two. A missing cue falls back to the
/// nearest band of **the same mood**, quieter side first, since a stiller bed
/// under a fierce paragraph is a gentler failure than a fierce one under a
/// still paragraph.
///
/// Never to another mood. A calm bed under a tense scene is worse than
/// silence.
///
/// One function, called by both the engine (`MusicLibrary.cueFor`) and the
/// offline replay (`soundingSteps`), because §9.24 found them disagreeing:
/// the replay named cues the set did not have, counted changes between two
/// names the engine resolves to one bed, and could not look up distances for
/// 11% of its pairs. [has] says whether a cue has a bed.
String resolveCue(
  String mood,
  double intensity, {
  required bool banded,
  required bool Function(String cue) has,
}) {
  final wanted = cueForPalette(mood, intensity, banded: banded);
  if (has(wanted) || !banded) return wanted;

  final from = bandFor(intensity);
  for (var step = 1; step < intensityBandNames.length; step++) {
    for (final band in [from - step, from + step]) {
      if (band < 0 || band >= intensityBandNames.length) continue;
      if (has('$mood-$band')) return '$mood-$band';
    }
  }
  // A banded set can still carry unbanded rows -- a mood-keyed run merged
  // into the same manifest, which is exactly what an upgraded book has.
  return has(mood) ? mood : wanted;
}

/// The mood a cue came from, whether or not it carries a band.
String moodOf(String cue) {
  final at = cue.lastIndexOf('-');
  if (at < 0) return cue;
  final tail = cue.substring(at + 1);
  return int.tryParse(tail) == null ? cue : cue.substring(0, at);
}

/// Which arc a chapter belongs to, given the arc size in chapters.
///
/// Zero or negative means the book is one arc, which is the whole-book case
/// rather than a special case.
int arcOf(int chapter, int arcSize) =>
    arcSize <= 0 ? 0 : chapter ~/ arcSize;

/// The directory name an arc's beds live in, under the book's own directory.
String arcDirectory(int arc) => 'arc-${arc.toString().padLeft(3, '0')}';
