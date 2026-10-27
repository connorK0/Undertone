import 'package:flutter/foundation.dart';

import 'book.dart';
import 'cue_selector.dart';
import 'mood_cache.dart';
import 'ollama_client.dart';

enum PipelineStatus {
  /// Nothing to do: the window ahead of the reader is fully tagged.
  idle,

  /// The one-per-book theme call is out.
  theme,

  /// A batch of paragraphs is out.
  classifying,

  /// The window ahead of the reader is covered, so the *next chapter's*
  /// opening is being tagged. Work that only ever happens on spare time.
  warming,

  /// Ollama isn't answering. Reading continues; the next trigger retries.
  unavailable,
}

/// Keeps the paragraphs around the reader tagged, without ever making them
/// wait for it.
///
/// Work is driven entirely by position: every mood trigger says where the
/// reader is, and the pipeline tops up a window ahead of them. Calls run one
/// at a time -- a second concurrent request to a local 7B model on one GPU
/// makes both slower, not the pair faster -- and each time one finishes the
/// next batch is chosen from wherever the reader has got to by then, so
/// skipping ahead re-prioritises instead of finishing stale work first.
class MoodPipeline extends ChangeNotifier {
  MoodPipeline({required this.client, required this.cache});

  /// Paragraphs to keep tagged ahead of the reader.
  ///
  /// Derived rather than chosen, because two separate things read ahead into
  /// it and a number that merely *looks* big enough silently stopped being so.
  /// [cueWindow] decides the current cue; [leadWindow] sits beyond that and
  /// decides what to prepare for (§8.9). Together they reach `position + 8`,
  /// which is exactly what this used to be -- so the lead window landed on the
  /// last paragraph the pipeline promised, and the moment classification was
  /// even slightly behind the reader there was nothing there. Leading in
  /// never once fired.
  ///
  /// The slack is what makes it work while the classifier is catching up,
  /// which is most of the time on a book whose arc has not been pre-classified.
  static const leadSlack = 4;
  static const lookahead = cueWindow + leadWindow + leadSlack;

  /// Paragraphs per call. Matches phase0's default: enough context for the
  /// model to hear a scene building, short enough to come back quickly.
  static const batchSize = 6;

  /// Paragraphs of the *next* chapter to tag before the reader gets there.
  ///
  /// Turning a page inside a chapter is free, because the window ahead of the
  /// reader is already tagged -- but turning to the next chapter used to mean
  /// waiting for a cold theme-and-classify pass, because the pipeline could
  /// not see past the chapter it was pointed at. It can now: once the current
  /// window is covered, the spare time goes on the next chapter's opening,
  /// straight into the cache that [setBook] reads.
  ///
  /// Sized to cover what BookPreparation waits for, plus enough of a lead that
  /// the first page's window is covered too.
  static const warmAhead = 16;

  final OllamaClient client;
  final MoodCache cache;

  Book? _book;

  /// The chapter after this one, if the reader has one to go to.
  Book? _next;
  Set<int> _nextDone = {};

  /// The next chapter's opening tags, kept rather than only written to the
  /// cache. [tagAcross] serves them, so the score can prepare for a change
  /// that lands on the other side of a chapter turn.
  Map<int, MoodTag> _nextTags = {};

  BookTheme? _theme;
  final _tags = <int, MoodTag>{};
  final _fromCache = <int>{};
  final _inFlight = <int>{};

  /// Paragraphs the model was asked about and did not answer.
  ///
  /// Structured output constrains the *shape* of the reply, not that every
  /// index asked for comes back in it. Without this, one omitted index is an
  /// infinite loop: it is not in [_tags], so [_nextBatch] picks it again, for
  /// ever -- 'classifying 2-5' over and over while the reader waits. One
  /// attempt per paragraph, then let it go. An untagged paragraph is not a
  /// failure the reader sees; the music simply holds the cue it is on.
  final _unanswered = <int>{};

  int _position = 0;

  /// The running pump loop, if any. Also what [settled] waits on.
  Future<void>? _pumping;
  PipelineStatus _status = PipelineStatus.idle;
  String? _note;

  BookTheme? get theme => _theme;
  PipelineStatus get status => _status;

