/// How many beds each cue gets, from what an arc actually contains.
///
/// The palette used to be a cartesian product: eight moods times four
/// intensity bands, one bed each, thirty-two beds. That spends the budget
/// uniformly on a distribution that is anything but. Measured over nine
/// chapters of the test book, a long web serial (301 cached tags):
///
///     tense-2         76   25.2%     <- one file, a quarter of what is read
///     tense-3         73   24.3%
///     tense-1         35   11.6%
///     calm-0          30   10.0%
///     ...
///     romantic-0       1    0.3%     <- its own bed, heard once
///     romantic-2       1    0.3%
///     whimsical        0    0.0%     <- four beds, never reached
///
/// So the most-heard cue and the least-heard cue cost the same to make and got
/// the same share. Tense alone is 195 of 301 tags, 65%, spread over four beds;
/// whimsical did not occur once in nine chapters and holds four.
///
/// Nothing here decides what an arc contains -- tool/allocate.dart classifies a
/// sample of the arc and hands the counts over. This is the arithmetic, kept
/// separate because it is the part with edge cases and the part worth testing.
library;

import 'palette.dart';

/// The default number of beds per set. Unchanged: this redistributes the same
/// budget rather than asking for a bigger one.
const defaultBudget = 32;

/// Count cues the way the engine asks for them.
///
/// Bands come from [bandFor], the same function the selector uses, so the
/// histogram is in the vocabulary that will actually be played rather than a
/// parallel one that could drift from it.
Map<String, int> histogramOf(Iterable<(String, double)> tags) {
  final counts = <String, int>{};
  for (final (mood, intensity) in tags) {
    final cue = cueForPalette(mood, intensity, banded: true);
    counts[cue] = (counts[cue] ?? 0) + 1;
  }
  return counts;
}

