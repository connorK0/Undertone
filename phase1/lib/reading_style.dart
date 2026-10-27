import 'package:flutter/material.dart';

/// How the page looks: the things a reader expects to be able to change.
///
/// One object rather than four settings threaded separately, because the
/// paginator has to notice when *any* of it moves. Page breaks are computed
/// from a real layout of the text, so a font change at an unchanged window
/// size would otherwise go on serving ranges cut for the old face -- and the
/// symptom is not a crash but text quietly overflowing the page. Hence the
/// value equality below: it is the paginator's cache key.

/// Three steps of page brightness.
///
/// Measured against their own ink, all three clear WCAG AAA (7:1) by a margin;
/// what separates them is how much light the page throws, which is the thing
/// being chosen. Contrast, and the luminance of the page itself:
///
///     light    15.9:1    92.5%     paper by a window
///     medium   10.6:1    62.2%     paper in a room
///     dark     12.4:1     0.6%     reading at night
enum ReaderTheme { light, medium, dark }

/// Faces to read in.
///
/// Windows system fonts, so there is nothing to bundle, nothing to license and
/// no dependency to add. That is also the limit of it: **none of these ship
/// with iOS**, and the iOS build will need either bundled faces or its own
/// list. Flutter falls back silently to the platform default for a family it
/// cannot find, so the failure there would be invisible rather than loud.
enum ReaderFont { georgia, cambria, palatino, segoe, verdana }

/// Space between lines, as a multiple of the font size.
enum LineSpacing { compact, normal, relaxed }

extension ReaderThemeLook on ReaderTheme {
  String get label => switch (this) {
        ReaderTheme.light => 'Light',
        ReaderTheme.medium => 'Medium',
        ReaderTheme.dark => 'Dark',
      };

  /// The page.
  Color get background => switch (this) {
        ReaderTheme.light => const Color(0xFFFAF6EF),
        ReaderTheme.medium => const Color(0xFFD6CEC0),
        ReaderTheme.dark => const Color(0xFF14120F),
      };

  /// The text on it.
  Color get ink => switch (this) {
        ReaderTheme.light => const Color(0xFF1F1B16),
        ReaderTheme.medium => const Color(0xFF221E19),
        ReaderTheme.dark => const Color(0xFFD8D2C6),
      };

  Brightness get brightness =>
      this == ReaderTheme.dark ? Brightness.dark : Brightness.light;

  /// The whole app follows the page, not just the prose. A dark chapter with a
  /// bright app bar over it is worse than either, and the inspector, the
  /// banner and the settings dialog all have to be readable in all three.
  ThemeData get themeData => ThemeData(
        brightness: brightness,
        // The warm brown the app has always used. Material derives the rest of
        // the scheme from it, so one seed covers all three brightnesses.
        colorSchemeSeed: const Color(0xFF6D5B45),
        scaffoldBackgroundColor: background,
      );
}

extension ReaderFontFace on ReaderFont {
  /// The family name, as Windows knows it.
  String get family => switch (this) {
        ReaderFont.georgia => 'Georgia',
        ReaderFont.cambria => 'Cambria',
        ReaderFont.palatino => 'Palatino Linotype',
        ReaderFont.segoe => 'Segoe UI',
        ReaderFont.verdana => 'Verdana',
      };

  String get label => switch (this) {
        ReaderFont.palatino => 'Palatino',
        _ => family,
      };

  bool get isSerif => switch (this) {
        ReaderFont.georgia || ReaderFont.cambria || ReaderFont.palatino => true,
        ReaderFont.segoe || ReaderFont.verdana => false,
      };
}

extension LineSpacingHeight on LineSpacing {
  double get height => switch (this) {
        LineSpacing.compact => 1.35,
        LineSpacing.normal => 1.6,
        LineSpacing.relaxed => 1.9,
      };

  String get label => switch (this) {
        LineSpacing.compact => 'Compact',
        LineSpacing.normal => 'Normal',
        LineSpacing.relaxed => 'Relaxed',
      };
}

