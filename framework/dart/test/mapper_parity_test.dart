// lib/music_params.dart is a port of phase0/mapper.py, and those numbers decide
// what a reader hears. A drift between the two would be invisible in use -- the
// app would still play something, just not what Phase 0 validated. This pins
// them together over every mood and a dense intensity sweep.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:music_book_core/music_book_core.dart';

void main() {
  final fixtureFile = File(
      Platform.environment['MAPPER_PARITY_JSON'] ?? 'test/python_mapper.json');

  test('Dart maps moods exactly as phase0/mapper.py does', () {
    expect(
      fixtureFile.existsSync(),
      isTrue,
      reason: 'regenerate with phase1/tool/dump_python_mapper.py',
    );
    final fixture =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    final themeJson = fixture['theme'] as Map<String, dynamic>;
    final theme = BookTheme(
      overallTheme: 'Mystery and Gothic',
      instrumentation: themeJson['instrumentation'] as String,
      genreSeed: themeJson['genre_seed'] as String,
      themeId: themeJson['theme_id'] as String,
    );

    final cases = fixture['cases'] as List;
    expect(cases, isNotEmpty);

    for (final entry in cases) {
      final testCase = entry as Map<String, dynamic>;
      final mood = testCase['mood'] as String;
      final intensity = (testCase['intensity'] as num).toDouble();
      final expected = testCase['expected'] as Map<String, dynamic>;
      final where = '$mood @ $intensity';

      final actual = mapToMusicParams(mood, intensity, theme);

      expect(actual.genre, expected['genre'], reason: 'genre, $where');
      expect(actual.mood, expected['mood'], reason: 'mood token, $where');
      expect(actual.intensity, closeTo((expected['intensity'] as num).toDouble(), 1e-9),
          reason: 'intensity, $where');
      expect(actual.energy, closeTo((expected['energy'] as num).toDouble(), 1e-9),
          reason: 'energy, $where');
      expect(actual.bpm, expected['bpm'], reason: 'bpm, $where');
      expect(actual.instrumentation, expected['instrumentation'],
          reason: 'instrumentation, $where');
      expect(actual.themeId, expected['theme_id'], reason: 'theme_id, $where');
    }
  });

  test('every mood the classifier can return has a mapping', () {
    // The taxonomy is shared with phase0 and pinned by the schema in
    // ollama_client.dart. A mood with no entry would throw at the moment the
    // reader arrived at that paragraph -- with music playing.
    for (final mood in moods) {
      expect(moodParams.containsKey(mood), isTrue,
          reason: '$mood is in the classifier schema but has no MoodParams');
    }
    expect(moodParams.length, moods.length,
        reason: 'no mappings for moods the classifier cannot produce');
  });
}
