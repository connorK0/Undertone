import 'dart:async';

import 'package:flutter/material.dart';

import 'book.dart';
import 'chapter_list.dart';
import 'grammar.dart';
import 'inspector_panel.dart';
import 'library.dart';
import 'arc_scanner.dart';
import 'mood_pipeline.dart';
import 'mood_trigger.dart';
import 'music_engine.dart';
import 'music_library.dart';
import 'ollama_client.dart';
import 'page_reader.dart';
import 'preparation.dart';
import 'reading_style.dart';
import 'scroll_reader.dart';
import 'settings.dart';
import 'settings_dialog.dart';

/// One chapter, open and scored.
///
/// The chapter is prepared before it is shown -- theme plus the opening
/// paragraphs -- so the first page arrives with music already fading in rather
/// than fifteen seconds of silence. Moving to the next chapter prepares again,
/// which is fast because the theme is shared across the book and only the new
/// chapter's opening has to be classified.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.library,
    required this.entry,
    required this.pipeline,
    required this.engine,
    required this.settings,
    this.proofreader,
    this.startChapter = 0,
    this.startParagraph = 0,
  });

  final Library library;
  final LibraryEntry entry;
  final MoodPipeline pipeline;
  final MusicEngine engine;
  final Settings settings;

  /// Fixes clear grammar mistakes for display; null reads the text as stored.
  final Proofreader? proofreader;
  final int startChapter;
  final int startParagraph;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final BookPreparation _preparation =
      BookPreparation(pipeline: widget.pipeline, engine: widget.engine);

  /// Finds where this book's storyline turns, in the gaps between paragraph
  /// batches. Nothing on screen waits for it: it decides which arc's beds a
  /// *later* chapter will use, and until it has run the cut is evenly spaced.
  late final ArcScanner _scanner = ArcScanner(
    library: widget.library,
    client: widget.pipeline.client,
    isBusy: () => widget.pipeline.busy,
  );

  ReadingMode _mode = ReadingMode.pages;
  bool _inspecting = false;
  Book? _book;
  late int _chapter = widget.startChapter;

  /// Whether the open chapter was entered by turning back into it, so the
  /// page reader starts on its last page.
  bool _openAtEnd = false;
  bool _reading = false;

  /// The open chapter's proofreading, once there is any, and the chapter as
  /// it reads with the accepted fixes -- built once, since the page reader
  /// re-cuts its pages whenever it is handed a different text.
  Proofread? _proof;
  Book? _proofed;

  /// Identifies the current open. Preparing takes seconds, so moving chapters
  /// twice quickly leaves two in flight; without this the slower one opens a
  /// chapter that is not ready on top of the one that is.
  int _openId = 0;

  @override
  void initState() {
    super.initState();
    // A book is being opened, so the score starts back at its warm-up floor
    // and climbs as the reader settles in. Here rather than in the engine's
    // own open(), which runs once per *chapter*.
    widget.engine.restartWarmup();
    _open(_chapter);
    lastMoodTrigger.addListener(_rememberPosition);
  }

  @override
  void dispose() {
    lastMoodTrigger.removeListener(_rememberPosition);
    _scanner.stop();
    _scanner.dispose();
    widget.engine.close();
    super.dispose();
  }

  /// Reading position is saved on every trigger rather than on the way out,
  /// so closing the window -- or losing power -- still keeps your place.
  void _rememberPosition() {
    final position = lastMoodTrigger.value?.position;
    if (position == null || !_reading) return;
    widget.library
        .saveProgress(widget.entry.id, _chapter, position.paragraphIndex);
  }

  Future<void> _open(int chapterIndex, {bool atEnd = false}) async {
    final id = ++_openId;
    setState(() {
      _chapter = chapterIndex;
      _openAtEnd = atEnd;
      _reading = false;
      _book = null;
      _proof = null;
      _proofed = null;
    });

    final book = await widget.library.chapter(widget.entry.id, chapterIndex);
    if (!mounted || id != _openId || book == null) return;
    // A chapter checked before opens already corrected, rather than
    // changing under the reader a moment later. Never asks the model.
    final proof = widget.settings.proofread
        ? await widget.proofreader?.cached(book)
        : null;
    if (!mounted || id != _openId) return;
    setState(() {
      _book = book;
      _setProof(book, proof);
    });

    // Generated beds are per book, so the right set has to be loaded before
    // preparation preloads the opening cue -- otherwise the first page fades
    // in on the previous book's music. Falls back on its own if this book has
    // no generated set.
    if (widget.settings.loops == MusicLibrary.perBook) {
      // The chapter matters: a per-arc set changes at an arc boundary, and
      // this is the call that notices.
      await widget.engine.useLibrary(MusicLibrary.perBook,
          bookId: widget.entry.id, chapter: chapterIndex);
      if (!mounted || id != _openId) return;
    }

    if (!widget.settings.scoring) {
      // "Just reading": no theme pass, no classifying, nothing to wait for.
      // The engine is closed rather than merely silent, so a bed left running
      // from a previous book does not follow the reader into this one.
      await widget.engine.close();
      if (!mounted || id != _openId) return;
      setState(() => _reading = true);
      unawaited(_proofread(book, id));
      return;
    }

    await _preparation.run(book);
    if (!mounted || id != _openId) return;
    // Ready or not, the chapter opens; failed just opens it silent.
    setState(() => _reading = true);
    if (widget.settings.enabled) widget.engine.open();
    // After preparation, so the first page's music never waits on it.
    unawaited(_proofread(book, id));

    // Hand the pipeline the chapter after this one, so its opening is tagged
    // out of the spare time between batches rather than at the moment the
    // reader turns to it. Loaded after the current chapter is on screen, so it
    // costs the reader nothing; null at the end of the book, which
    // prepareNext expects.
    final next =
        await widget.library.chapter(widget.entry.id, chapterIndex + 1);
    if (!mounted || id != _openId) return;
    await widget.pipeline.prepareNext(next);

    // After the chapter is on screen, never before. The scan needs the book's
    // theme -- which the preparation pass has just settled -- and it must not
    // add a step to the wait before reading starts.
    final theme = widget.pipeline.theme;
    if (theme != null) {
      await _scanner.setBook(
        widget.entry.id,
        widget.entry.chapterCount,
        theme.overallTheme,
      );
      _scanner.onChapter(chapterIndex);
    }
  }

  void _setProof(Book book, Proofread? proof) {
    _proof = proof;
    _proofed = proof == null || proof.applied == 0
        ? null
        : Book(
            title: book.title,
            paragraphs: proof.paragraphs,
            source: book.source,
          );
  }

  /// Check the open chapter if it never was -- the page updates in place when
  /// the answer lands -- and then the next one, so turning to it finds it
  /// done. A model that is down leaves the text as written; nothing waits.
  Future<void> _proofread(Book book, int id) async {
    final reader = widget.proofreader;
    if (reader == null || !widget.settings.proofread) return;
    try {
      if (_proof == null) {
        final proof = await reader.check(book);
        if (!mounted || id != _openId) return;
        setState(() => _setProof(book, proof));
      }
      final next =
          await widget.library.chapter(widget.entry.id, _chapter + 1);
      if (next == null || !mounted || id != _openId) return;
      await reader.check(next);
    } on OllamaUnavailable catch (e) {
      debugPrint('[proofread] skipped: ${e.message}');
    }
  }

  double _progress(MoodTriggerEvent? trigger) => bookProgress(
        chapter: _chapter,
        chapterCount: widget.entry.chapterCount,
        position: trigger?.position,
        paragraphCount: _book?.paragraphs.length ?? 0,
      );

  Future<void> _pickChapter() async {
    final titles = await widget.library.chapterTitles(widget.entry.id);
    if (!mounted) return;
    final chosen = await showChapterList(
      context,
      title: widget.entry.title,
      chapters: titles,
      current: _chapter,
    );
    if (chosen != null && chosen != _chapter && mounted) _open(chosen);
  }

  /// The prose.
  ///
  /// The style is passed in rather than keyed on, deliberately: a key change
  /// would rebuild the reader from scratch and lose the character offset it
  /// holds your place with, so changing the font mid-chapter would send you
  /// back to page one. Passed as a parameter, PageReader re-cuts its pages and
  /// finds the page containing that same offset.
  Widget _reader(Book book) => ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) {
          // The page shows the corrected chapter; the pipeline was handed the
          // chapter as stored, and paragraph numbers are the same in both.
          final fixed = widget.settings.proofread ? _proofed : null;
          final shown = fixed ?? book;
          final ProofMarks marks =
              fixed == null ? const {} : _proof?.marks ?? const {};
          return KeyedSubtree(
            key: ValueKey('${widget.entry.id}/$_chapter/$_mode'),
            child: _mode == ReadingMode.pages
                ? PageReader(
                    book: shown,
                    marks: marks,
                    style: widget.settings.reading,
                    // Null on the last chapter, which is what disables it.
                    onNextChapter: _chapter + 1 < widget.entry.chapterCount
                        ? () => _open(_chapter + 1)
                        : null,
                    onPreviousChapter: _chapter > 0
                        ? () => _open(_chapter - 1, atEnd: true)
                        : null,
                    startAtEnd: _openAtEnd,
                  )
                : ScrollReader(
                    book: shown,
                    marks: marks,
                    style: widget.settings.reading,
                  ),
          );
        },
      );

  Widget _inspector(Book book) => InspectorPanel(
        pipeline: widget.pipeline,
        engine: widget.engine,
        title: book.title,
        chapter: _chapter,
        chapterCount: widget.entry.chapterCount,
        proof: _proof,
      );

  @override
  Widget build(BuildContext context) {
    final book = _book;
    final last = widget.entry.chapterCount - 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(book?.title ?? widget.entry.title),
        actions: [
          IconButton(
            tooltip: 'Previous chapter',
            icon: const Icon(Icons.chevron_left),
            onPressed: _chapter > 0 ? () => _open(_chapter - 1) : null,
          ),
          ValueListenableBuilder<MoodTriggerEvent?>(
            valueListenable: lastMoodTrigger,
            builder: (context, trigger, _) => TextButton(
              onPressed: _pickChapter,
              child: Text(
                '${_chapter + 1}/${last + 1}'
                '  ·  ${(100 * _progress(trigger)).toStringAsFixed(0)}%',
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next chapter',
            icon: const Icon(Icons.chevron_right),
            onPressed: _chapter < last ? () => _open(_chapter + 1) : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<ReadingMode>(
              segments: const [
                ButtonSegment(
                  value: ReadingMode.pages,
                  label: Text('Pages'),
                  icon: Icon(Icons.auto_stories),
                ),
                ButtonSegment(
                  value: ReadingMode.scroll,
                  label: Text('Scroll'),
                  icon: Icon(Icons.swap_vert),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) =>
                  setState(() => _mode = selection.first),
            ),
          ),
          IconButton(
            tooltip: 'Font, size and page',
            icon: const Icon(Icons.text_format),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(
                settings: widget.settings,
                engine: widget.engine,
              ),
            ),
          ),
          if (widget.settings.scoring)
            IconButton(
              tooltip: _inspecting
                  ? 'Hide what the score is doing'
                  : 'Show what the score is doing',
              isSelected: _inspecting,
              icon: const Icon(Icons.insights_outlined),
              selectedIcon: const Icon(Icons.insights),
              onPressed: () => setState(() => _inspecting = !_inspecting),
            ),
        ],
      ),
      body: book == null
          ? const Center(child: CircularProgressIndicator())
          : !_reading
              // Preparation is a cold theme pass and a first batch -- fifteen
              // seconds of the most interesting thing the pipeline ever does,
              // and the toggle would otherwise appear broken here.
              ? (_inspecting
                  ? _inspector(book)
                  : PrepareView(preparation: _preparation, book: book))
              : Column(
                  children: [
                    // With the inspector off this is exactly the tree that was
                    // here before it existed. That is not tidiness: wrapping
                    // the reader in a LayoutBuilder unconditionally made
                    // app_test's fling assertion fail about half the time
                    // (15 triggers where 14 were expected) while master passed
                    // 4 of 4. Deferring the child's build to layout is enough
                    // to shift when scroll notifications land, and the settle
                    // timer fires 400ms after the last one -- so a ballistic
                    // tail that goes quiet for four of pumpAndSettle's 100ms
                    // steps settles twice. The panel is meant to be free when
                    // it is closed, so it costs nothing when it is closed.
                    Expanded(
                      child: _inspecting
                          ? LayoutBuilder(
                              builder: (context, constraints) {
                                final inspector = _inspector(book);
                                // Beside the text where there is room, because
                                // the interesting moments are the transitions
                                // and those only happen while you are reading.
                                // Where there is not, it takes the whole width
                                // -- a cramped column of prose next to a
                                // cramped column of numbers is worse than
                                // either alone.
                                if (constraints.maxWidth < 900) return inspector;
                                return Row(
                                  children: [
                                    Expanded(child: _reader(book)),
                                    const VerticalDivider(width: 1),
                                    SizedBox(width: 380, child: inspector),
                                  ],
                                );
                              },
                            )
                          : _reader(book),
                    ),
                    if (widget.settings.scoring)
                      MoodBanner(
                        pipeline: widget.pipeline,
                        engine: widget.engine,
                      ),
                  ],
                ),
    );
  }
}

