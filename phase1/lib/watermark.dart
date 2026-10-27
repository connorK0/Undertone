/// Finding the lines a book's *distributor* wrote, without ever touching the
/// lines its author wrote.
///
/// Downloaded ePubs often carry a stamp on every chapter -- "Read more at"
/// and a site name, a bare URL, an invitation to go and read somewhere else
/// instead. It is not marked as anything, so it reads as prose
/// to everything downstream: it gets a mood, it gets scored, and because a
/// short block folds forward into the paragraph after it (see [Book.fromText])
/// it also contaminates a real paragraph's text. So it is worth removing, and
/// removing it at import is what keeps it out of the folding.
///
/// The whole design is about precision, because the two mistakes are not the
/// same size. Leaving a watermark in is an annoyance. Deleting a sentence
/// Dickens wrote is data loss that the reader may not notice for a hundred
/// pages. So nothing here is removed on the strength of looking suspicious.
///
/// **Repetition is the proof.** A line that appears verbatim in chapter after
/// chapter is not prose -- authors do not repeat themselves that way, and the
/// ones who do (a refrain, a chapter epigraph) do not also carry a URL. Three
/// rules have to hold at once before a line is even *offered* for removal:
///
///   1. it is short -- a watermark is a one-liner, and the cap means a
///      mis-fire can never take a paragraph with it;
///   2. it repeats -- three times, or twice if it contains a web address;
///   3. it carries a signal -- a URL, or a phrase that is asking the reader to
///      go somewhere else.
///
/// And then a human confirms it, with the text and the count in front of them.
/// That last step is the actual guarantee; the rules above only make the list
/// short enough to read.
library;

/// One repeated line, with the evidence for calling it a watermark.
class Watermark {
  const Watermark({
    required this.canonical,
    required this.sample,
    required this.occurrences,
    required this.chapters,
    required this.reason,
    required this.inline,
  });

  /// The counting key: lower-cased, whitespace collapsed, digits masked. Digits
  /// are masked because these things are rarely identical -- "Read more at
  /// example.com/chapter-12" is the same stamp as "...chapter-13", and matching
  /// literally would find neither.
  final String canonical;

  /// One literal occurrence, to show the reader. Not the key: the key is
  /// unreadable by design.
  final String sample;

  /// How many times it appears across the whole book, and in how many chapters.
  /// Both are shown, because "40 times in 1 chapter" and "40 times in 40
  /// chapters" are different kinds of evidence.
  final int occurrences;
  final int chapters;

  /// Why it was flagged, in the reader's words rather than a regex.
  final String reason;

  /// True when it was found stuck on the end of a real paragraph rather than
  /// standing alone. Held to a stricter count, because removing it means
  /// cutting into a block that also contains prose.
  final bool inline;

  @override
  String toString() => '"$sample" x$occurrences in $chapters chapter(s)';
}

/// The longest line that may be called a watermark.
///
/// A real paragraph of prose runs 300-500 characters in the books this has been
/// measured on; the shortest genuine ones are still over 60, which is the
/// threshold at which the reader folds a block forward. 150 leaves room for a
/// wordy stamp while making it arithmetically impossible to delete a paragraph.
const maxWatermarkChars = 150;

/// A web address, which is the strongest signal there is: prose does not
/// usually carry one, and a distributor's stamp almost always does.
final _url = RegExp(
  r'(https?://|www\.)'
  r'|\b[a-z0-9][a-z0-9-]*\.(com|net|org|co|io|me|info|xyz|ru|cc|to|site|'
  r'online|club|top|fun|vip|live|link|app)\b',
  caseSensitive: false,
);

/// Phrases that ask the reader to go somewhere else.
///
/// Deliberately short, and deliberately only about *promotion*. Things a
/// translator or scanner writes about themselves are left alone: a credit line
/// is somebody's name, and this feature has no business deciding that a name is
/// not part of the book.
final _invitation = RegExp(
  r'\b('
  r'read (more|it|them|the (latest|rest|full))'
  r'|latest chapters?'
  r'|(for|find) (more|the fastest|new) (chapters?|novels?|books?|updates?)'
  r'|visit (us|our)'
  r'|download (this|more|the)'
  r'|free (web ?)?(novels?|books?|ebooks?)'
  r'|(follow|join) (us|our)'
  r'|support us on'
  r'|updated daily'
  r'|brought to you by'
  r'|this (book|novel|chapter) (is|was) (from|taken)'
  r')\b',
  caseSensitive: false,
);

