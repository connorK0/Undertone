/// How a chapter looks, and where in it the reader is.
library;

import 'dart:async';

import 'package:flutter/material.dart';

enum Paper { light, sepia, dark }

class ReadingLook {
  const ReadingLook({this.fontSize = 19, this.paper = Paper.light});

  static const minFontSize = 14.0;
  static const maxFontSize = 30.0;

  final double fontSize;
  final Paper paper;

  Color get background => switch (paper) {
        Paper.light => const Color(0xFFFFFFFF),
        Paper.sepia => const Color(0xFFF4ECD8),
        Paper.dark => const Color(0xFF121212),
      };

  Color get ink => switch (paper) {
        Paper.light => const Color(0xFF1B1B1B),
        Paper.sepia => const Color(0xFF3B2F20),
        Paper.dark => const Color(0xFFD8D4CC),
      };

  TextStyle get text => TextStyle(
        fontFamily: 'Georgia',
        fontFamilyFallback: const ['Times New Roman', 'serif'],
        fontSize: fontSize,
        height: 1.55,
        color: ink,
      );

  ReadingLook copyWith({double? fontSize, Paper? paper}) => ReadingLook(
      fontSize: fontSize ?? this.fontSize, paper: paper ?? this.paper);
}

/// How long the reader must stop scrolling before the position counts. Every
/// drag update and fling frame resets it -- the reader app's value.
const settleDelay = Duration(milliseconds: 400);

/// One chapter, scrolled. Reports the paragraph being read whenever
/// scrolling settles, and once on opening.
///
/// "Being read" is the paragraph a third of the way down the viewport, the
/// reader app's rule: on a scrolling page the eyes sit in the upper part of
/// the screen, and dead centre misreports the top of a chapter, where a
/// short heading pushes the centre onto paragraph three before anything has
/// been read.
///
/// Every paragraph is built (a chapter is tens of paragraphs, not
/// thousands), so each can be measured and the saved place can be scrolled
/// to directly.
class ChapterView extends StatefulWidget {
  const ChapterView({
    super.key,
    required this.title,
    required this.paragraphs,
    required this.look,
    required this.onSettled,
    this.startAt = 0,
  });

  final String title;
  final List<String> paragraphs;
  final ReadingLook look;
  final int startAt;
  final void Function(int paragraph) onSettled;

  @override
  State<ChapterView> createState() => _ChapterViewState();
}

class _ChapterViewState extends State<ChapterView> {
  final _viewport = GlobalKey();
  late List<GlobalKey> _keys;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.paragraphs) GlobalKey()];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final at = widget.startAt.clamp(0, _keys.length - 1);
      final target = _keys.isEmpty ? null : _keys[at].currentContext;
      if (at > 0 && target != null) {
        await Scrollable.ensureVisible(target, alignment: 1 / 3);
      }
      _report();
    });
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
      _settle = Timer(settleDelay, _report);
    }
    return false;
  }

  void _report() {
    if (!mounted || _keys.isEmpty) return;
    widget.onSettled(_paragraphAtReadingLine());
  }

  int _paragraphAtReadingLine() {
    final viewport = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return 0;
    final line =
        viewport.localToGlobal(Offset(0, viewport.size.height / 3)).dy;
    var nearest = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (top <= line && line < bottom) return i;
      final distance = line < top ? top - line : line - bottom;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = i;
      }
    }
    return nearest;
  }

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    return ColoredBox(
      color: look.background,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SizedBox.expand(
          key: _viewport,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 120),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text(widget.title,
                            style: look.text.copyWith(
                                fontSize: look.fontSize * 1.3,
                                fontWeight: FontWeight.w600)),
                      ),
                    for (var i = 0; i < widget.paragraphs.length; i++)
                      Padding(
                        key: _keys[i],
                        padding: EdgeInsets.only(bottom: look.fontSize * 0.9),
                        child: Text(widget.paragraphs[i], style: look.text),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
