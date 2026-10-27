import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'book.dart';
import 'ollama_client.dart';

/// Proofreading: clear mistakes in the book's own text, fixed for display.
///
/// Serial fiction is written fast, often in the author's second language, and
/// some sentences come out saying something other than what they plainly mean
/// ("the founders were used to invest a lot"). The model proposes fixes; four
/// rules decide what the reader actually sees.
///
/// **The text the pipeline tags is never touched.** A chapter's cache key is a
/// hash of its text ([Book.key]), so a corrected copy would miss every mood tag
/// already cached for it. Corrections are a display layer: the reader shows the
/// corrected copy, the pipeline reads the original, and paragraph numbers agree
/// because no correction adds or removes a paragraph.
///
/// **The model proposes; code decides.** A 7B model will sometimes "fix" what
/// was meant, invent a quotation, or rewrite a sentence it was asked to touch.
/// [rejectionOf] turns a proposal down unless it is small, found exactly once
/// in the paragraph, keeps every name, and was not flagged as possibly
/// deliberate -- incorrect grammar can be the author's choice, and a
/// character's voice is not a mistake.
///
/// **Then the model looks again, at one fix at a time.** A proposal that
/// passes the rules is shown back to it alone: is the original clearly wrong,
/// and does the fix leave the meaning alone? The rules cannot see meaning --
/// "didn't hesitate" to "hesitated" is a one-word change -- and the second
/// look can (SUMMARY §9.41).
///
/// **What the model said is cached, not what was accepted**, so tightening a
/// rule applies to every chapter already checked without asking again.
class Correction {
  const Correction({
    required this.paragraph,
    required this.original,
    required this.corrected,
    required this.kind,
    required this.reason,
    this.deliberate = false,
    this.confirmed,
    this.verdict = '',
  });

  factory Correction.fromJson(Map<String, dynamic> json) => Correction(
        paragraph: (json['paragraph'] as num).toInt(),
        original: json['original'] as String? ?? '',
        corrected: json['corrected'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        deliberate: json['deliberate'] as bool? ?? false,
        confirmed: json['confirmed'] as bool?,
        verdict: json['verdict'] as String? ?? '',
      );

  /// Which paragraph of the chapter, by index.
  final int paragraph;

  /// The words as the book has them -- a few words around the mistake.
  final String original;

  /// The same words with only the mistake fixed.
  final String corrected;

  /// grammar, wrong_word or spelling.
  final String kind;

  /// The model's own few words on why.
  final String reason;

  /// The model thought a character or the author could have meant it.
  final bool deliberate;

  /// The second look's answer: true a real fix, false not, null never asked
  /// -- which is never applied.
  final bool? confirmed;

  /// The second look's own few words on why.
  final String verdict;

  Correction judged({required bool confirmed, required String verdict}) =>
      Correction(
        paragraph: paragraph,
        original: original,
        corrected: corrected,
        kind: kind,
        reason: reason,
        deliberate: deliberate,
        confirmed: confirmed,
        verdict: verdict,
      );

  Map<String, dynamic> toJson() => {
        'paragraph': paragraph,
        'original': original,
        'corrected': corrected,
        'kind': kind,
        'reason': reason,
        'deliberate': deliberate,
        if (confirmed != null) 'confirmed': confirmed,
        if (verdict.isNotEmpty) 'verdict': verdict,
      };
}

/// The most words one correction may change. The model is asked for the
/// smallest edit; anything larger is a rewrite, and a rewrite of someone
/// else's sentence is not proofreading.
const maxChangedWords = 4;

/// Why [c] must not be applied to [paragraph], or null if it may: the rules,
/// then the second look.
String? rejectionOf(Correction c, String paragraph) =>
    ruleRejection(c, paragraph) ??
    switch (c.confirmed) {
      true => null,
      false => 'not confirmed',
      null => 'never confirmed',
    };

/// What the rules alone make of [c]: everything but the second look, which is
/// only worth asking for a proposal that gets this far.
///
/// Words are compared without their punctuation, so a correction that only
/// moves a comma, straightens a quote, hyphenates or recases is turned down:
/// the model was told not to, the first trial found it doing little else
/// (SUMMARY §9.41), and punctuation is exactly where an author's style lives.
String? ruleRejection(Correction c, String paragraph) {
  if (c.deliberate) return 'possibly deliberate';
  if (c.original.isEmpty || c.original == c.corrected) return 'no change';
  final found = _count(paragraph, c.original);
  if (found == 0) return 'not in the text';
  if (found > 1) return 'appears $found times';
  final before = _bare(c.original);
  final after = _bare(c.corrected);
  if (before.join(' ').toLowerCase() == after.join(' ').toLowerCase()) {
    return 'punctuation only';
  }
  if (_changedWords(before, after) > maxChangedWords) {
    return 'too large a change';
  }
  final kept = {for (final word in after) _base(word)};
  if (!_names(c.original).every(kept.contains)) {
    return 'changes a capitalised word';
  }
  return null;
}

/// A chapter as the reader should see it.
class Proofread {
  const Proofread({
    required this.paragraphs,
    required this.marks,
    required this.proposals,
  });