/// Nothing but punctuation and spacing -- a scene break, most often `* * *`.
/// It repeats all through a book and it is content, so it is excluded before
/// any counting happens.
final _symbolsOnly = RegExp(r'^[\W_]+$', unicode: true);

/// Letters that live in Letterlike Symbols because the maths block leaves a
/// hole where they would have been -- script *e*, Planck's *h*, and the rest.
/// A stamp mixing styles picks these up without meaning to, and one of them
/// (`ℴ`, in `.cℴm`) is the whole reason a real book's stamp went unmatched.
const _letterlike = {
  0x2102: 'C', 0x210A: 'g', 0x210B: 'H', 0x210C: 'H', 0x210D: 'H',
  0x210E: 'h', 0x2110: 'I', 0x2111: 'I', 0x2112: 'L', 0x2113: 'l',
  0x2115: 'N', 0x2118: 'p', 0x2119: 'P', 0x211A: 'Q', 0x211B: 'R',
  0x211C: 'R', 0x211D: 'R', 0x2124: 'Z', 0x2128: 'Z', 0x212A: 'K',
  0x212B: 'A', 0x212C: 'B', 0x212D: 'C', 0x212F: 'e', 0x2130: 'E',
  0x2131: 'F', 0x2133: 'M', 0x2134: 'o',
};

/// Characters that take up no space and so can be sprinkled through a word
/// without a reader seeing anything. Dropped outright.
const _invisible = {0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF};

/// Fold styled, full-width and invisible characters back to plain ASCII.
///
/// Written because a real book did exactly this. *The Author's POV* stamps
/// `freewebnovel.com` on 187 of its 862 chapters, in **Mathematical
/// Alphanumeric Symbols** -- and every occurrence uses a different random mix
/// of the styles, so no two are the same string:
///
///     𝒇𝓻𝓮𝓮𝙬𝙚𝒃𝒏𝓸𝙫𝒆𝙡.𝓬𝓸𝒎
///     𝒻𝑟𝘦𝘦𝘸ℯ𝒷𝑛𝘰𝓋ℯ𝘭.𝘤𝘰𝘮
///     𝚏𝗿𝗲𝐞𝚠𝕖𝐛𝗻𝗼𝐯𝕖𝚕.𝚌𝗼𝗺
///
/// Literal matching finds one occurrence of each and flags none of them, which
/// is the point of writing it that way. What makes it tractable is that the
/// maths block is regular: thirteen styles of the Latin alphabet, each a run
/// of 26 capitals followed by 26 smalls, one style after another from U+1D400
/// to U+1D6A3. So the whole block folds with one modulo, and the styles need
/// not be enumerated at all.
///
/// Dart has no Unicode normalisation in its core library, and this is a
/// narrower job than NFKC anyway: it is only ever used to build a matching
/// key, and never to rewrite the book.
String foldConfusables(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (_invisible.contains(rune)) continue;

    if (rune >= 0x1D400 && rune <= 0x1D6A3) {
      // Thirteen Latin styles x (26 capitals + 26 smalls).
      final i = (rune - 0x1D400) % 52;
      out.writeCharCode(i < 26 ? 0x41 + i : 0x61 + i - 26);
    } else if (rune >= 0x1D7CE && rune <= 0x1D7FF) {
      // Five styles of the digits, ten each.
      out.writeCharCode(0x30 + (rune - 0x1D7CE) % 10);
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // Halfwidth and Fullwidth Forms sit a fixed distance above ASCII.
      out.writeCharCode(rune - 0xFEE0);
    } else {
      final letter = _letterlike[rune];
      if (letter != null) {
        out.write(letter);
      } else {
        out.writeCharCode(rune);
      }
    }
  }
  return out.toString();
}

/// The counting key. Style, case, spacing and digits are all things that vary
/// between two printings of the same stamp.
String canonicalise(String line) => foldConfusables(line)
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\d+'), '#')
    .trim();

