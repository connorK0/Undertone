/// Which arcs are alike enough to share one set of beds.
///
/// A long serial does not have thirty *different* moods. It returns to the
/// same places and the same kinds of scene, so arc 5 and arc 17 can come back
/// from the theme pass saying nearly the same thing -- and generating 32 beds
/// twice for two descriptions that differ by a word is 1.8 hours of GPU spent
/// on audio nobody could tell apart.
///
/// What is compared is the theme triple, and that is deliberate rather than
/// convenient: `genre_seed`, `overall_theme` and `instrumentation` are exactly
/// the parts of the generator's prompt that vary between arcs. Everything else
/// in a prompt -- the mood's texture, its BPM range, the band language, the
/// closing constraint -- is fixed by the cue. So two arcs with the same triple
/// produce the same 32 prompts, and near-identical triples produce prompts
/// that differ by a word in a sentence the model is only loosely steered by.
///
/// Similarity is Jaccard over the word set. It is a blunt instrument and it is
/// the right one here: the alternative is an embedding model, which means
/// another model pulled and another thing to keep in step, to rank strings
/// that are eight words long and drawn from the same vocabulary.
library;

/// Words too common in these themes to carry any signal.
const _stopWords = {
  'a', 'an', 'and', 'the', 'of', 'for', 'with', 'to', 'in', 'on', 'or',
  'more', 'other', 'some', 'its', 'their',
};

/// The comparable word set of a theme triple.
Set<String> themeTokens(
  String genreSeed,
  String overallTheme,
  String instrumentation,
) {
  final words = '$genreSeed $overallTheme $instrumentation'
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2 && !_stopWords.contains(w));
  return words.toSet();
}

/// 0 for nothing in common, 1 for the same words.
double similarity(Set<String> a, Set<String> b) {
  // Two themeless arcs score 0, not 1. Jaccard is undefined on a pair of
  // empty sets and 1 is the usual convention, but the convention is wrong
  // here: it would merge two arcs on the absence of any evidence that they
  // are alike, which is the one mistake that costs something a reader hears.
  if (a.isEmpty || b.isEmpty) return 0;
  final shared = a.intersection(b).length;
  return shared / (a.length + b.length - shared);
}

/// How alike two themes must be to share a palette.
///
/// Not measured yet -- there is no set of arc themes to measure it against
/// until a book has been through the arc theme pass. Starting high on purpose:
/// merging two arcs that should have sounded different is a fault a reader
/// would hear, while failing to merge two that were alike only costs GPU time.
/// Raise it to merge less, lower it to merge more.
const defaultPaletteThreshold = 0.8;

/// Assign each arc the index of the arc whose beds it should use.
///
/// Greedy and first-match: each arc is compared against the arcs already
/// chosen as representatives, in order, and joins the first one it is close
/// enough to. That makes grouping **order-dependent and non-transitive** --
/// A may join B while C, which is close to B but not to A, starts its own
/// group. A clustering that handled that properly would be harder to predict
/// and harder to explain, and this runs over a few dozen eight-word strings.
///
/// Returns a list the same length as [themes]: entry i is the index of the arc
/// that generates the beds arc i will play. An arc that represents itself maps
/// to its own index, so `palette[i] == i` marks a set that has to be generated.
List<int> paletteFor(
  List<Set<String>> themes, {
  double threshold = defaultPaletteThreshold,
}) {
  final palette = <int>[];
  final representatives = <int>[];
  for (var i = 0; i < themes.length; i++) {
    var chosen = i;
    for (final rep in representatives) {
      if (similarity(themes[i], themes[rep]) >= threshold) {
        chosen = rep;
        break;
      }
    }
    if (chosen == i) representatives.add(i);
    palette.add(chosen);
  }
  return palette;
}