  /// Why tagging is unavailable, when it is.
  String? get note => _note;

  int get position => _position;

  /// Whether a call is out right now. The arc scanner asks, so that it can
  /// keep off the model while the reader's own paragraphs are being scored.
  bool get busy => _pumping != null;

  /// Completes when no classification work is outstanding. The UI never waits
  /// on this -- reading is not gated on the pipeline -- but tests and shutdown
  /// need a way to know the work has stopped.
  Future<void> get settled async {
    while (_pumping != null) {
      await _pumping;
    }
  }

  MoodTag? get currentTag => _tags[_position];

  /// The tag for any paragraph, or null if it has not been classified. How
  /// preparation knows the opening of the book is ready to be read over.
  MoodTag? tagAt(int index) => _tags[index];

  /// A tag at [index], continuing into the *next* chapter past the end of
  /// this one.
  ///
  /// Reading is continuous; chapters are containers. The scoring window stops
  /// at the chapter end on purpose -- the cue belongs to the page under the
  /// reader's eye. But *preparing* for a change has to see over the boundary,
  /// or a chapter turn is the one change in the book that nothing can lead
  /// into: the paragraphs that would have warned about it are in a chapter
  /// [tagAt] cannot reach. Which made every chapter turn a cut.
  ///
  /// Only as far as the warm-up has got ([warmAhead] paragraphs), and null
  /// before it has got anywhere -- so this degrades to the old behaviour
  /// rather than to a wrong answer.
  MoodTag? tagAcross(int index) {
    final own = _tags[index];
    if (own != null) return own;
    final book = _book;
    if (book == null || index < book.paragraphs.length) return null;
    return _nextTags[index - book.paragraphs.length];
  }
  bool get currentPending => _inFlight.contains(_position);
  int get tagCount => _tags.length;

  /// The book being tagged, for anything that needs its length or its prose.
  Book? get book => _book;

  /// Paragraphs a call is out for right now, in order.
  List<int> get inFlight => _inFlight.toList()..sort();

  /// Whether a paragraph's tag came off disk rather than from the model.
  bool isFromCache(int index) => _fromCache.contains(index);

  /// Whether the tag on screen was read from disk or just classified.
  String? get currentSource {
    if (!_tags.containsKey(_position)) return null;
    return _fromCache.contains(_position) ? 'cache' : 'fresh';
  }

  /// Point the pipeline at a book, loading whatever is already cached for it.
  Future<void> setBook(Book book) async {
    _book = book;
    _next = null;
    _nextDone = {};
    _theme = null;
    _tags.clear();
    _fromCache.clear();
    _inFlight.clear();
    _unanswered.clear();
    _position = 0;
    _status = PipelineStatus.idle;
    _note = null;

    _theme = await cache.theme(book.themeKey);
    final cached = await cache.tags(book.key);
    _tags.addAll(cached);
    _fromCache.addAll(cached.keys);
    debugPrint(
      '[pipeline] ${book.key}: ${cached.length}/${book.paragraphs.length} tags cached'
      '${_theme == null ? ', no theme yet' : ', theme "${_theme!.overallTheme}"'}',
    );
    notifyListeners();
    _pump();
  }

  /// Point the pipeline at the chapter *after* the current one, so its
  /// opening can be tagged on spare time.
  ///
  /// Takes a Book rather than an index because the pipeline has no library:
  /// it is given prose and a cache, which is what makes it testable without
  /// either. Pass null on the last chapter.
  Future<void> prepareNext(Book? next) async {
    if (next == null) {
      _next = null;
      _nextDone = {};
      _nextTags = {};
      return;
    }
    if (next.key == _next?.key) return;
    _next = next;
    _nextTags = await cache.tags(next.key);
    _nextDone = _nextTags.keys.toSet();
    _pump();
  }