/// How far through the *book* the reader is, 0 to 1.
///
/// Chapters plus where they are inside the current one. Both halves are
/// needed: on a serial with hundreds of chapters the chapter number alone
/// barely moves, and on a twelve-chapter novel it moves in visible jumps. The
/// within-chapter part comes from the page count when paginated and from the
/// paragraph index when scrolling -- the two things the reader already
/// reports, so nothing new has to be measured.
///
/// Deliberately a plain function: it is the number on screen, and a number on
/// screen should be testable without building a reader.
double bookProgress({
  required int chapter,
  required int chapterCount,
  ReadingPosition? position,
  int paragraphCount = 0,
}) {
  if (chapterCount <= 0) return 0;
  var within = 0.0;
  if (position != null) {
    final pages = position.pageCount;
    if (pages != null && pages > 0 && position.page != null) {
      // Page 1 of 34 is the *start* of the chapter, not 1/34 of the way in.
      within = (position.page! - 1) / pages;
    } else if (paragraphCount > 0) {
      within = position.paragraphIndex / paragraphCount;
    }
  }
  return ((chapter + within.clamp(0.0, 1.0)) / chapterCount).clamp(0.0, 1.0);
}

/// Shown instead of the reader while a chapter is being got ready.
class PrepareView extends StatelessWidget {
  const PrepareView({super.key, required this.preparation, required this.book});