/// The last sentence of [line], if removing it would still leave a paragraph
/// behind.
///
/// This is how an inline stamp is found -- the ones appended to the end of real
/// prose rather than given a paragraph of their own. Returns null unless there
/// is a substantial amount of text in front of it, because a "tail" that is
/// nearly the whole line is just the line, and is handled as one.
String? trailingSentence(String line) {
  final boundaries = RegExp(r'''[.!?…]["'’”)\]]*\s+''')
      .allMatches(line)
      .toList();
  if (boundaries.isEmpty) return null;
  final start = boundaries.last.end;
  if (start >= line.length) return null;
  // The prose left behind has to be a paragraph, not a fragment.
  if (start < 60) return null;
  final tail = line.substring(start).trim();
  return tail.isEmpty ? null : tail;
}

/// The last whitespace-delimited word of [line], if there is more than one.
///
/// The cheapest of the three units, and it earns its place: a stamp is often
/// stuck on the end of a line with no sentence boundary in front of it at all
/// -- "High pressure freewebnovel.com" -- which [trailingSentence] cannot see.
String? lastToken(String line) {
  final at = line.lastIndexOf(RegExp(r'\s'));
  if (at < 0 || at + 1 >= line.length) return null;
  return line.substring(at + 1);
}

class _Tally {
  int occurrences = 0;
  int standalone = 0;
  final chapters = <int>{};
  String? sample;
}

/// Everything in [chapters] that repeats, carries a signal, and is short enough
/// to be safe to offer. Highest count first, since that is the strongest
/// evidence and the reader should see it before anything marginal.
///
/// Nothing is removed here. This only builds the list to be confirmed.
List<Watermark> findWatermarks(List<String> chapters) {
  final tallies = <String, _Tally>{};

  void count(String line, int chapter, {required bool standalone}) {
    // A cheap first pass so a book's worth of paragraphs is not folded for
    // nothing. Generous, because folding *shortens*: a styled character is a
    // surrogate pair, two UTF-16 units, and comes back as one.
    if (line.length > 4 * maxWatermarkChars) return;
    final key = canonicalise(line);
    // Both of these are judged on the folded form, and the second has to be.
    // Dart's \w is ASCII-only, so every styled character is \W -- testing the
    // raw line would classify an entire watermark written in Mathematical
    // Alphanumeric Symbols as punctuation and throw it out. (Python's \w is
    // Unicode-aware, which is exactly why a prototype of this missed it.)
    if (key.isEmpty || key.length > maxWatermarkChars) return;
    if (_symbolsOnly.hasMatch(key)) return;
    final tally = tallies.putIfAbsent(key, _Tally.new);
    tally.occurrences++;
    if (standalone) tally.standalone++;
    tally.chapters.add(chapter);
    tally.sample ??= line;
  }

  for (var chapter = 0; chapter < chapters.length; chapter++) {
    for (final block in chapters[chapter].split('\n\n')) {
      final line = block.trim();
      if (line.isEmpty) continue;
      count(line, chapter, standalone: true);
      final tail = trailingSentence(line);
      if (tail != null) count(tail, chapter, standalone: false);
      final word = lastToken(line);
      if (word != null && word != tail) {
        count(word, chapter, standalone: false);
      }
    }
  }

  final found = <Watermark>[];
  tallies.forEach((key, tally) {
    final sample = tally.sample!;
    final hasUrl = _url.hasMatch(key);
    final hasInvitation = _invitation.hasMatch(key);
    if (!hasUrl && !hasInvitation) return;

    // Repetition is the proof, so this is the rule that does the work. A URL
    // buys one occurrence's worth of credit and no more: a single line that
    // happens to mention a website is a line the author may well have written.
    final inline = tally.standalone == 0;
    final needed = inline ? 3 : (hasUrl ? 2 : 3);
    if (tally.occurrences < needed) return;

    found.add(Watermark(
      canonical: key,
      sample: sample,
      occurrences: tally.occurrences,
      chapters: tally.chapters.length,
      inline: inline,
      reason: hasUrl ? 'repeats, and contains a web address'
          : 'repeats, and points the reader elsewhere',
    ));
  });

  // A line that is only some *other* candidate with prose stuck in front of it
  // is not its own watermark. Real books are full of these -- the stamp lands
  // wherever the paragraph happened to end, so "Bang-! <stamp>" and
  // "*** <stamp>" show up as candidates of their own. Offering them would
  // invite the reader to delete a block that contains the author's words.
  // Removing the shorter key handles all of them and keeps what came before.
  //
  // Which of the pair survives is decided by the counts, and the two cases
  // pull in opposite directions:
  //
  //   * the shorter appears *more often* -- it turns up on its own elsewhere,
  //     so it is the stamp and the longer is prose with the stamp on the end.
  //     Drop the longer; removing the shorter cleans those lines and keeps
  //     what came before.
  //   * they appear *equally often* -- the shorter is only ever the tail of
  //     the longer, so the longer is the whole stamp. Drop the shorter, or
  //     "read more at:" is left behind in the book.
  final subsumed = <String>{};
  for (final mark in found) {
    for (final other in found) {
      if (other.canonical == mark.canonical) continue;
      if (!mark.canonical.endsWith(other.canonical)) continue;
      if (other.occurrences > mark.occurrences) {
        subsumed.add(mark.canonical); // prose plus a stamp
      } else if (other.occurrences == mark.occurrences) {
        subsumed.add(other.canonical); // only ever part of the longer
      }
    }
  }

  final kept = [
    for (final mark in found)
      if (!subsumed.contains(mark.canonical)) mark,
  ];
  kept.sort((a, b) => b.occurrences.compareTo(a.occurrences));
  return kept;
}