  /// Tag a batch of the next chapter's opening. True if it did any work.
  ///
  /// Only ever called when [_nextBatch] is empty, so the reader's own window
  /// always wins -- this is what the chapter turn spends its waiting on, not
  /// something that competes for it.
  Future<bool> _warmNext() async {
    final next = _next;
    final theme = _theme;
    if (next == null || theme == null) return false;

    final limit = next.paragraphs.length < warmAhead
        ? next.paragraphs.length
        : warmAhead;
    final missing = <int>[];
    for (var i = 0; i < limit && missing.length < batchSize; i++) {
      if (!_nextDone.contains(i)) missing.add(i);
    }
    if (missing.isEmpty) return false;

    _setStatus(PipelineStatus.warming);
    final tagged = await client.paragraphs(
      [for (final i in missing) (i, next.paragraphs[i])],
      theme.overallTheme,
    );
    await cache.putTags(next.key, tagged);
    _nextTags.addAll(tagged);
    // Everything asked for is marked done, not merely what came back. An index
    // the model failed to echo would otherwise be chosen again on the next
    // pass, for ever -- the same trap the arc scanner has.
    _nextDone.addAll(missing);
    debugPrint('[pipeline] warmed next chapter ${missing.first}-'
        '${missing.last} (${_nextDone.length}/$limit)');
    return true;
  }

  /// The reader moved. Called from every mood trigger.
  void onPosition(int paragraphIndex) {
    _position = paragraphIndex;
    notifyListeners();
    _pump();
  }

  /// Indices in the window that nothing has yet claimed, nearest first.
  List<int> _nextBatch() {
    final book = _book;
    if (book == null) return const [];
    final end = (_position + lookahead).clamp(0, book.paragraphs.length - 1);
    final missing = <int>[];
    for (var i = _position; i <= end && missing.length < batchSize; i++) {
      if (!_tags.containsKey(i) &&
          !_inFlight.contains(i) &&
          !_unanswered.contains(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  void _setStatus(PipelineStatus status, {String? note}) {
    _status = status;
    _note = note;
    notifyListeners();
  }

  void _pump() {
    if (_pumping != null) return;
    // Notify on the way out as well. The last thing _run does is set the
    // status, which happens while _pumping is still set -- so without this
    // there is no notification on which [busy] is finally false, and anything
    // waiting for the pipeline to run out of work waits for ever.
    _pumping = _run().whenComplete(() {
      _pumping = null;
      notifyListeners();
    });
  }

  Future<void> _run() async {
    try {
      while (true) {
        final book = _book;
        if (book == null) break;

        if (_theme == null) {
          _setStatus(PipelineStatus.theme);
          debugPrint('[pipeline] theme pass for ${book.key}...');
          final started = DateTime.now();
          final theme = await client.theme(book);
          _theme = theme;
          await cache.putTheme(book.themeKey, theme);
          debugPrint(
            '[pipeline] theme "${theme.overallTheme}" / ${theme.genreSeed} '
            'in ${_secondsSince(started)}s',
          );
          notifyListeners();
          continue;
        }

        // Chosen fresh each pass, so moving during a call re-prioritises.
        final batch = _nextBatch();
        if (batch.isEmpty) {
          // Nothing left for this chapter: spend the time on the next one.
          if (await _warmNext()) continue;
          break;
        }

        _inFlight.addAll(batch);
        _setStatus(PipelineStatus.classifying);
        debugPrint(
          '[pipeline] classifying ${batch.first}-${batch.last} '
          '(${batch.length} paragraphs)...',
        );
        final started = DateTime.now();
        try {
          final tagged = await client.paragraphs(
            [for (final i in batch) (i, book.paragraphs[i])],
            _theme!.overallTheme,
          );
          _tags.addAll(tagged);
          for (final i in batch) {
            if (!tagged.containsKey(i)) _unanswered.add(i);
          }
          await cache.putTags(book.key, tagged);
          debugPrint(
            '[pipeline] tagged ${batch.first}-${batch.last} in '
            '${_secondsSince(started)}s: '
            '${batch.map((i) => tagged[i]?.mood ?? '?').join(', ')}',
          );
        } finally {
          _inFlight.removeAll(batch);
        }
        notifyListeners();
      }
      _setStatus(PipelineStatus.idle);
    } on OllamaUnavailable catch (error) {
      _inFlight.clear();
      debugPrint('[pipeline] unavailable: ${error.message}');
      _setStatus(PipelineStatus.unavailable, note: error.message);
    }
  }

  String _secondsSince(DateTime started) =>
      (DateTime.now().difference(started).inMilliseconds / 1000)
          .toStringAsFixed(1);
}
