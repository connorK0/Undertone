// Reading a generated set, and deciding what sounds where the reader is.

import 'dart:convert';
import 'dart:io';

import 'package:music_book_core/music_book_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Map<String, dynamic> manifestOf(List<(String, int)> beds,
        {Map<String, Object>? distances}) =>
    {
      'loops': [
        for (final (cue, variant) in beds)
          {
            'cue': cue,
            'mood': moodOf(cue),
            'band': int.tryParse(cue.split('-').last),
            'variant': variant,
            'file': variant == 0 ? '$cue.wav' : '$cue-v$variant.wav',
          },
      ],
      'distances': ?distances,
    };

MoodTag tag(String mood, double intensity) =>
    MoodTag(mood: mood, intensity: intensity, reason: '');

final theme = BookTheme(
    overallTheme: 'Drama', instrumentation: 'strings', genreSeed: 'drama');

void main() {
  group('BedSet', () {
    test('variants come out in order whatever order the rows are in', () {
      final set = BedSet.fromManifest(
          manifestOf([('tense-1', 2), ('tense-1', 0), ('tense-1', 1)]), 'd');
      expect(set.variantsOf('tense-1'),
          [p.join('d', 'tense-1.wav'), p.join('d', 'tense-1-v1.wav'),
           p.join('d', 'tense-1-v2.wav')]);
      expect(set.banded, isTrue);
    });

    test('a missing band falls back within the mood, never across', () {
      final set = BedSet.fromManifest(
          manifestOf([('tense-0', 0), ('calm-0', 0)]), 'd');
      expect(set.cueFor('tense', 0.9), 'tense-0');
      expect(set.cueFor('ominous', 0.9), 'ominous-1',
          reason: 'no ominous bed at all: asked for, not substituted');
    });

    test('distances are symmetric, and 1.0 when unmeasured', () {
      final measured = BedSet.fromManifest(
          manifestOf([('tense-0', 0), ('tense-1', 0)], distances: {
            'tense-0|tense-1': {'timbre': 1.4, 'chroma': 0.9},
          }),
          'd');
      expect(measured.distanceBetween('tense-1', 'tense-0').timbre, 1.4);
      expect(measured.measured, isTrue);
      final bare =
          BedSet.fromManifest(manifestOf([('tense-0', 0)]), 'd');
      expect(bare.distanceBetween('tense-0', 'calm-0').timbre, 1.0);
      expect(bare.measured, isFalse);
    });
  });

  group('BookScore', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('mb-'));
    tearDown(() async => root.delete(recursive: true));

    void write(String path, Object json) {
      final file = File(p.join(root.path, path));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(json));
    }

    test('a chapter plays its arc\'s set, or the one it shares', () async {
      write('palette.json', {
        'arcs': 2,
        'boundaries': [
          {'index': 0, 'start': 0, 'end': 9, 'title': '', 'palette': 0},
          {'index': 1, 'start': 10, 'end': 19, 'title': '', 'palette': 1},
          {'index': 2, 'start': 20, 'end': 29, 'title': '', 'palette': 0},
        ],
      });
      write('arc-000/manifest.json', manifestOf([('calm-0', 0)]));
      write('arc-001/manifest.json', manifestOf([('tense-0', 0)]));
      final score = await BookScore.load(root.path);
      expect((await score.setFor(5))!.cues, {'calm-0'});
      expect((await score.setFor(15))!.cues, {'tense-0'});
      expect((await score.setFor(25))!.cues, {'calm-0'},
          reason: 'arc 2 plays arc 0\'s beds');
    });

    test('an arc not generated yet plays the last one that was', () async {
      write('palette.json', {
        'arcs': 1,
        'boundaries': [
          {'index': 0, 'start': 0, 'end': 9, 'title': '', 'palette': 0},
          {'index': 1, 'start': 10, 'end': 19, 'title': '', 'palette': 1},
        ],
      });
      write('arc-000/manifest.json', manifestOf([('calm-0', 0)]));
      final score = await BookScore.load(root.path);
      expect((await score.setFor(15))!.cues, {'calm-0'});
    });

    test('nothing generated is silence, not an error', () async {
      final score = await BookScore.load(root.path);
      expect(await score.setFor(0), isNull);
    });
  });

  group('ScoreFollower', () {
    final set = BedSet.fromManifest(
        manifestOf([('calm-0', 0), ('tense-0', 0), ('tense-1', 0)],
            distances: {
              'calm-0|tense-1': {'timbre': 1.6, 'chroma': 0.8},
              'calm-0|tense-0': {'timbre': 1.1, 'chroma': 0.8},
              'tense-0|tense-1': {'timbre': 1.3, 'chroma': 1.5},
            }),
        'd');
    final start = DateTime(2026);

    test('the first tagged window commits, and nothing before it does', () {
      final follower = ScoreFollower(theme: theme);
      expect(
          follower.observe(
              set: set, chapter: [null, tag('calm', 0.2)], paragraph: 0,
              now: start),
          isNull,
          reason: 'the window stops at the first untagged paragraph');
      final first = follower.observe(
          set: set, chapter: [tag('calm', 0.2)], paragraph: 0, now: start)!;
      expect(first.cue, 'calm-0');
      expect(first.changed, isTrue);
    });

    test('a big change coming is prepared for, as a second voice', () {
      final follower = ScoreFollower(theme: theme);
      final chapter = [
        for (var i = 0; i < 4; i++) tag('calm', 0.2),
        for (var i = 0; i < 4; i++) tag('tense', 0.9),
      ];
      final decision = follower.observe(
          set: set, chapter: chapter, paragraph: 0, now: start)!;
      expect(decision.cue, 'calm-0');
      expect(decision.lead?.cue, 'tense-1');
      expect(decision.lead!.overlap, isTrue);
    });

    test('a small change is not, and says why', () {
      final follower = ScoreFollower(theme: theme);
      final decision = follower.observe(
          set: set,
          chapter: [
            for (var i = 0; i < 4; i++) tag('calm', 0.2),
            for (var i = 0; i < 4; i++) tag('tense', 0.3),
          ],
          paragraph: 0,
          now: start)!;
      expect(decision.lead, isNull);
      expect(decision.leadNote, contains('under'));
    });

    test('tonally far apart leads by brightness only', () {
      final follower = ScoreFollower(theme: theme);
      final decision = follower.observe(
          set: set,
          chapter: [
            for (var i = 0; i < 4; i++) tag('tense', 0.3),
            for (var i = 0; i < 4; i++) tag('tense', 0.9),
          ],
          paragraph: 0,
          now: start)!;
      expect(decision.lead?.cue, 'tense-1');
      expect(decision.lead!.overlap, isFalse);
      expect(decision.leadNote, 'brightness only');
    });

    test('the look-ahead crosses into the next chapter; the window does not',
        () {
      final follower = ScoreFollower(theme: theme);
      final decision = follower.observe(
          set: set,
          chapter: [for (var i = 0; i < 4; i++) tag('calm', 0.2)],
          next: [for (var i = 0; i < 4; i++) tag('tense', 0.9)],
          paragraph: 0,
          now: start)!;
      expect(decision.cue, 'calm-0');
      expect(decision.lead?.cue, 'tense-1');
    });

    test('a change needs confirming and waits out the dwell', () {
      final follower = ScoreFollower(theme: theme);
      final calm = [for (var i = 0; i < 12; i++) tag('calm', 0.2)];
      final tense = [for (var i = 0; i < 12; i++) tag('tense', 0.9)];
      final chapter = [...calm, ...tense];
      follower.observe(set: set, chapter: chapter, paragraph: 0, now: start);
      // Reader jumps into the tense stretch well after the dwell: the first
      // paragraph there is one confirmation, the second commits.
      final later = start.add(const Duration(minutes: 1));
      expect(
          follower
              .observe(set: set, chapter: chapter, paragraph: 12, now: later)!
              .changed,
          isFalse);
      final second = follower.observe(
          set: set, chapter: chapter, paragraph: 13, now: later)!;
      expect(second.changed, isTrue);
      expect(second.cue, 'tense-1');
    });
  });
}
