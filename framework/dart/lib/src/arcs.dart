/// Where a book's storyline turns, and therefore where its music should.
///
/// Arcs used to be arithmetic: `chapter ~/ arcSize`, every arc the same length,
/// boundaries falling wherever the modulo landed. That is defensible for a
/// cost estimate and indefensible as a musical decision -- a score that changes
/// character at chapter 100 because 100 is a round number is changing for no
/// reason a reader could ever hear.
///
/// So boundaries are *found* rather than computed, in two passes:
///
///   1. **Explicit divisions**, free and certain. A book that says "Volume
///      Two" is telling you where an arc starts and should be believed.
///   2. **The model**, for everything else. It reads a digest of each chapter
///      and scores how much of a fresh start it is; [chooseArcs] then picks
///      boundaries from those scores subject to a length range.
///
/// Pass 1 finds **nothing at all** on the book this was built for: the test
/// book has 2,364 chapters titled "Chapter N", and not one line in it is a
/// division heading. That is the normal case for a web serial, so
/// pass 2 is the load-bearing one and pass 1 is the cheap win when a book
/// happens to be structured.
///
/// It does not follow that the book has no declared divisions -- only that
/// they are not *headings*. Chapter 1977 closes with an author's note saying
/// the thirteenth volume ends there, and pass 2 read it: chapter 1978 scored
/// 1.0, labelled "End of Volume 13", and the arc boundary landed on it
/// exactly. A heading regex could not have caught that without also matching
/// prose, which is the trade [isDivisionHeading] deliberately refuses.
///
/// The two are separated on purpose: scoring chapters is slow and is cached,
/// while choosing boundaries from scores is pure arithmetic over that cache.
/// Changing the length range re-cuts a book instantly, with no model calls.
library;

import 'dart:math' as math;

/// The range an arc's length is held to, in chapters.
///
/// A floor exists because an arc costs a fixed 32 beds and about 1.8 hours of
/// GPU whatever its length, so a 12-chapter arc is the same price as a
/// 90-chapter one for a twelfth of the reading. A ceiling exists because one
/// palette stretched over hundreds of chapters is the complaint that started
/// all of this. Between them the model chooses.
const minArcChapters = 50;
const maxArcChapters = 100;

/// How many chapters are described to the model in one call.
///
/// Smaller than it could be on context grounds. A digest is about 400
/// characters, so sixty would still fit in `num_ctx`; the limit is the model's
/// accuracy at echoing twenty-odd indices in one structured reply, which is
/// the same reason the paragraph classifier batches six.
const arcScanBatch = 20;

/// A heading that announces a division of the book.
///
/// Anchored at **both** ends, so a heading has to be the whole of its line
/// rather than merely start one. That is what keeps it off prose: this book
/// contains "the volume was", "a volume of", and a partial match would also
/// have fired on ordinary sentences like "Book I loved as a child" -- the
/// single-letter Roman numeral being the trap. A trailing subtitle is allowed
/// after a separator, because "Volume Two: The Long Winter" is still a
/// heading.
///
/// The cost of anchoring is a heading buried in a line with other text, which
/// is not a thing books do. The cost of not anchoring is a false division,
/// which outranks the model and moves a boundary to a chapter that is not one.
final _divisionHeading = RegExp(
  r'^\s*[\[(]?\s*(?:the\s+)?'
  r'(?:end\s+of\s+|start\s+of\s+|beginning\s+of\s+)?'
  r'(?:volume|book|part|arc|saga|season|act)\s+'
  r'(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|'
  r'eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|'
  r'nineteen|twenty)'
  r'\s*[)\]]?\s*(?:[:.\u2013\u2014-]\s*.{0,40})?$',
  caseSensitive: false,
);

/// Standalone division words, which carry no number.
final _divisionWord = RegExp(
  r'^\s*[\[(]?\s*(?:epilogue|prologue|interlude|intermission|finale)\b'
  r'\s*[)\]]?\s*(?:[:.\u2013\u2014-]?\s*.{0,40})?$',
  caseSensitive: false,
);

/// The longest a line can be and still be read as a heading rather than prose.
const _headingChars = 60;

