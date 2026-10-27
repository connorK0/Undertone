import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'book.dart';
import 'mood_trigger.dart';
import 'reading_style.dart';

/// Paginated reading. The mood hook fires on every page turn.
class PageReader extends StatefulWidget {
  const PageReader({
    super.key,
    required this.book,
    this.style = defaultReadingStyle,
    this.onNextChapter,
    this.onPreviousChapter,
    this.startAtEnd = false,
    this.marks = const {},
  });

  final Book book;
  final ReadingStyle style;

  /// Turning past the last page. Null on the last chapter of a book, which is
  /// what stops the reader running off the end of it.
  ///
  /// A chapter break is a container boundary, not a place to stop reading, so
  /// the same gesture that turns a page should cross it -- otherwise the last
  /// page of every chapter is a dead end that only the chapter list can get
  /// out of.
  final VoidCallback? onNextChapter;

  /// Turning back past the first page. Null on the first chapter of a book.
  final VoidCallback? onPreviousChapter;

  /// Open on the last page rather than the first: how a chapter is entered by
  /// turning back into it, so going back lands where going back should.
  final bool startAtEnd;

  /// What the proofreader changed, to underline. See lib/grammar.dart.
  final ProofMarks marks;

  @override
  State<PageReader> createState() => _PageReaderState();
}

class _PageReaderState extends State<PageReader> {
  final _focus = FocusNode();

  List<TextRange> _pages = const [];
  Size? _pagedFor;

  /// The text the pages were cut from. A chapter's corrections can arrive
  /// after it opens, and the corrected text breaks into pages differently.
  Book? _bookFor;

  /// The style the current page breaks were cut for. Without this, changing
  /// the font at an unchanged window size keeps ranges measured against the
  /// old face, and the page silently overflows or ends early.
  ReadingStyle? _styledFor;
  int _page = 0;

  /// Character offset the reader is at. Survives re-pagination on resize, so
  /// a window drag doesn't lose your place. Past the end means the last page.
  late int _anchor = widget.startAtEnd ? widget.book.text.length : 0;
  bool _announced = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _paginate(Size size, TextScaler scaler) {
    if (_pagedFor == size &&
        _styledFor == widget.style &&
        identical(_bookFor, widget.book) &&
        _pages.isNotEmpty) {
      return;
    }
    final was = _pages.length;
    _pagedFor = size;
    _styledFor = widget.style;
    _bookFor = widget.book;
    _pages = paginate(widget.book.text, widget.style.textStyle, size, scaler);
    _page = _pageContaining(_anchor);
    if (!_announced) {
      _announced = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fire('opened'));
    }

    // The page bar is a *sibling* of the LayoutBuilder that calls this, and
    // build runs before layout -- so on the frame a chapter opens the bar has
    // already been built with a count of zero. It renders "Page 1 of 0" and,
    // because it disables its own arrows when page >= count, they do nothing
    // until some unrelated rebuild happens along. Turning by key or by tapping
    // the page still worked, which is how this went unnoticed.
    //
    // setState is illegal during layout, so ask for the extra frame after this
    // one. Only when the count actually moved, or this would rebuild forever.
    if (_pages.length != was) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  int _pageContaining(int offset) {
    for (var i = 0; i < _pages.length; i++) {
      if (offset < _pages[i].end) return i;
    }
    return _pages.isEmpty ? 0 : _pages.length - 1;
  }

  void _turn(int delta) {
    if (_pages.isEmpty) return;
    final target = (_page + delta).clamp(0, _pages.length - 1);
    if (target == _page) {
      // Already against an edge. Forwards off the last page is the next
      // chapter; backwards off the first is the previous one, which opens on
      // its *last* page (startAtEnd) -- landing at its start would read as
      // going the wrong way.
      if (delta > 0 && _page == _pages.length - 1) widget.onNextChapter?.call();
      if (delta < 0 && _page == 0) widget.onPreviousChapter?.call();
      return;
    }
    setState(() {
      _page = target;
      _anchor = _pages[target].start;
    });
    _fire('page turn');
  }

