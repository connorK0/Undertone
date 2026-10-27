import 'dart:async';

import 'package:flutter/material.dart';

import 'arcs.dart';
import 'grammar.dart';
import 'mood_pipeline.dart';
import 'music_engine.dart';
import 'music_library.dart';

/// Everything the score is doing, while it is doing it.
///
/// The app has a lot of machinery between prose and sound -- classify, smooth
/// over a window, confirm, dwell, map, choose a loop, crossfade, sweep a filter
/// -- and until now the only window onto it was a one-line banner and the debug
/// console. That is enough to see *what* is playing and useless for the
/// question that actually comes up while reading: why that, and why now.
///
/// So this shows the whole chain in the order the decision is made, and it
/// shows the parts that are waiting as well as the parts that fired -- a mood
/// counting towards a change, a dwell not yet satisfied. "Nothing is happening
/// and here is what it is waiting for" is the state that most needs explaining.
///
/// Read-only, with two deliberate exceptions. Nothing here changes how the
/// score *decides*, so having the panel open cannot be the reason a reading
/// session chose differently -- but the audition section does take the audio,
/// because the alternative was reading for half an hour and hoping the prose
/// went somewhere that reached the bed you wanted to hear. The selector keeps
/// running underneath it, and the score resumes wherever the prose has got to.
/// And the bed-set section can play another arc's beds under this chapter, so
/// two arcs can be compared on the same prose.
class InspectorPanel extends StatefulWidget {
  const InspectorPanel({
    super.key,
    required this.pipeline,
    required this.engine,
    required this.title,
    required this.chapter,
    required this.chapterCount,
    this.proof,
  });

  final MoodPipeline pipeline;
  final MusicEngine engine;
  final String title;
  final int chapter;
  final int chapterCount;

  /// This chapter's proofreading, or null if it has not been checked.
  final Proofread? proof;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  Timer? _tick;

  /// The book's generated sets, read once per book: they change only when a
  /// set is installed, and the panel is reopened far more often than that.
  Future<List<({int set, List<Arc> arcs})>>? _sets;
  String? _setsFor;

