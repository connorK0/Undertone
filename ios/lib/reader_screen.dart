/// Reading one book, with its score following along.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:music_book_core/music_book_core.dart';
import 'package:music_book_player/music_book_player.dart';

import 'reading.dart';
import 'shelf.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.ws, required this.player});

  final Workspace ws;
  final ScorePlayer player;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  List<WorkspaceChapter>? _chapters;
  int _chapter = 0;
  int _startAt = 0;
  var _look = const ReadingLook();

  /// Why the book is silent, when it is; null when there is music to play.
  String? _silence;

  bool _music = true;
  double _volume = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final ws = widget.ws;
    final chapters = await ws.chapters();
    final place = await ReadingPlace.load(ws);
    final theme = (await ws.bookTheme())?.theme;
    String? silence;
    if (theme == null) {
      silence = 'This book has not been prepared for music yet.';
    } else if (!hasMusic(ws)) {
      silence = 'No music has been generated for this book yet.';
    } else if (!widget.player.available) {
      silence = widget.player.note ?? 'No audio device.';
    }
    if (theme != null && hasMusic(ws)) {
      await widget.player.openBook(
        score: await BookScore.load(ws.directory.path),
        theme: theme,
        tags: tagSourceFor(ws),
      );
    }
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      _chapter = place.chapter.clamp(0, chapters.length - 1);
      _startAt = place.paragraph;
      _silence = silence;
    });
  }

  void _settled(int paragraph) {
    unawaited(ReadingPlace(_chapter, paragraph).save(widget.ws));
    if (_music) unawaited(widget.player.onPosition(_chapter, paragraph));
  }

  void _goTo(int chapter) {
    final chapters = _chapters;
    if (chapters == null || chapter < 0 || chapter >= chapters.length) return;
    setState(() {
      _chapter = chapter;
      _startAt = 0;
    });
  }

  @override
  void dispose() {
    unawaited(widget.player.closeBook());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _chapters;
    if (chapters == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final chapter = chapters[_chapter];
    return Scaffold(
      backgroundColor: _look.background,
      appBar: AppBar(
        title: Text(widget.ws.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Reading and music',
            icon: const Icon(Icons.tune),
            onPressed: _settings,
          ),
        ],
      ),
      body: ChapterView(
        key: ValueKey(_chapter),
        title: chapter.title,
        paragraphs: chapter.paragraphs,
        look: _look,
        startAt: _startAt,
        onSettled: _settled,
      ),
      bottomNavigationBar: SafeArea(
        child: Material(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous chapter',
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _chapter > 0 ? () => _goTo(_chapter - 1) : null,
                ),
                Expanded(child: _MusicLine(
                    player: widget.player, silence: _silence, on: _music)),
                Text('${_chapter + 1} / ${chapters.length}',
                    style: Theme.of(context).textTheme.labelMedium),
                IconButton(
                  tooltip: 'Next chapter',
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _chapter + 1 < chapters.length
                      ? () => _goTo(_chapter + 1)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _settings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void set(void Function() change) {
            setState(change);
            update(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Text size', style: Theme.of(context).textTheme.labelLarge),
                  Slider.adaptive(
                    min: ReadingLook.minFontSize,
                    max: ReadingLook.maxFontSize,
                    value: _look.fontSize,
                    onChanged: (v) =>
                        set(() => _look = _look.copyWith(fontSize: v)),
                  ),
                  SegmentedButton<Paper>(
                    segments: const [
                      ButtonSegment(value: Paper.light, label: Text('Light')),
                      ButtonSegment(value: Paper.sepia, label: Text('Sepia')),
                      ButtonSegment(value: Paper.dark, label: Text('Dark')),
                    ],
                    selected: {_look.paper},
                    onSelectionChanged: (s) =>
                        set(() => _look = _look.copyWith(paper: s.first)),
                  ),
                  const Divider(height: 32),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Music'),
                    subtitle: _silence == null ? null : Text(_silence!),
                    value: _music,
                    onChanged: _silence != null
                        ? null
                        : (v) => set(() {
                              _music = v;
                              widget.player.setEnabled(v);
                            }),
                  ),
                  Text('Music volume',
                      style: Theme.of(context).textTheme.labelLarge),
                  Slider.adaptive(
                    value: _volume,
                    onChanged: _silence != null || !_music
                        ? null
                        : (v) => set(() {
                              _volume = v;
                              widget.player.setVolume(v);
                            }),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// What the score is doing, in a line: the cue sounding, and whether it is
/// preparing for a change -- or why there is no music. Never blank, because a
/// silent reader with nothing on screen to say why is a bug report.
class _MusicLine extends StatelessWidget {
  const _MusicLine({
    required this.player,
    required this.silence,
    required this.on,
  });

  final ScorePlayer player;
  final String? silence;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final String line;
        if (silence != null) {
          line = silence!;
        } else if (!on) {
          line = 'Music off';
        } else if (player.playing == null) {
          line = player.note ?? 'Music starts as you read';
        } else {
          final leading = player.leading;
          line = leading == null
              ? '♪ ${player.playing}'
              : '♪ ${player.playing} → $leading';
        }
        return Text(line,
            style: style,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
      },
    );
  }
}