  /// Every mark, moved from its paragraph into [Book.text], in order.
  List<({int start, int end})> _marksInText() {
    final starts = widget.book.paragraphStarts;
    final paragraphs = widget.marks.keys.toList()..sort();
    return [
      for (final paragraph in paragraphs)
        if (paragraph < starts.length)
          for (final r in widget.marks[paragraph]!)
            (start: starts[paragraph] + r.start, end: starts[paragraph] + r.end),
    ];
  }

  void _fire(String reason) {
    if (!mounted || _pages.isEmpty) return;
    onMoodTrigger(ReadingPosition(
      paragraphIndex: widget.book.paragraphAt(_pages[_page].start),
      mode: ReadingMode.pages,
      reason: reason,
      page: _page + 1,
      pageCount: _pages.length,
    ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Only deliberate presses turn pages. A held key auto-repeats, and one
    // held key should not flip twenty pages and fire twenty triggers.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _turn(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      _turn(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.style.measure),
                child: Padding(
                  padding: ReadingStyle.padding,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      _paginate(size, scaler);
                      final range = _pages[_page];
                      final pageText = widget.book.text
                          .substring(range.start, range.end)
                          .replaceFirst(RegExp(r'^\n+'), '');
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _turn(
                          details.localPosition.dx < size.width / 2 ? -1 : 1,
                        ),
                        child: ClipRect(
                          child: SizedBox.expand(
                            child: Text.rich(
                              markedSpan(
                                pageText,
                                _marksInText(),
                                widget.style,
                                // Where pageText starts in the book's text:
                                // the page, less the newlines stripped off it.
                                offset: range.end - pageText.length,
                              ),
                              textScaler: scaler,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          _PageBar(
            page: _page + 1,
            count: _pages.length,
            // Enabled on the first page when there is a chapter before this
            // one, since there it means "previous chapter".
            onPrevious: _page > 0
                ? () => _turn(-1)
                : (widget.onPreviousChapter == null ? null : () => _turn(-1)),
            // Enabled on the last page when there is a chapter after this
            // one, since there it means "next chapter".
            onNext: (_pages.isNotEmpty && _page == _pages.length - 1)
                ? (widget.onNextChapter == null ? null : () => _turn(1))
                : () => _turn(1),
          ),
        ],
      ),
    );
  }
}

/// Splits [text] into pages that each fit [page] when rendered in [style].
///
/// Lays the whole text out once, walks its line metrics, and cuts wherever
/// the next line would overflow the page height. Each page is a character
/// range starting at a line boundary, so rendering the substring on its own
/// wraps exactly as it did in the full layout.
List<TextRange> paginate(
  String text,
  TextStyle style,
  Size page,
  TextScaler scaler,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout(maxWidth: page.width);

  final pages = <TextRange>[];
  var pageStart = -1;
  var pageEnd = 0;
  var used = 0.0;
  for (final line in painter.computeLineMetrics()) {
    final bounds = painter.getLineBoundary(
      painter.getPositionForOffset(Offset(0, line.baseline)),
    );
    if (pageStart >= 0 && used + line.height > page.height) {
      pages.add(TextRange(start: pageStart, end: pageEnd));
      pageStart = -1;
      used = 0;
    }
    if (pageStart < 0) pageStart = bounds.start;
    pageEnd = bounds.end;
    used += line.height;
  }
  if (pageStart >= 0) pages.add(TextRange(start: pageStart, end: pageEnd));
  painter.dispose();
  return pages;
}

class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.page,
    required this.count,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int count;

  /// Null when there is nowhere to go: the first page of the first chapter.
  final VoidCallback? onPrevious;

  /// Null when there is nowhere to go: the last page of the last chapter.
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous page (Left, PageUp)',
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Page $page of $count'),
          ),
          IconButton(
            tooltip: 'Next page (Right, PageDown, Space)',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
