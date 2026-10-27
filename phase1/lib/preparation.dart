import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'book.dart';
import 'mood_pipeline.dart';
import 'music_engine.dart';

/// How far a book gets before it can be opened.
enum PrepareStage {
  /// Reading the book's theme -- one call, and every paragraph prompt quotes it.
  theme,

  /// Classifying the opening paragraphs.
  opening,

  /// Enough is tagged and the first loop is loaded: open it.
  ready,

  /// Ollama could not be reached. The book still opens; it just opens silent.
  failed,
}

/// Gets a book ready to be *opened*, rather than letting the reader open it and
/// then wait.
///
/// A cold classification is about 15s for the theme and another 8-9s for the
/// first batch. Spending that while someone stares at page one is the worst
/// place for it. Spending it here means the music has something to play the
/// moment the first page appears, which is the whole point of the phase.
///
/// Eventually this is where an uploaded .epub is parsed too. Today it runs
/// against the bundled chapters and does the classifier half only.
class BookPreparation extends ChangeNotifier {
  BookPreparation({required this.pipeline, required this.engine});

  final MoodPipeline pipeline;
  final MusicEngine engine;

  /// One batch. Enough that the reader is unlikely to outrun it on the first
  /// page, and the prefetch window keeps up from there.
  static const openingParagraphs = MoodPipeline.batchSize;

  PrepareStage _stage = PrepareStage.theme;
  int _tagged = 0;
  int _target = openingParagraphs;
  String? _note;

  PrepareStage get stage => _stage;
  int get tagged => _tagged;
  int get target => _target;

  /// Why preparation failed, when it did.
  String? get note => _note;

  double get progress {
    if (_stage == PrepareStage.ready) return 1;
    // The theme pass is most of a cold start, so it is worth a visible share
    // of the bar rather than sitting at zero for fifteen seconds.
    const themeShare = 0.35;
    if (pipeline.theme == null) return 0;
    return themeShare + (1 - themeShare) * (_target == 0 ? 1 : _tagged / _target);
  }

  /// Which run is current. Choosing a second book before the first has
  /// finished preparing leaves a stale run waiting on a pipeline that has since
  /// moved to a different book -- it must not go on reporting progress, or
  /// decide the newer book is ready.
  int _generation = 0;

  Future<void> run(Book book) async {
    final generation = ++_generation;
    _stage = PrepareStage.theme;
    _tagged = 0;
    _note = null;
    _target = min(openingParagraphs, book.paragraphs.length);
    notifyListeners();

    await engine.close();
    await pipeline.setBook(book);

    final done = Completer<void>();
    void check() {
      if (done.isCompleted) return;
      if (generation != _generation) {
        // A different book is being prepared now. The tags this is watching
        // belong to that one, so stop rather than report on the wrong book.
        done.complete();
        return;
      }
      if (pipeline.status == PipelineStatus.unavailable) {
        // Never trap the reader behind a spinner because a local model is
        // down. Give up on the music and let them read.
        _stage = PrepareStage.failed;
        _note = pipeline.note;
        notifyListeners();
        done.complete();
        return;
      }
      if (pipeline.theme == null) return;
      var tagged = 0;
      for (var i = 0; i < _target; i++) {
        if (pipeline.tagAt(i) != null) tagged++;
      }
      if (tagged != _tagged || _stage == PrepareStage.theme) {
        _tagged = tagged;
        _stage = PrepareStage.opening;
        notifyListeners();
      }
      if (tagged >= _target) {
        done.complete();
        return;
      }
      // The pipeline has stopped and the target is still not met, which means
      // the model declined to answer for a paragraph in the opening and
      // waiting will not change that. Open the chapter with what there is --
      // the same choice already made when the classifier is unreachable.
      if (!pipeline.busy) done.complete();
    }

    pipeline.addListener(check);
    check();
    await done.future;
    pipeline.removeListener(check);
    if (generation != _generation) return;

    if (_stage != PrepareStage.failed) {
      // Decode the first bed now, so opening the book is a fade-in and not a
      // fade-in that waits on a file read.
      final first = pipeline.tagAt(0);
      if (first != null) {
        await engine.preload(engine.cueKeyFor(
          mood: first.mood,
          intensity: first.intensity,
        ));
      }
      _stage = PrepareStage.ready;
    }
    debugPrint('[prepare] ${book.key}: ${_stage.name}'
        '${_note == null ? '' : ' ($_note)'}');
    notifyListeners();
  }
}
