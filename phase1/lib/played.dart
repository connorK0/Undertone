/// Which cue is *sounding* on each paragraph, as opposed to which was tagged.
///
/// A tag is not a cue. Between the classifier and the speakers sit three
/// things, and all of them move the distribution:
///
///   * [dominantTag] takes the weighted-dominant mood of a [cueWindow]-long
///     window, so a single odd paragraph never reaches the selector at all;
///   * that same window averages intensity, which pulls bands toward the middle
///     and away from the extremes the raw tags reach;
///   * [CueSelector] needs a new cue confirmed on two separate paragraphs and
///     holds the old one for its dwell regardless.
///
/// Measured on eight wholly-classified chapters of the test book, 279
/// paragraphs, the difference is not small:
///
///     tense-2       24.4% tagged -> 35.8% sounding
///     tense-3       25.8%        -> 30.5%
///     calm-0        10.0%        ->  2.9%
///     ominous-1/2/3  6.4%        ->  0.0%   never confirms
///     romantic-1     0.7%        ->  0.0%
///
/// Seven of thirty-two beds move. Ominous was tagged eighteen times and never
/// once got two consecutive paragraphs, so it never sounded -- while tense,
/// which is 65% of tags, is 84% of what plays.
///
/// This is what a bed set should be sized against, because a bed is heard for
/// as long as its cue sounds and not for as long as its mood is tagged. See
/// [allocate], which takes the sounding counts as weights and the tagged ones
/// as the floor: a mood that never sounds here may well sound in a scene that
/// sustains it, and having no bed for it at all is the one failure worse than
/// the wrong bed.
library;

import 'cue_selector.dart';
import 'palette.dart';

/// Rounding that MusicParams applies before the band is chosen, and therefore
/// what decides which side of a band edge a paragraph falls on.
double _round2(double value) => (value * 100).round() / 100;

/// The cue sounding on each paragraph of one contiguous run of tags.
///
/// One entry per input tag, in order. [tags] must be contiguous and in reading
/// order -- a gap would let the window borrow a neighbour the reader never saw,
/// which is exactly the thing a scattered sample cannot support.
///
/// The selector starts fresh, so the first paragraph of a run always commits.
/// That is one observation of overstatement per run, which is why a run should
/// be as long as the reading is continuous -- see [contiguousRuns], which joins
/// chapters rather than breaking at every turn. Splitting an arc into 66
/// chapter-runs would manufacture 66 commits that never happen.
List<String> soundingCues(
  List<({String mood, double intensity})> tags, {
  int window = cueWindow,
  Duration perParagraph = const Duration(seconds: 40),
  Set<String>? beds,
}) =>
    [for (final step in soundingSteps(tags, window: window,
        perParagraph: perParagraph, beds: beds)) step.cue];

/// One entry per paragraph the selector answered for, with where the score
/// actually moved.
///
/// [soundingCues] is this with everything but the cue dropped. Kept as one
/// walk rather than two because a second replay of the selector is a parity
/// bug waiting to happen: the histograms and the timeline have to agree about
/// what sounded or neither can be trusted against the other.
///
/// [beds] is which cues the set actually has. With it, a cue the set lacks
/// resolves to the one the engine would play instead ([resolveCue]), so the
/// replay counts the changes the reader hears rather than the ones the tags
/// ask for -- §9.24 found the two differ by 2 % of changes and 11 % of
/// distance lookups on arc 0. Without it, the raw cue, which is right for
/// sizing a set that does not exist yet.
List<({int paragraph, String cue, bool changed})> soundingSteps(
  List<({String mood, double intensity})> tags, {
  int window = cueWindow,
  Duration perParagraph = const Duration(seconds: 40),
  Set<String>? beds,
}) {
  final selector = CueSelector();
  var now = DateTime(2026);
  final steps = <({int paragraph, String cue, bool changed})>[];
  for (var at = 0; at < tags.length; at++) {
    final ahead = tags.sublist(at, (at + window).clamp(0, tags.length));
    final dominant = dominantTag(ahead);
    if (dominant == null) continue;
    final intensity = _round2(dominant.intensity);
    final decision = selector.observe(
      paragraphIndex: at,
      mood: beds == null
          ? cueForPalette(dominant.mood, intensity, banded: true)
          : resolveCue(dominant.mood, intensity,
              banded: true, has: beds.contains),
      // The selector does not use energy to decide anything; it carries it for
      // the engine's benefit. A constant keeps this honest about that.
      energy: 0.5,
      now: now,
    );
    now = now.add(perParagraph);
    if (decision != null) {
      steps.add((
        paragraph: at,
        cue: decision.mood,
        changed: decision.changed,
      ));
    }
  }
  return steps;
}

/// What was tagged and what sounded, over a set of contiguous runs.
///
/// [runs] is one entry per *continuously readable stretch*, not per chapter --
/// build it with [contiguousRuns]. Each run is replayed with its own selector,
/// so runs should be split only where the reading genuinely breaks: at a
/// paragraph the classifier never answered for, which cannot be windowed
/// across.
///
/// [beds] resolves what *sounds* through the set's fallback, as
/// [soundingSteps] does; what is *tagged* is always the raw cue, because it
/// is the demand a set is being sized against, not the supply.
({Map<String, int> tagged, Map<String, int> sounding, int changes}) histograms(
  Iterable<List<({String mood, double intensity})>> runs, {
  Set<String>? beds,
}) {
  final tagged = <String, int>{};
  final sounding = <String, int>{};
  var changes = 0;
  for (final run in runs) {
    for (final tag in run) {
      final cue = cueForPalette(tag.mood, tag.intensity, banded: true);
      tagged[cue] = (tagged[cue] ?? 0) + 1;
    }
    String? last;
    for (final cue in soundingCues(run, beds: beds)) {
      sounding[cue] = (sounding[cue] ?? 0) + 1;
      if (cue != last) changes++;
      last = cue;
    }
  }
  return (tagged: tagged, sounding: sounding, changes: changes);
}

/// Contiguous runs from a sequence of chapters, each holding one entry per
/// paragraph and null where a tag is missing.
///
/// Chapters are concatenated, not kept apart. The reader reads them in order
/// and the engine keeps playing across the turn, so the selector's state
/// carries over -- treating each chapter as its own run would hand every
/// chapter's opening cue a free commit and, over an arc, count dozens of cue
/// changes that never happen.
///
/// A null breaks the run: it is a paragraph the model never returned a tag for,
/// and windowing across it would let the window borrow a neighbour the reader
/// never had. So does the end of the input.
///
/// Runs shorter than [minimum] are dropped. A run of one cannot be windowed
/// into anything the selector would see differently, and counting it would be
/// counting a free commit.
List<List<T>> contiguousRuns<T extends Object>(
  Iterable<List<T?>> chapters, {
  int minimum = 2,
}) {
  final runs = <List<T>>[];
  var run = <T>[];
  void end() {
    if (run.length >= minimum) runs.add(run);
    run = [];
  }

  for (final chapter in chapters) {
    for (final entry in chapter) {
      if (entry == null) {
        end();
        continue;
      }
      run.add(entry);
    }
  }
  end();
  return runs;
}
