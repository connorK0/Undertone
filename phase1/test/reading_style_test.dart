// The page's appearance: what the defaults are, and what the palettes are
// worth measured rather than eyeballed.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_shell/reading_style.dart';

/// WCAG relative luminance. Needed to say anything true about a palette:
/// "looks fine" is exactly the claim that keeps producing unreadable themes.
double luminance(Color color) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double contrast(Color a, Color b) {
  final la = luminance(a), lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('defaults', () {
    test('reproduce the page as it was before any of this was settable', () {
      // A reader who never opens the appearance panel must see no change. The
      // numbers on the right are the constants this replaced.
      const style = defaultReadingStyle;
      expect(style.textStyle.fontFamily, 'Georgia');
      expect(style.fontSize, 19);
      expect(style.textStyle.height, 1.6);
      expect(style.textStyle.color, const Color(0xFF1F1B16));
      expect(style.paragraphGap, closeTo(18, 0.1)); // was 18
      expect(style.measure, closeTo(720, 2.5)); // was 720
      expect(ReadingStyle.padding,
          const EdgeInsets.symmetric(horizontal: 40, vertical: 32));
    });

    test('the measure grows with the size, so line length stays put', () {
      // A fixed 720 is about 70 characters at 19pt and about 45 at 30pt, which
      // is a newspaper column. Scaling keeps the ratio -- the thing that
      // actually makes a line comfortable -- constant.
      const small = ReadingStyle(fontSize: 14);
      const large = ReadingStyle(fontSize: 28);
      expect(large.measure / large.fontSize,
          closeTo(small.measure / small.fontSize, 1e-9));
      expect(large.measure, greaterThan(small.measure));
    });
  });

  group('palettes', () {
    test('every theme clears WCAG AAA against its own ink', () {
      for (final theme in ReaderTheme.values) {
        final ratio = contrast(theme.background, theme.ink);
        expect(ratio, greaterThan(7.0),
            reason: '${theme.label} is ${ratio.toStringAsFixed(1)}:1, '
                'which is not comfortable for a chapter');
      }
    });

    test('light, medium and dark are three real steps of brightness', () {
      // Otherwise "medium" is just a second light theme with a different name.
      final light = luminance(ReaderTheme.light.background);
      final medium = luminance(ReaderTheme.medium.background);
      final dark = luminance(ReaderTheme.dark.background);
      expect(light, greaterThan(medium + 0.15));
      expect(medium, greaterThan(dark + 0.15));
    });

    test('only the dark page reports itself dark', () {
      // Material derives the whole app scheme from this, so getting it wrong
      // means light-on-light app bars over a dark chapter.
      expect(ReaderTheme.dark.brightness, Brightness.dark);
      expect(ReaderTheme.light.brightness, Brightness.light);
      expect(ReaderTheme.medium.brightness, Brightness.light);
      expect(ReaderTheme.dark.themeData.scaffoldBackgroundColor,
          ReaderTheme.dark.background);
    });
  });

  group('as a cache key', () {
    test('equal styles are equal, and every field is part of that', () {
      // The paginator skips re-cutting pages when the style has not changed,
      // so a field left out of == is a page that silently overflows.
      const base = ReadingStyle();
      expect(base, const ReadingStyle());
      expect(base.hashCode, const ReadingStyle().hashCode);
      expect(base == base.copyWith(font: ReaderFont.verdana), isFalse);
      expect(base == base.copyWith(fontSize: 20), isFalse);
      expect(base == base.copyWith(spacing: LineSpacing.relaxed), isFalse);
      expect(base == base.copyWith(theme: ReaderTheme.dark), isFalse);
    });
  });

  test('every font and spacing has a face and a label', () {
    for (final font in ReaderFont.values) {
      expect(font.family, isNotEmpty);
      expect(font.label, isNotEmpty);
    }
    for (final spacing in LineSpacing.values) {
      expect(spacing.height, greaterThan(1.0));
      expect(spacing.label, isNotEmpty);
    }
    // Compact must actually be tighter than relaxed, or the control is a lie.
    expect(LineSpacing.compact.height, lessThan(LineSpacing.normal.height));
    expect(LineSpacing.normal.height, lessThan(LineSpacing.relaxed.height));
  });
}