/// [text] with every confirmed watermark taken out.
///
/// Exactly the lines whose canonical form is in [canonicals] -- nothing is
/// re-judged here, so what the reader confirmed is what happens. With an empty
/// set this returns [text] unchanged, character for character; there is a test
/// that says so, because a cleaner that quietly reformats a book it found
/// nothing in would be its own kind of data loss.
String removeWatermarks(String text, Set<String> canonicals) {
  if (canonicals.isEmpty) return text;
  // Longest first, so that where two confirmed keys both match the end of a
  // line the fuller one wins and no fragment of the stamp is left behind.
  final ordered = canonicals.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  final kept = <String>[];
  for (final block in text.split('\n\n')) {
    final line = block.trim();
    if (line.isEmpty) {
      kept.add(block);
      continue;
    }
    final canon = canonicalise(line);
    if (canonicals.contains(canon)) continue;

    // The stamp is usually stuck on the end of whatever paragraph it landed
    // in. Measured on a real book: of the blocks under 60 characters carrying
    // one, nearly all are a line of dialogue or a sound effect with the stamp
    // appended -- so dropping the block would delete the author's words. Only
    // the stamp comes off.
    var head = line;
    var cut = false;
    for (final key in ordered) {
      if (!canon.endsWith(key)) continue;
      final at = _suffixStart(line, key);
      if (at == null) continue;
      head = line.substring(0, at).trimRight();
      cut = true;
      break;
    }
    if (!cut) {
      kept.add(block);
    } else if (head.isNotEmpty) {
      // Whatever is left stays, even if it is only punctuation: an ellipsis or
      // a row of asterisks may well be the scene break the book was written
      // with, and the stamp merely landed on it.
      kept.add(head);
    }
  }
  return kept.join('\n\n');
}

/// Where in [line] the shortest suffix begins that canonicalises to [key].
///
/// Needed because [canonicalise] does not preserve length -- it drops
/// invisible characters, collapses runs of spaces, and folds surrogate pairs
/// to one ASCII byte each -- so the cut point cannot be found by subtracting
/// lengths. Scans rune boundaries from the end, and stops well before the
/// start of the line: a stamp is short, and four UTF-16 units per folded
/// character with room to spare is a generous ceiling.
int? _suffixStart(String line, String key) {
  final limit = 4 * key.length + 32;
  for (var i = line.length - 1; i >= 0 && line.length - i <= limit; i--) {
    // Never split a surrogate pair; a lone half folds to nothing useful.
    final unit = line.codeUnitAt(i);
    if (unit >= 0xDC00 && unit <= 0xDFFF) continue;
    if (canonicalise(line.substring(i)) == key) return i;
  }
  return null;
}

/// How many characters [canonicals] would take out of [chapters]. Shown before
/// anything is applied, as the last sanity check a person can make at a glance:
/// a watermark clean is tenths of a percent of a book.
int removalSize(List<String> chapters, Set<String> canonicals) {
  var removed = 0;
  for (final chapter in chapters) {
    removed += chapter.length - removeWatermarks(chapter, canonicals).length;
  }
  return removed;
}
