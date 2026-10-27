/// Scores chapters for arc boundaries while the book is being read.
///
/// A deliberately impolite thing done politely. Segmenting 2,364 chapters is
/// hours of model time, and the same model is scoring the paragraphs the
/// reader is hearing music for right now -- so this yields to that, always,
/// and fills the gaps. Classification runs at roughly a quarter duty cycle
/// against reading speed (§9.8), and this is what the other three quarters are
/// for.
///
/// It also never tries to scan the whole book. A boundary can only land within
/// [maxArcChapters] of the arc that is being read, so [scanTargetFor] is as far
/// ahead as it ever needs to be -- about a hundred chapters, five calls,
/// perhaps a minute. The rest of the book is scored as the reader reaches it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'arcs.dart';
import 'library.dart';
import 'ollama_client.dart';

enum ArcScanStatus { idle, scanning, done, unavailable }

class ArcScanner extends ChangeNotifier {
  ArcScanner({
    required this.library,
    required this.client,
    required this.isBusy,
    this.pollInterval = const Duration(seconds: 2),
  });

  final Library library;
  final OllamaClient client;

  /// Whether the paragraph classifier is working. While it is, this waits:
  /// the reader can hear the classifier and cannot hear this.
  final bool Function() isBusy;

  /// How often to re-check when yielding. Long enough not to spin, short
  /// enough to use the gaps between batches.
  final Duration pollInterval;

  String? _bookId;
  String? _theme;
  int _chapterCount = 0;
  int _scanned = 0;
  int _chapter = 0;
  var _status = ArcScanStatus.idle;
  String? _note;
  Future<void>? _running;
  var _stopped = false;

  ArcScanStatus get status => _status;
  String? get note => _note;

  /// Chapters scored so far, contiguously from the start.
  int get scanned => _scanned;
  int get chapterCount => _chapterCount;

  /// The cut as it currently stands. Cheap: arithmetic over cached scores.
  List<Arc> arcs = const [];

  /// Completes when no scan work is outstanding. For tests and shutdown.
  Future<void> get settled async {
    while (_running != null) {
      await _running;
    }
  }

  Future<void> setBook(String bookId, int chapterCount, String theme) async {
    _bookId = bookId;
    _chapterCount = chapterCount;
    _theme = theme;
    _stopped = false;
    _scanned = await library.scannedThrough(bookId);
    await _recut();
    _pump();
  }

  /// Follow the reader. Only the chapter matters: arcs are chapter-sized.
  void onChapter(int chapter) {
    if (chapter == _chapter) return;
    _chapter = chapter;
    _pump();
  }

  void stop() {
    _stopped = true;
  }

  Future<void> _recut() async {
    final bookId = _bookId;
    if (bookId == null) return;
    arcs = chooseArcs(await library.chapterBreaks(bookId), _chapterCount);
    notifyListeners();
  }

  void _pump() {
    if (_running != null || _stopped) return;
    _running = _run().whenComplete(() => _running = null);
  }

  Future<void> _run() async {
    final bookId = _bookId;
    final theme = _theme;
    if (bookId == null || theme == null) return;

    while (!_stopped) {
      final target = scanTargetFor(_chapter, _chapterCount);
      if (_scanned >= target) {
        _set(_scanned >= _chapterCount
            ? ArcScanStatus.done
            : ArcScanStatus.idle);
        return;
      }

      // Paragraph scoring wins, every time.
      if (isBusy()) {
        _set(ArcScanStatus.idle);
        await Future<void>.delayed(pollInterval);
        continue;
      }

      _set(ArcScanStatus.scanning);
      final to = (_scanned + arcScanBatch).clamp(0, target);
      final rows = await library.chapterRange(bookId, _scanned, to);
      if (rows.isEmpty) {
        _set(ArcScanStatus.done);
        return;
      }

      final Map<int, ChapterBreak> scored;
      try {
        scored = await client.chapterBreaks(
          [
            for (final (index, title, body) in rows)
              (index, chapterDigest(title, body)),
          ],
          theme,
        );
      } on OllamaUnavailable catch (error) {
        // Not fatal and not retried in a tight loop: the book stays readable,
        // the arcs stay as they were, and the next chapter turn tries again.
        _set(ArcScanStatus.unavailable, note: error.message);
        return;
      }

      // Every chapter in the batch gets a row, including ones the model did
      // not echo. Otherwise the contiguous scan front stalls on the hole and
      // this batch is retried forever. No score means 0, which is exactly
      // "no reason to cut here".
      await library.putChapterBreaks(bookId, [
        for (final (index, title, body) in rows)
          () {
            final hard = isDivisionHeading(title, body);
            final got = scored[index];
            return ChapterBreak(
              index: index,
              score: hard ? 1 : (got?.score ?? 0),
              situation: got?.situation ?? '',
              hard: hard,
            );
          }(),
      ]);
      _scanned = to;
      await _recut();
    }
  }

  void _set(ArcScanStatus status, {String? note}) {
    if (_status == status && _note == note) return;
    _status = status;
    _note = note;
    notifyListeners();
  }
}