/// Everything about the look of the prose, in one value.
///
/// The defaults are exactly what the app rendered before any of this was
/// settable, so a reader who never opens the appearance panel sees no change.
@immutable
class ReadingStyle {
  const ReadingStyle({
    this.font = ReaderFont.georgia,
    this.fontSize = 19,
    this.spacing = LineSpacing.normal,
    this.theme = ReaderTheme.light,
  });

  /// The range the size slider offers. Below 13 the measure gets so narrow
  /// that lines break oddly; above 30 a normal window holds a paragraph.
  static const minFontSize = 13.0;
  static const maxFontSize = 30.0;

  final ReaderFont font;
  final double fontSize;
  final LineSpacing spacing;
  final ReaderTheme theme;

  TextStyle get textStyle => TextStyle(
        fontFamily: font.family,
        fontSize: fontSize,
        height: spacing.height,
        color: theme.ink,
      );

  /// How wide a column of text may get.
  ///
  /// Scaled with the size rather than fixed, because what makes a line
  /// comfortable is its length in *characters*, not in pixels: a fixed 720
  /// that reads well at 19pt is about 45 characters at 30pt, which is a
  /// newspaper column. 38em is roughly 70 characters in a serif face, and at
  /// the default size it comes to 722 -- two pixels off the constant it
  /// replaces, which is to say the same page.
  double get measure => fontSize * 38;

  /// Space between paragraphs. 0.95em is 18 at the default size, as before.
  double get paragraphGap => fontSize * 0.95;

  static const padding = EdgeInsets.symmetric(horizontal: 40, vertical: 32);

  ReadingStyle copyWith({
    ReaderFont? font,
    double? fontSize,
    LineSpacing? spacing,
    ReaderTheme? theme,
  }) =>
      ReadingStyle(
        font: font ?? this.font,
        fontSize: fontSize ?? this.fontSize,
        spacing: spacing ?? this.spacing,
        theme: theme ?? this.theme,
      );

  @override
  bool operator ==(Object other) =>
      other is ReadingStyle &&
      other.font == font &&
      other.fontSize == fontSize &&
      other.spacing == spacing &&
      other.theme == theme;

  @override
  int get hashCode => Object.hash(font, fontSize, spacing, theme);

  @override
  String toString() => '${font.label} ${fontSize.toStringAsFixed(0)}pt '
      '${spacing.label.toLowerCase()} ${theme.label.toLowerCase()}';
}

/// The page as it was before any of this was settable.
const defaultReadingStyle = ReadingStyle();

/// Stretches of text the proofreader changed: paragraph -> ranges in that
/// paragraph's text, sorted. See lib/grammar.dart.
typedef ProofMarks = Map<int, List<({int start, int end})>>;

/// [text] -- which begins at [offset] of whatever [marks] measure -- with
/// every marked stretch under a faint dotted line, so a reader can tell where
/// the page is not word for word what the author wrote.
///
/// The underline is decoration only: it changes nothing about layout, so a
/// page cut against the plain text still fits.
TextSpan markedSpan(
  String text,
  List<({int start, int end})> marks,
  ReadingStyle style, {
  int offset = 0,
}) {
  if (marks.isEmpty) return TextSpan(text: text, style: style.textStyle);
  final marked = TextStyle(
    decoration: TextDecoration.underline,
    decorationStyle: TextDecorationStyle.dotted,
    decorationColor: style.theme.ink.withValues(alpha: 0.45),
  );
  final spans = <TextSpan>[];
  var at = 0;
  for (final mark in marks) {
    final start = (mark.start - offset).clamp(at, text.length);
    final end = (mark.end - offset).clamp(start, text.length);
    if (end <= start) continue;
    if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
    spans.add(TextSpan(text: text.substring(start, end), style: marked));
    at = end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style.textStyle, children: spans);
}

/// How long the reader must stop scrolling before the position counts as
/// settled. Every wheel tick, drag update and fling frame resets this.
const settleDelay = Duration(milliseconds: 400);