  @override
  void initState() {
    super.initState();
    // Gain, cutoff and the voice count are read from the audio engine rather
    // than pushed by it, and the dwell countdown is a clock. None of those
    // notify, so the panel polls while it is on screen -- and only then.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pipeline = widget.pipeline;
    final engine = widget.engine;

    return ListenableBuilder(
      listenable: Listenable.merge([pipeline, engine]),
      builder: (context, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            _book(context),
            _classifier(context),
            _selection(context),
            _music(context),
            _bedSet(context),
            _audition(context),
            _proofreading(context),
            _history(context),
          ],
        ),
      ),
    );
  }

  // --- 1. the book -------------------------------------------------------
  Widget _book(BuildContext context) {
    final pipeline = widget.pipeline;
    final theme = pipeline.theme;
    final book = pipeline.book;
    return _Section(
      title: 'Book',
      children: [
        _Field('title', widget.title),
        _Field('chapter', '${widget.chapter + 1} of ${widget.chapterCount}'),
        _Field('paragraphs', '${book?.paragraphs.length ?? 0}'),
        if (book != null) _Field('chapter key', book.key, mono: true),
        const _Gap(),
        if (theme == null)
          const _Field('theme', 'not read yet', dim: true)
        else ...[
          // One theme per book, not per chapter, and every paragraph prompt
          // quotes it -- so it is upstream of every tag below.
          _Field('theme', theme.overallTheme),
          _Field('genre seed', theme.genreSeed),
          _Field('instruments', theme.instrumentation),
          _Field('theme id', theme.themeId, mono: true),
        ],
      ],
    );
  }

  // --- 2. what the model has said ----------------------------------------
  Widget _classifier(BuildContext context) {
    final pipeline = widget.pipeline;
    final book = pipeline.book;
    final tag = pipeline.currentTag;
    final inFlight = pipeline.inFlight;
    final total = book?.paragraphs.length ?? 0;

    return _Section(
      title: 'Classifier',
      children: [
        _Field('status', pipeline.status.name,
            dim: pipeline.status == PipelineStatus.idle),
        if (pipeline.note != null) _Field('note', pipeline.note!),
        _Field('at paragraph', '${pipeline.position}'),
        _Field('tagged', '${pipeline.tagCount} of $total'),
        _Field(
          'in flight',
          inFlight.isEmpty
              ? 'nothing'
              : '${inFlight.first}-${inFlight.last} (${inFlight.length})',
          dim: inFlight.isEmpty,
        ),
        _Field('model calls', '${pipeline.client.requests}'),
        const _Gap(),
        // The prose itself, so a tag can be judged against what it was a tag
        // *of* without hunting for the paragraph on the page.
        if (book != null && pipeline.position < book.paragraphs.length)
          _Field('text', _excerpt(book.paragraphs[pipeline.position]),
              wrap: true, dim: true),
        if (tag == null)
          const _Field('this paragraph', 'not tagged yet', dim: true)
        else ...[
          _Field('mood', '${tag.mood}  ${tag.intensity.toStringAsFixed(2)}'),
          _Field('from', pipeline.currentSource ?? '-'),
          // The model's own justification. Carried through the cache since
          // Phase 1 and never shown until now; it is the clearest evidence of
          // whether a tag is reasonable.
          _Field('reason', tag.reason, wrap: true),
        ],
      ],
    );
  }

  // --- 3. how that became a cue ------------------------------------------
  Widget _selection(BuildContext context) {
    final engine = widget.engine;
    final selector = engine.selector;
    final window = engine.window;
    final dominant = engine.dominant;
    final since = selector.since;
    final held = since == null ? null : DateTime.now().difference(since);
    final dwellLeft = held == null ? null : selector.minDwell - held;

    return _Section(
      title: 'Cue selection',
      children: [
        if (window.isEmpty)
          const _Field('window', 'nothing to decide over yet', dim: true)
        else ...[
          // Nearer paragraphs count for more, which is why a single odd
          // paragraph under the reader's eye cannot swing the cue by itself.
          const _Field('window', 'paragraph, tag, weight', dim: true),
          for (var i = 0; i < window.length; i++)
            _Field(
              '  p${engine.windowStart + i}',
              '${window[i].mood} ${window[i].intensity.toStringAsFixed(2)}'
              '   ×${(1 / (1 + i)).toStringAsFixed(2)}',
              mono: true,
            ),
          if (dominant != null)
            _Field('dominant',
                '${dominant.mood} ${dominant.intensity.toStringAsFixed(2)}'),
        ],
        const _Gap(),
        _Field('playing cue', selector.mood ?? 'nothing yet',
            dim: selector.mood == null),
        // The two reasons a change can be pending rather than done.
        if (selector.pending != null)
          _Field(
            'considering',
            '${selector.pending}  '
            '(${selector.confirmationsSeen} of ${selector.confirmations} '
            'paragraphs)',
          )
        else
          const _Field('considering', 'nothing', dim: true),
        // Distinct from 'considering': that is the selector deciding whether
        // to move, this is the audio getting ready for a move nobody has
        // decided on yet. Shown because a lead-in that is only a brightness
        // sweep is otherwise indistinguishable from nothing happening.
        if (engine.leading case final coming?)
          _Field(
            'leading into',
            '$coming  ${engine.leadingAudibly ? 'under the current bed' : 'by '
                'brightness only — too far apart tonally'}',
          )
        else
          // The reason, not just "nothing": several different failures used
          // to render identically here, including two real ones.
          _Field('leading into', engine.leadNote, dim: true),
        if (held != null)
          _Field(
            'held for',
            '${_duration(held)}'
            '${dwellLeft != null && !dwellLeft.isNegative ? '   dwell blocks a change for ${_duration(dwellLeft)}' : '   dwell satisfied'}',
          ),
      ],
    );
  }

  // --- 4. what it chose, and what came out of the speakers ---------------
  Widget _music(BuildContext context) {
    final engine = widget.engine;
    final params = engine.current;
    // What the score chose, which is not always what the speakers are doing:
    // with music switched off, no audio device, or a doze in progress, the
    // decision is still being made and is still worth seeing.
    final chosen = engine.selector.mood;
    final details = engine.detailsFor(chosen);
    // The bed actually sounding, when the cue owns several and one of them is.
    // A cue with eight takes is the whole point of the allocation, and "which
    // one is this" is exactly the question the panel is here to answer.
    final asset = engine.playingBed ?? engine.assetFor(chosen);
    final takes = engine.playingBedCount;
    final take = engine.playingBedNumber;
    final motif = engine.libraryManifest['motif'];
    final cutoff = engine.cutoff;
    final gain = engine.playingVolume;

    return _Section(
      title: 'Music',
      children: [
        _Field('library', engine.library?.name ?? 'not loaded'),
        _Field('chose', chosen ?? 'nothing yet', dim: chosen == null),
        _Field(
          'sounding',
          !engine.available
              ? 'no audio — ${engine.note ?? 'no device'}'
              : !engine.enabled
                  ? 'music switched off'
                  : engine.dozing
                      ? 'faded out — no page turn for a while'
                      : engine.playing ?? 'silent',
          dim: engine.playing == null,
        ),
        // The whole path from the book down to the file, on one line, because
        // reading it off five separate rows is exactly the work this panel is
        // supposed to save. Under the experiment library that path has a real
        // shape -- theme, motif, mode, treatment -- and under the mood
        // libraries it is honestly short: theme, mood, file.
        if (chosen != null) _Field('branch', _lineage(chosen), wrap: true),
        if (asset != null)
          _Field(
              takes > 1 && take > 0 ? 'file (take $take of $takes)' : 'file',
              asset,
              mono: true,
              wrap: true),
        const _Gap(),
        // Whatever the loaded library records about this particular loop: how
        // it was made, what it is meant to sound like, how seamless it
        // measured. Untyped on purpose -- each library's manifest carries its
        // own fields, and this shows what is there rather than a fixed set.
        if (details.isEmpty)
          const _Field('provenance', 'no library loaded', dim: true)
        else
          for (final entry in details.entries)
            if (entry.value != null && entry.key != 'mood')
              _Field('  ${entry.key}', '${entry.value}',
                  mono: true, wrap: true),
        if (motif is List) ...[
          const _Gap(),
          _Field('motif', _motifLine(motif), mono: true, wrap: true),
        ],
        const _Gap(),
        if (params != null) ...[
          // The mapper's output. Only mood and energy reach the loop engine;
          // the rest is carried for a real music API later.
          _Field('mapped to',
              '${params.mood}  e${params.energy.toStringAsFixed(2)}  '
              '${params.bpm}bpm'),
          _Field('from mood', params.sourceMood),
        ],
        _Field('gain', gain == null ? '-' : gain.toStringAsFixed(3)),
        // Intensity moves brightness as well as loudness, because loudness
        // alone renders the whole intensity range as about 3 dB.
        _Field('low-pass', cutoff == null ? '-' : '${cutoff.round()} Hz'),
        _Field('voices', '${engine.voices}',
            dim: engine.voices < 2),
        _Field('cue changes', '${engine.crossfades}'),
      ],
    );
  }

  // --- 5. whose beds are playing -------------------------------------------
  Widget _bedSet(BuildContext context) {
    final engine = widget.engine;
    final book = engine.bookId;
    if (book == null) {
      return const _Section(
        title: 'Bed set',
        children: [_Field('sets', 'no generated beds for this book', dim: true)],
      );
    }
    if (_setsFor != book) {
      _setsFor = book;
      _sets = LoopLibrary.generatedSets(book);
    }
    final scheme = Theme.of(context).colorScheme;
    final pinned = engine.pinnedSet;

    return FutureBuilder(
      future: _sets,
      builder: (context, snapshot) {
        final sets = snapshot.data ?? const [];
        return _Section(
          title: 'Bed set',
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                pinned == null
                    ? 'Following the book: each arc plays its own beds.'
                    : "Arc ${pinned + 1}'s beds, whatever chapter is open. "
                        'The score decides as it always does.',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: pinned == null ? scheme.outline : scheme.primary,
                ),
              ),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _Take(
                  label: 'Follow the book',
                  on: pinned == null,
                  onTap: () => engine.pinSet(null),
                  width: null,
                ),
                for (final entry in sets)
                  Tooltip(
                    message: [
                      for (final arc in entry.arcs)
                        'arc ${arc.index + 1}, chapters '
                            '${arc.start + 1}-${arc.end + 1}: ${arc.title}',
                    ].join('\n'),
                    child: _Take(
                      label: 'Arc ${entry.set + 1}',
                      on: pinned == entry.set,
                      onTap: () => engine.pinSet(entry.set),
                      width: null,
                    ),
                  ),
              ],
            ),
            if (snapshot.hasData && sets.length < 2)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: _Field('', 'only one arc has beds so far', dim: true),
              ),
          ],
        );
      },
    );
  }

  // --- 6. hear one bed on its own -----------------------------------------
  Widget _audition(BuildContext context) {
    final engine = widget.engine;
    final scheme = Theme.of(context).colorScheme;
    final beds = engine.beds;
    final playing = engine.auditioning;

    if (beds.isEmpty) {
      return _Section(
        title: 'Audition',
        children: [_Field('beds', 'no set loaded', dim: true)],
      );
    }

    // Sorted, so the same bed is in the same place every time the panel is
    // opened: by mood, then by band within it.
    final cues = beds.keys.toList()..sort();
    return _Section(
      title: 'Audition',
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  switch ((playing, engine.auditionProblem)) {
                    (_, final String why) => 'Nothing played: $why',
                    (null, _) => 'Tap a take to hear it on its own.',
                    (final p?, _) => 'Playing ${p.cue} take ${p.take} — '
                        'the score is paused, not lost.',
                  },
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: switch ((playing, engine.auditionProblem)) {
                      (_, final String _) => scheme.error,
                      (null, _) => scheme.outline,
                      _ => scheme.primary,
                    },
                  ),
                ),
              ),
              if (playing != null)
                TextButton(
                  onPressed: () => engine.stopAudition(),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Stop', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        for (final cue in cues)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 104,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      cue,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var take = 1; take <= beds[cue]!.length; take++)
                        _Take(
                          label: '$take',
                          on: playing?.cue == cue && playing?.take == take,
                          onTap: () => engine.audition(cue, take),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // --- 7. what the proofreader changed, and what it was not allowed to ----
  Widget _proofreading(BuildContext context) {
    final proof = widget.proof;
    if (proof == null) {
      return const _Section(
        title: 'Proofreading',
        children: [_Field('chapter', 'not checked', dim: true)],
      );
    }
    return _Section(
      title: 'Proofreading',
      children: [
        _Field('fixed', '${proof.applied} of ${proof.proposals.length} proposed'),
        // Every proposal, turned down or not: a wrong call by the model is
        // judged here, and a wrong call by the rules is too.
        for (final p in proof.proposals) ...[
          const _Gap(),
          _Field(
            'p${p.correction.paragraph}',
            '${p.correction.original}  ->  ${p.correction.corrected}',
            wrap: true,
            dim: p.rejected != null,
          ),
          _Field(
            '',
            p.rejected == null
                ? '${p.correction.kind}: ${p.correction.reason}'
                : 'not applied: ${p.rejected}'
                    '${p.correction.verdict.isEmpty ? '' : ' -- '
                        '${p.correction.verdict}'}',
            wrap: true,
            dim: true,
          ),
        ],
      ],
    );
  }

  // --- 8. what it has done so far ----------------------------------------
  Widget _history(BuildContext context) {
    final history = widget.engine.history;
    return _Section(
      title: 'Cue changes',
      children: [
        if (history.isEmpty)
          const _Field('', 'none yet in this chapter', dim: true)
        else
          for (final event in history)
            _Field(
              '  ${_clock(event.at)}',
              'p${event.paragraph}  ${event.cue}'
              '${event.cue == event.sourceMood ? '' : '   ← ${event.sourceMood}'}'
              '  ${event.intensity.toStringAsFixed(2)}',
              mono: true,
              wrap: true,
            ),
      ],
    );
  }

  String _excerpt(String paragraph) {
    final text = paragraph.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 140 ? text : '${text.substring(0, 139)}…';
  }

  String _lineage(String chosen) {
    final engine = widget.engine;
    final details = engine.detailsFor(chosen);
    final theme = widget.pipeline.theme;
    final parts = <String>[
      if (theme != null) '“${theme.overallTheme}”',
      if (engine.library == MusicLibrary.experiment) ...[
        'one motif',
        if (details['mode'] != null) '${details['mode']}',
      ] else if (engine.current != null &&
          engine.current!.sourceMood != chosen)
        // Under a mood library the cue key *is* the mood, so naming it twice
        // would pad the line rather than explain it.
        engine.current!.sourceMood,
      chosen,
      if (details['band'] != null) '${details['band']}',
    ];
    return parts.join('  →  ');
  }

  String _motifLine(List<dynamic> motif) => motif
      .map((n) => '${(n as Map)['degree']}/${n['beats']}')
      .join(' ');

  String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';

  String _duration(Duration d) {
    final seconds = d.inSeconds.abs();
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
}

/// One take of one cue, as a tappable chip. Small on purpose: a cue can own
/// nine of these and they have to fit a 380px panel beside a book.
class _Take extends StatelessWidget {
  const _Take({
    required this.label,
    required this.on,
    required this.onTap,
    this.width = 26,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  /// A take number is a square; a word is as wide as it needs (null).
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: width,
        height: 24,
        padding: width == null
            ? const EdgeInsets.symmetric(horizontal: 8)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: on ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: on ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        // Hugs the label sideways, so a word does not stretch to the row.
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Divider(height: 9, color: scheme.outlineVariant),
          ...children,
        ],
      ),
    );
  }
}

/// One labelled line. Long values wrap rather than being cut off, because a
/// truncated reason or file path is the one thing you were looking at.
class _Field extends StatelessWidget {
  const _Field(
    this.label,
    this.value, {
    this.mono = false,
    this.dim = false,
    this.wrap = false,
  });

  final String label;
  final String value;
  final bool mono;
  final bool dim;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final valueStyle = TextStyle(
      fontSize: 12,
      height: 1.35,
      fontFamily: mono ? 'monospace' : null,
      color: dim ? scheme.outline : scheme.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: valueStyle,
              maxLines: wrap ? null : 2,
              overflow: wrap ? null : TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Gap extends StatelessWidget {
  const _Gap();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 7);
}
