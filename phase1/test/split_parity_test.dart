// The classifier keys tags by paragraph index, and those tags were validated
// against phase0's Python splitter. If the two splitters ever disagree, a tag
// lands on the wrong paragraph. This pins them together on the real chapters.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_shell/book.dart';

void main() {
  final expectedFile = File(Platform.environment['SPLIT_PARITY_JSON'] ??
      'test/python_split.json');

  test('Dart splits the sample chapters exactly as phase0/main.py does', () {
    expect(
      expectedFile.existsSync(),
      isTrue,
      reason: 'regenerate with phase1/tool/dump_python_split.py',
    );
    final expected = (jsonDecode(expectedFile.readAsStringSync())
            as Map<String, dynamic>)
        .map((name, paragraphs) =>
            MapEntry(name, (paragraphs as List).cast<String>()));

    for (final entry in expected.entries) {
      final raw =
          File('assets/books/${entry.key}').readAsStringSync(encoding: utf8);
      final book = Book.fromText(entry.key, raw, source: entry.key);

      expect(book.paragraphs.length, entry.value.length,
          reason: '${entry.key}: paragraph count must match Python');
      for (var i = 0; i < entry.value.length; i++) {
        expect(book.paragraphs[i], entry.value[i],
            reason: '${entry.key}: paragraph $i differs from Python');
      }
    }
  });
}
