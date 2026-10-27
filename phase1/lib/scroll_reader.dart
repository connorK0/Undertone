import 'dart:async';

import 'package:flutter/material.dart';

import 'book.dart';
import 'mood_trigger.dart';
import 'reading_style.dart';

/// Continuous-scroll reading. The mood hook fires once the scrolling has
/// stopped for [settleDelay], never while it is in motion.
class ScrollReader extends StatefulWidget {
  const ScrollReader({
    super.key,
    required this.book,
    this.style = defaultReadingStyle,
    this.marks = const {},
  });

  final Book book;
  final ReadingStyle style;

  /// What the proofreader changed, to underline. See lib/grammar.dart.
  final ProofMarks marks;

  @override
  State<ScrollReader> createState() => _ScrollReaderState();
}

class _ScrollReaderState extends State<ScrollReader> {
  final _viewportKey = GlobalKey();

  /// Paragraph tiles currently built by the list, by index. Only these have
  /// a position on screen to measure.
  final _built = <int, BuildContext>{};

  Timer? _settle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fire('opened'));
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _settle?.cancel();
      _settle = Timer(settleDelay, () => _fire('scroll settled'));
    }
    return false;
  }

  void _fire(String reason) {
    if (!mounted) return;
    onMoodTrigger(ReadingPosition(
      paragraphIndex: _paragraphAtCenter(),
      mode: ReadingMode.scroll,
      reason: reason,
    ));
  }

  /// The paragraph a third of the way down the viewport. On a scrolling page
  /// the eyes sit in the upper part of the screen and the reader scrolls when
  /// they near the bottom, so that is a better proxy than dead centre -- which
  /// also misreports the top of a chapter, where a short heading paragraph
  /// pushes the centre onto paragraph three before anything has been read.
  /// Falls back to the nearest paragraph if the sample lands in a gap.
  int _paragraphAtCenter() {
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return 0;
    final centerY =
        viewport.localToGlobal(Offset(0, viewport.size.height / 3)).dy;

    int? nearest;
    var nearestDistance = double.infinity;
    for (final entry in _built.entries) {
      final box = entry.value.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (top <= centerY && centerY < bottom) return entry.key;
      final distance = centerY < top ? top - centerY : centerY - bottom;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = entry.key;
      }
    }
    return nearest ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Center(
        child: ConstrainedBox(
          key: _viewportKey,
          constraints: BoxConstraints(maxWidth: widget.style.measure),
          child: ListView.builder(
            padding: ReadingStyle.padding,
            itemCount: widget.book.paragraphs.length,
            itemBuilder: (context, index) => _ParagraphTile(
              index: index,
              text: widget.book.paragraphs[index],
              marks: widget.marks[index] ?? const [],
              registry: _built,
              style: widget.style,
            ),
          ),
        ),
      ),
    );
  }
}

class _ParagraphTile extends StatefulWidget {
  const _ParagraphTile({
    required this.index,
    required this.text,
    required this.marks,
    required this.registry,
    required this.style,
  });

  final int index;
  final String text;
  final List<({int start, int end})> marks;
  final Map<int, BuildContext> registry;
  final ReadingStyle style;

  @override
  State<_ParagraphTile> createState() => _ParagraphTileState();
}

class _ParagraphTileState extends State<_ParagraphTile> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.index] = context;
  }

  @override
  void didUpdateWidget(_ParagraphTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      widget.registry.remove(oldWidget.index);
      widget.registry[widget.index] = context;
    }
  }

  @override
  void dispose() {
    widget.registry.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: widget.style.paragraphGap),
      child: Text.rich(markedSpan(widget.text, widget.marks, widget.style)),
    );
  }
}