  /// The original paragraphs, untouched: nothing was accepted.
  factory Proofread.none(List<String> paragraphs) => Proofread(
        paragraphs: paragraphs,
        marks: const {},
        proposals: const [],
      );

  /// Every paragraph, with the accepted corrections applied.
  final List<String> paragraphs;

  /// Where each accepted correction landed: paragraph -> ranges in that
  /// paragraph's *corrected* text, for marking.
  final Map<int, List<({int start, int end})>> marks;

  /// Everything the model proposed, and why each was turned down (null for
  /// the ones applied) -- for the inspector, where a wrong call is judged.
  final List<({Correction correction, String? rejected})> proposals;

  int get applied => proposals.where((p) => p.rejected == null).length;
}

/// Apply what passes [rejectionOf] to [paragraphs].
Proofread proofread(List<String> paragraphs, List<Correction> proposals) {
  final decided = <({Correction correction, String? rejected})>[];
  final byParagraph = <int, List<(int, Correction)>>{};
  for (final c in proposals) {
    if (c.paragraph < 0 || c.paragraph >= paragraphs.length) {
      decided.add((correction: c, rejected: 'no such paragraph'));
      continue;
    }
    final text = paragraphs[c.paragraph];
    var why = rejectionOf(c, text);
    final at = text.indexOf(c.original);
    if (why == null) {
      final taken = byParagraph[c.paragraph] ?? const [];
      final overlaps = taken.any((t) =>
          at < t.$1 + t.$2.original.length && t.$1 < at + c.original.length);
      if (overlaps) why = 'overlaps another fix';
    }
    decided.add((correction: c, rejected: why));
    if (why == null) (byParagraph[c.paragraph] ??= []).add((at, c));
  }

  final out = List<String>.of(paragraphs);
  final marks = <int, List<({int start, int end})>>{};
  for (final MapEntry(key: index, value: fixes) in byParagraph.entries) {
    fixes.sort((a, b) => a.$1.compareTo(b.$1));
    final text = paragraphs[index];
    final buffer = StringBuffer();
    final ranges = <({int start, int end})>[];
    var from = 0;
    for (final (at, c) in fixes) {
      buffer.write(text.substring(from, at));
      final start = buffer.length;
      buffer.write(c.corrected);
      ranges.add((start: start, end: buffer.length));
      from = at + c.original.length;
    }
    buffer.write(text.substring(from));
    out[index] = buffer.toString();
    marks[index] = ranges;
  }
  return Proofread(paragraphs: out, marks: marks, proposals: decided);
}

int _count(String text, String part) {
  var n = 0;
  for (var at = text.indexOf(part); at >= 0; at = text.indexOf(part, at + 1)) {
    n++;
  }
  return n;
}

/// The words of [text] without their punctuation. An apostrophe inside a word
/// stays, and a curly one reads as straight, so "didn’t" and "didn't" are the
/// same word.
List<String> _bare(String text) => [
      for (final match
          in RegExp(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)*").allMatches(text))
        match.group(0)!.replaceAll('’', "'"),
    ];

/// A word without its possessive, so "Cecil's" is still Cecil.
String _base(String word) => word.replaceFirst(RegExp(r"'s$"), '');

/// Words that start with a capital: the names a correction must not touch.
/// Catches a sentence's first word too, which costs the occasional fix there
/// and never costs a name.
Set<String> _names(String text) => {
      for (final word in _bare(text))
        if (RegExp('^[A-Z]').hasMatch(word)) _base(word),
    };

/// How many words differ once the common start and end are set aside.
int _changedWords(List<String> a, List<String> b) {
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head &&
      tail < b.length - head &&
      a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final changedA = a.length - head - tail;
  final changedB = b.length - head - tail;
  return changedA > changedB ? changedA : changedB;
}

/// What the model proposed for each chapter, on disk.
///
/// Its own database rather than a table in the mood cache: proofreading is
/// not mood, and this way the mood cache's schema is untouched. Keyed like the
/// mood cache -- by the chapter's [Book.key], so an edited chapter is checked
/// afresh -- and by model and prompt version, so a changed prompt is never
/// served the old one's answers.
class ProofCache {
  ProofCache._(this._db);

  final Database _db;

  static Future<ProofCache> at(String path) async {
    sqfliteFfiInit();
    return ProofCache._(await _openAt(path));
  }

  /// For tests: a database that never touches disk.
  static Future<ProofCache> inMemory() async {
    sqfliteFfiInit();
    return ProofCache._(await _openAt(inMemoryDatabasePath));
  }

  static Future<Database> _openAt(String path) =>
      databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) => db.execute('''
            CREATE TABLE proofs (
              book_key  TEXT NOT NULL,
              model     TEXT NOT NULL,
              prompt    INTEGER NOT NULL,
              proposals TEXT NOT NULL,
              PRIMARY KEY (book_key, model, prompt)
            )
          '''),
        ),
      );

  /// What the model proposed for [bookKey], or null if it was never asked.
  /// An empty list is an answer: the chapter was checked and needs nothing.
  Future<List<Correction>?> proposals(String bookKey) async {
    final rows = await _db.query(
      'proofs',
      where: 'book_key = ? AND model = ? AND prompt = ?',
      whereArgs: [bookKey, ollamaModel, proofreadPromptVersion],
    );
    if (rows.isEmpty) return null;
    return [
      for (final raw in jsonDecode(rows.first['proposals'] as String) as List)
        Correction.fromJson(raw as Map<String, dynamic>),
    ];
  }

  Future<void> put(String bookKey, List<Correction> proposals) =>
      _db.insert(
        'proofs',
        {
          'book_key': bookKey,
          'model': ollamaModel,
          'prompt': proofreadPromptVersion,
          'proposals': jsonEncode([for (final c in proposals) c.toJson()]),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> close() => _db.close();
}

/// Paragraphs per model call. At 12 the model found neither of the two known
/// mistakes in the test chapters; at 6 it found both (SUMMARY §9.41).
const proofreadBatch = 6;

/// Checks chapters, once each: the cache first, then the model.
class Proofreader {
  Proofreader(this.cache, this.client, {this.isBusy});

  final ProofCache cache;
  final OllamaClient client;

  /// True while the mood pipeline has a batch in flight. Proofreading waits
  /// for it before each batch of its own, the way the arc scanner does: the
  /// score comes first, and Ollama answers one call at a time.
  final bool Function()? isBusy;

  /// Chapters being checked right now, so the reader opening a chapter that
  /// is already being checked ahead waits for that rather than asking twice.
  final _inFlight = <String, Future<List<Correction>>>{};

  /// [chapter] as the reader should see it. Asks the model only for a
  /// chapter it has never seen.
  Future<Proofread> check(Book chapter) async {
    // A block body, not `=> _inFlight.remove(...)`: that returns the removed
    // future -- this one -- and whenComplete would wait on itself forever.
    final proposals = await (_inFlight[chapter.key] ??=
        _proposals(chapter).whenComplete(() {
      _inFlight.remove(chapter.key);
    }));
    return proofread(chapter.paragraphs, proposals);
  }

  /// [chapter] as the reader should see it if it has been checked, else null.
  /// Never asks the model, so opening a chapter is never slowed by it.
  Future<Proofread?> cached(Book chapter) async {
    final proposals = await cache.proposals(chapter.key);
    return proposals == null
        ? null
        : proofread(chapter.paragraphs, proposals);
  }

  Future<List<Correction>> _proposals(Book chapter) async {
    final cached = await cache.proposals(chapter.key);
    if (cached != null) return cached;
    final proposed = <Correction>[];
    final paragraphs = chapter.paragraphs;
    for (var at = 0; at < paragraphs.length; at += proofreadBatch) {
      await _yield();
      final end = (at + proofreadBatch).clamp(0, paragraphs.length);
      proposed.addAll(await client.proofread([
        for (var i = at; i < end; i++) (i, paragraphs[i]),
      ]));
    }
    // The second look, for what the rules let through -- most proposals are
    // turned down before it, and each look is a model call.
    final all = <Correction>[];
    for (final c in proposed) {
      final inRange = c.paragraph >= 0 && c.paragraph < paragraphs.length;
      if (!inRange || ruleRejection(c, paragraphs[c.paragraph]) != null) {
        all.add(c);
        continue;
      }
      await _yield();
      final verdict = await client.confirmFix(c, paragraphs[c.paragraph]);
      all.add(c.judged(confirmed: verdict.accept, verdict: verdict.why));
    }
    await cache.put(chapter.key, all);
    return all;
  }

  Future<void> _yield() async {
    while (isBusy?.call() ?? false) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