/// Whether this chapter opens a division the author declared.
///
/// Checks the title and the first non-empty line of the body, because ePubs
/// disagree about which one a volume heading belongs to.
bool isDivisionHeading(String title, String body) {
  for (final line in [title, _firstLine(body)]) {
    if (line.isEmpty || line.length > _headingChars) continue;
    if (_divisionHeading.hasMatch(line) || _divisionWord.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

String _firstLine(String body) {
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

/// What the model is shown for one chapter.
///
/// The opening says where the story now is -- who is present, where, what they
/// are doing -- and the closing says where it is heading, which is what a
/// boundary actually looks like: one chapter finishing something and the next
/// starting something else. The middle is the part a segmenter needs least, so
/// it is the part left out.
String chapterDigest(
  String title,
  String body, {
  int head = 240,
  int tail = 120,
}) {
  final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= head + tail) return '$title | $flat';
  return '$title | ${flat.substring(0, head)}'
      ' [...] ${flat.substring(flat.length - tail)}';
}

/// One chapter's answer to "is this a fresh start?".
class ChapterBreak {
  const ChapterBreak({
    required this.index,
    required this.score,
    required this.situation,
    this.hard = false,
  });

  /// Chapter index in the book.
  final int index;

  /// 0 continues what came before, 1 begins a new storyline.
  final double score;

  /// A few words on what is going on, which becomes an arc's name when this
  /// chapter is chosen as a boundary.
  final String situation;

  /// Set by pass 1: the author declared a division here. Beats any score.
  final bool hard;
}

/// A stretch of chapters that shares one palette.
class Arc {
  const Arc({
    required this.index,
    required this.start,
    required this.end,
    required this.title,
    int? palette,
  }) : palette = palette ?? index;

  final int index;

  /// The arc whose beds this one plays.
  ///
  /// Usually itself. A long serial returns to the same kinds of scene, so two
  /// arcs can come back from the theme pass saying nearly the same thing, and
  /// generating 32 beds twice for that is GPU time spent on audio nobody could
  /// tell apart. See lib/theme_similarity.dart. `palette == index` marks a set
  /// that actually has to be generated.
  final int palette;

  /// First chapter, inclusive.
  final int start;

  /// Last chapter, inclusive.
  final int end;

  /// What this stretch is about, for the chapter list and the arc list.
  final String title;

  int get length => end - start + 1;

  bool contains(int chapter) => chapter >= start && chapter <= end;

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': start,
        'end': end,
        'title': title,
        'palette': palette,
      };

  /// A file written before palettes existed has no `palette`, and an arc that
  /// represents itself is the right reading of that.
  static Arc fromJson(Map<String, dynamic> json) => Arc(
        index: (json['index'] as num).toInt(),
        start: (json['start'] as num).toInt(),
        end: (json['end'] as num).toInt(),
        title: json['title'] as String? ?? '',
        palette: (json['palette'] as num?)?.toInt(),
      );

  @override
  String toString() => 'arc $index: $start-$end ($length ch) $title'
      '${palette == index ? '' : ' [plays arc $palette]'}';
}

/// Cut a book into arcs at the best-scoring chapters, within the length range.
///
/// Greedy and left-to-right, which is the right shape here even though it is
/// not globally optimal: arcs are generated in reading order and the reader
/// starts on arc 0 immediately, so a boundary must be decidable from what
/// comes before it. A dynamic-programming pass over the whole book would score
/// marginally better and could not be run until every chapter had been read.
///
/// The tail is never left as a stub. Once fewer than [max] chapters remain
/// they become the final arc, and a cut is refused if it would leave fewer
/// than [min] after it -- an arc costs the same 32 beds whether it holds 90
/// chapters or 9.
List<Arc> chooseArcs(
  List<ChapterBreak> breaks,
  int chapterCount, {
  int min = minArcChapters,
  int max = maxArcChapters,
}) {
  if (chapterCount <= 0) return const [];
  if (min < 1) min = 1;
  if (max < min) max = min;

  final score = List<double>.filled(chapterCount, 0);
  final hard = List<bool>.filled(chapterCount, false);
  final situation = List<String>.filled(chapterCount, '');
  for (final b in breaks) {
    // Chapter 0 is where arc 0 starts; it cannot also be a boundary.
    if (b.index <= 0 || b.index >= chapterCount) continue;
    score[b.index] = b.score;
    hard[b.index] = b.hard;
    situation[b.index] = b.situation;
  }

  final starts = <int>[0];
  while (chapterCount - starts.last > max) {
    final from = starts.last;
    final lo = from + min;
    // Never cut so late that the remainder is a stub.
    final hi = math.min(from + max, chapterCount - min) + 1;
    if (hi <= lo) break;

    var cut = -1;
    // An author-declared division inside the window wins outright, and the
    // earliest one wins, since a later one can still open the next arc.
    for (var i = lo; i < hi; i++) {
      if (hard[i]) {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      cut = lo;
      for (var i = lo; i < hi; i++) {
        if (score[i] > score[cut]) cut = i;
      }
    }
    starts.add(cut);
  }

  return [
    for (var i = 0; i < starts.length; i++)
      Arc(
        index: i,
        start: starts[i],
        end: i + 1 < starts.length ? starts[i + 1] - 1 : chapterCount - 1,
        title: situation[starts[i]].isEmpty
            ? 'Chapters ${starts[i] + 1}-'
                '${(i + 1 < starts.length ? starts[i + 1] : chapterCount)}'
            : situation[starts[i]],
      ),
  ];
}

/// Which arc a chapter falls in. Past the end, the last arc.
int arcIndexFor(List<Arc> arcs, int chapter) {
  for (final arc in arcs) {
    if (arc.contains(chapter)) return arc.index;
  }
  return arcs.isEmpty ? 0 : arcs.last.index;
}

/// How far the scan must reach to settle the arc containing [chapter].
///
/// A boundary can land anywhere up to [max] chapters past the arc's start, so
/// the scores for all of them have to exist before [chooseArcs] can be trusted
/// that far. This is what lets the scanner run just far enough ahead of the
/// reader rather than scoring 2,364 chapters before the first note plays.
int scanTargetFor(int chapter, int chapterCount, {int max = maxArcChapters}) =>
    math.min(chapter + max + 1, chapterCount);