/// How many beds each cue should get, given how often it came up.
///
/// A count of 2 or more means that many *variants* of one cue -- same prompt,
/// different seeds -- which the engine rotates through so a long stretch on one
/// cue is not one file on repeat. A cue absent from the result gets no bed of
/// its own and is served by [LoopLibrary.cueFor]'s fall back to the nearest
/// band of the same mood.
///
/// Two rules, in this order:
///
/// 1. **Proportional.** Largest-remainder apportionment over the observed
///    counts, which is the same method used to divide seats by votes and has
///    the property that matters here: no cue is more than one bed away from
///    its exact share.
/// 2. **One bed per mood, always.** [LoopLibrary.cueFor] falls back across
///    bands but never across moods -- a calm bed under a tense scene is worse
///    than silence -- so a mood with no bed *is* silence wherever it occurs.
///    Rule 1 would drop romantic at 1.3%, so any mood left empty takes a bed
///    from whichever cue has the most to spare.
///
/// [floor] is the histogram rule 2 reads, and it is a separate argument for a
/// reason that only became visible once the two were measured apart. Weights
/// should come from what *sounds* (lib/played.dart); the floor must come from
/// what is *tagged*. On this book ominous is tagged 6.4% of the time and sounds
/// 0% -- it is always scattered, so it never confirms. Taking the floor from
/// the sounding histogram would leave ominous out of the set entirely, and then
/// the first arc that sustains an ominous scene has no bed for it and plays the
/// tense one underneath. Defaults to [histogram], which is the right answer
/// when there is only one.
///
/// Rule 2 costs rule 1 very little. On the measured histogram it moves one
/// bed: romantic is 4 tags in 301 and rounds to nothing, so it takes one from
/// `tense-2`, which goes from 8 variants to 7.
///
/// A mood absent from the *sample* gets nothing, which is the one way this can
/// be wrong -- whimsical is 0 of 301 here and would be planned out of the set
/// entirely. At the sample size tool/allocate.dart uses that is unlikely rather
/// than impossible, and the cost is bounded: [LoopLibrary.cueFor] finds no bed,
/// the engine keeps playing what it has, and the reader hears a stale bed
/// rather than silence.
Map<String, int> allocate(
  Map<String, int> histogram, {
  int budget = defaultBudget,
  Map<String, int>? floor,
}) {
  final counts = {
    for (final entry in histogram.entries)
      if (entry.value > 0) entry.key: entry.value,
  };
  if (counts.isEmpty || budget <= 0) return const {};
  final floorCounts = {
    for (final entry in (floor ?? histogram).entries)
      if (entry.value > 0) entry.key: entry.value,
  };

  final total = counts.values.reduce((a, b) => a + b);
  final quota = <String, int>{};
  final remainder = <String, double>{};
  for (final entry in counts.entries) {
    final ideal = entry.value * budget / total;
    quota[entry.key] = ideal.floor();
    remainder[entry.key] = ideal - ideal.floorToDouble();
  }

  // The leftover seats, to the largest fractional parts. Ties break on the raw
  // count and then on the cue name, so the result is stable rather than
  // dependent on map order -- two runs over the same arc must plan the same
  // set or the files on disk stop matching the manifest.
  final spare = budget - quota.values.fold(0, (sum, n) => sum + n);
  final ranked = counts.keys.toList()
    ..sort((a, b) {
      final byRemainder = remainder[b]!.compareTo(remainder[a]!);
      if (byRemainder != 0) return byRemainder;
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  for (var i = 0; i < spare && i < ranked.length; i++) {
    quota[ranked[i]] = quota[ranked[i]]! + 1;
  }

  _floorPerMood(quota, counts, floorCounts);
  return {
    for (final entry in quota.entries)
      if (entry.value > 0) entry.key: entry.value,
  };
}

/// Give every mood that occurs at least one bed, at its most-observed band.
///
/// Paid for by the cue holding the most beds, which is the one that can lose
/// one and still have variants. A mood too rare to afford -- when the budget is
/// smaller than the number of moods present -- simply goes without, and the
/// rarest go first because moods are served in order of how much of the arc
/// they cover.
void _floorPerMood(
  Map<String, int> quota,
  Map<String, int> weights,
  Map<String, int> counts,
) {
  // Cues the floor knows about but the weights never saw. A mood that is tagged
  // and never sounds has no quota entry at all, so there would be nothing to
  // raise to 1.
  for (final cue in counts.keys) {
    quota.putIfAbsent(cue, () => 0);
  }

  // The band to put a mood's one bed on. Ties go to the lower band: a stiller
  // bed under a fiercer paragraph is the gentler failure, which is the rule
  // cueFor already keeps.
  String? pick(String mood, Map<String, int> from) {
    String? best;
    for (final entry in from.entries) {
      if (moodOf(entry.key) != mood || entry.value <= 0) continue;
      if (best == null ||
          entry.value > from[best]! ||
          (entry.value == from[best]! && entry.key.compareTo(best) < 0)) {
        best = entry.key;
      }
    }
    return best;
  }

  final perMood = <String, int>{};
  for (final entry in counts.entries) {
    final mood = moodOf(entry.key);
    perMood[mood] = (perMood[mood] ?? 0) + entry.value;
  }
  // Where the mood is *heard*, if it is heard at all, and only otherwise where
  // it is tagged. Measured on arc 0: melancholic sounds most at band 2 and is
  // tagged most at band 1, and its one bed belongs where the reader meets it.
  final best = {
    for (final mood in perMood.keys)
      mood: ?(pick(mood, weights) ?? pick(mood, counts)),
  };

  final moods = perMood.keys.toList()
    ..sort((a, b) {
      final byShare = perMood[b]!.compareTo(perMood[a]!);
      return byShare != 0 ? byShare : a.compareTo(b);
    });

  for (final mood in moods) {
    // Over everything allocated, not just what the floor histogram named: the
    // window averages intensity, so a band can *sound* that was never tagged.
    // Counting only the tagged cues would miss that and hand the mood a second
    // bed it already has.
    final held = quota.keys
        .where((cue) => moodOf(cue) == mood)
        .fold(0, (sum, cue) => sum + quota[cue]!);
    if (held > 0) continue;
    // The richest cue, by beds and then by name so the choice is stable.
    String? donor;
    for (final cue in quota.keys) {
      if (quota[cue]! < 2) continue;
      if (donor == null ||
          quota[cue]! > quota[donor]! ||
          (quota[cue]! == quota[donor]! && cue.compareTo(donor) < 0)) {
        donor = cue;
      }
    }
    final cue = best[mood];
    if (cue == null) continue; // Nothing to put a bed on.
    if (donor == null) return; // Nothing left to give; the budget is spent.
    quota[donor] = quota[donor]! - 1;
    quota[cue] = (quota[cue] ?? 0) + 1;
  }
}

/// The file name for one variant of a cue.
///
/// Variant 0 keeps the plain name, so a set generated before variants existed
/// reads as one variant of each cue and nothing on disk has to be renamed.
String variantFile(String cue, int variant) =>
    variant == 0 ? '$cue.wav' : '$cue-v$variant.wav';
