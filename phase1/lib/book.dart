import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A plain-text book split into paragraphs.
class Book {
  Book({
    required this.title,
    required this.paragraphs,
    String? source,
    this.themeKeyOverride,
    this.themeTextOverride,
  })  : source = source ?? title,
        text = paragraphs.join('\n\n'),
        paragraphStarts = _starts(paragraphs);

  /// Set by the library so every chapter of one book shares a theme. Null for
  /// a standalone text, which is its own book.
  final String? themeKeyOverride;
  final String? themeTextOverride;

  /// Blocks shorter than this -- chapter headings, scene breaks, letter
  /// sign-offs -- carry no mood of their own and fold into the paragraph that
  /// follows them. Same rule as phase0/main.py, so a paragraph index means the
  /// same text here as it did in the classifier's validation runs.
  static const minParagraphChars = 60;

  /// Blank-line separated blocks, internal whitespace collapsed, short blocks
  /// folded forward (or into the last paragraph, at the very end).
  factory Book.fromText(
    String title,
    String raw, {
    String? source,
    String? themeKey,
    String? themeText,
  }) {
    final paragraphs = <String>[];
    var carry = '';
    for (final block in raw.split(RegExp(r'\n\s*\n'))) {
      final text = block.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      if (text.length < minParagraphChars) {
        carry = '$carry $text'.trim();
        continue;
      }
      paragraphs.add('$carry $text'.trim());
      carry = '';
    }
    if (carry.isNotEmpty) {
      if (paragraphs.isEmpty) {
        paragraphs.add(carry);
      } else {
        paragraphs[paragraphs.length - 1] = '${paragraphs.last} $carry';
      }
    }
    return Book(
      title: title,
      paragraphs: paragraphs,
      source: source,
      themeKeyOverride: themeKey,
      themeTextOverride: themeText,
    );
  }

  final String title;

  /// Where the text came from -- the asset's file name. Part of the cache key.
  final String source;

  final List<String> paragraphs;

  /// Every paragraph joined with a blank line: what the paginated view lays out.
  final String text;

  /// Character offset in [text] at which each paragraph begins.
  final List<int> paragraphStarts;

  /// Identity for the mood cache: the source's stem plus a hash of the text,
  /// so an edited text starts fresh instead of being served stale tags.
  late final String key = _computeKey();

  /// Where this text's *theme* is cached.
  ///
  /// Chapters of one book share a theme and so share this key. Without it a
  /// sixty-chapter novel would pay for sixty theme passes and, worse, get
  /// sixty different themes — and the theme is quoted in every paragraph
  /// prompt, so the book would drift in register as you read it.
  ///
  /// It folds in a hash of [themeText] for the same reason [key] folds in a
  /// hash of the prose: a theme is only valid for what it was computed from.
  /// When the sampling changed, every theme cached against the old sample
  /// stopped being reachable rather than being quietly served on.
  late final String themeKey = themeKeyOverride == null
      ? key
      : '$themeKeyOverride-${_digest(themeText)}';

  /// What the theme pass reads. For one chapter of a novel that should be a
  /// sample of the whole novel, not of the chapter.
  late final String themeText = themeTextOverride ?? text;

  String _computeKey() =>
      '${source.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '')}-${_digest(text)}';

  static String _digest(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 10);

  /// Index of the paragraph containing character [offset] of [text].
  int paragraphAt(int offset) {
    var index = 0;
    while (index + 1 < paragraphStarts.length &&
        paragraphStarts[index + 1] <= offset) {
      index++;
    }
    return index;
  }

  static List<int> _starts(List<String> paragraphs) {
    final starts = <int>[];
    var offset = 0;
    for (final paragraph in paragraphs) {
      starts.add(offset);
      offset += paragraph.length + 2; // the '\n\n' separator
    }
    return starts;
  }
}