  final BookPreparation preparation;
  final Book book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: preparation,
      builder: (context, _) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.title,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  switch (preparation.stage) {
                    PrepareStage.theme => 'Reading the book to find its voice...',
                    PrepareStage.opening =>
                      'Scoring the opening — ${preparation.tagged} of '
                          '${preparation.target} paragraphs',
                    PrepareStage.ready => 'Ready',
                    PrepareStage.failed => 'Opening without music',
                  },
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: preparation.stage == PrepareStage.failed
                      ? 1
                      : preparation.progress,
                ),
                if (preparation.stage == PrepareStage.failed) ...[
                  const SizedBox(height: 10),
                  Text(
                    preparation.note ?? 'the classifier is unavailable',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What the pipeline knows about the paragraph on screen, and what the engine
/// is doing about it.
class MoodBanner extends StatelessWidget {
  const MoodBanner({super.key, required this.pipeline, this.engine});

  final MoodPipeline pipeline;
  final MusicEngine? engine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final music = engine;
    return ListenableBuilder(
      listenable:
          music == null ? pipeline : Listenable.merge([pipeline, music]),
      builder: (context, _) {
        final unavailable = pipeline.status == PipelineStatus.unavailable;
        return Container(
          width: double.infinity,
          color:
              unavailable ? scheme.errorContainer : scheme.secondaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: unavailable
                  ? scheme.onErrorContainer
                  : scheme.onSecondaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      unavailable ? Icons.cloud_off : Icons.graphic_eq,
                      size: 18,
                      color: unavailable
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_headline(pipeline),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (pipeline.status == PipelineStatus.theme ||
                        pipeline.status == PipelineStatus.classifying)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                  ],
                ),
                if (music != null) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text(
                      _musicLine(music),
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _headline(MoodPipeline pipeline) {
    if (pipeline.status == PipelineStatus.unavailable) {
      return 'Mood tagging unavailable — ${pipeline.note}';
    }
    final tag = pipeline.currentTag;
    if (tag != null) {
      final theme = pipeline.theme;
      return 'paragraph ${pipeline.position}: ${tag.mood} '
          '${tag.intensity.toStringAsFixed(2)} (${pipeline.currentSource})'
          '${theme == null ? '' : '  ·  ${theme.genreSeed}'}'
          '  ·  ${tag.reason}';
    }
    return switch (pipeline.status) {
      PipelineStatus.theme => 'Reading the book\'s theme...',
      PipelineStatus.classifying =>
        'Classifying paragraph ${pipeline.position}...',
      _ => 'paragraph ${pipeline.position}: not tagged yet',
    };
  }

  String _musicLine(MusicEngine music) {
    if (!music.enabled) return '♪ music off';
    if (!music.available) {
      return '♪ silent — ${music.note ?? 'no audio device'}';
    }
    if (music.dozing) return '♪ faded out — no page turn for a while';
    final params = music.current;
    final playing = music.playing;
    if (params == null || playing == null) return '♪ waiting for a tag';
    final pending = music.selector.pending;
    return '♪ $playing → ${params.mood} '
        'e${params.energy.toStringAsFixed(2)} · ${params.bpm}bpm'
        '${pending == null ? '' : '  ·  considering $pending'}';
  }
}
