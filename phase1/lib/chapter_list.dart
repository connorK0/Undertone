import 'package:flutter/material.dart';

/// Every chapter in the book, and a way to any of them.
///
/// Sized for the books this is actually used on. The chapter arrows in the app
/// bar are fine for a twelve-chapter novel and useless for a web serial with
/// 862 -- getting from chapter 3 to chapter 400 is 397 taps. So: a filter that
/// takes a number, a list that opens where you already are, and one tap.
///
/// Returns the chapter index chosen, or null.
Future<int?> showChapterList(
  BuildContext context, {
  required String title,
  required List<String> chapters,
  required int current,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ChapterList(
      title: title,
      chapters: chapters,
      current: current,
    ),
  );
}

class _ChapterList extends StatefulWidget {
  const _ChapterList({
    required this.title,
    required this.chapters,
    required this.current,
  });

  final String title;
  final List<String> chapters;
  final int current;

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  /// Fixed, so the list can be scrolled straight to the current chapter
  /// without laying out the 400 above it first.
  static const _rowHeight = 52.0;

  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _offsetFor(widget.current),
  );
  String _filter = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Puts the current chapter a third of the way down rather than at the very
  /// top, so the ones around it are visible too.
  double _offsetFor(int index) => (index * _rowHeight - 3 * _rowHeight)
      .clamp(0.0, (widget.chapters.length * _rowHeight - 1).clamp(0.0, 1e9));

  /// Indices matching the filter, in order.
  ///
  /// Matches the number as well as the title, because "Chapter 451" is what
  /// the entry says and "451" is what someone types.
  List<int> get _matches {
    final needle = _filter.trim().toLowerCase();
    if (needle.isEmpty) {
      return [for (var i = 0; i < widget.chapters.length; i++) i];
    }
    return [
      for (var i = 0; i < widget.chapters.length; i++)
        if (widget.chapters[i].toLowerCase().contains(needle) ||
            '${i + 1}'.contains(needle))
          i,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = _matches;
    final filtering = _filter.trim().isNotEmpty;

    return AlertDialog(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Find a chapter — "451", or part of its title',
                  border: const OutlineInputBorder(),
                  helperText: '${widget.chapters.length} chapters'
                      '${filtering ? ' · ${matches.length} matching' : ''}',
                ),
                onChanged: (value) => setState(() => _filter = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? const Center(child: Text('Nothing by that name.'))
                  : ListView.builder(
                      // Only when the whole book is showing: once a filter has
                      // reordered things the saved offset means nothing.
                      controller: filtering ? null : _scroll,
                      itemExtent: _rowHeight,
                      itemCount: matches.length,
                      itemBuilder: (context, row) {
                        final index = matches[row];
                        final here = index == widget.current;
                        return ListTile(
                          selected: here,
                          selectedTileColor: scheme.secondaryContainer,
                          leading: SizedBox(
                            width: 44,
                            child: Text(
                              '${index + 1}',
                              textAlign: TextAlign.end,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          title: Text(
                            widget.chapters[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight:
                                  here ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                          trailing: here
                              ? Icon(Icons.bookmark,
                                  size: 18, color: scheme.primary)
                              : null,
                          onTap: () => Navigator.of(context).pop(index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
