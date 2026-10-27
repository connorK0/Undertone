// A scripted model and a small synthetic book, shared by the tests
// that drive the pipeline.

import 'package:music_book_core/music_book_core.dart';

/// Answers from the prompt itself: a paragraph mentioning a fight is tense,
/// anything else calm; a chapter whose digest says NEWARC starts one. Can be
/// told to fail on the nth call, which is how resuming is tested.
class ScriptedBackend implements TaggingBackend {
  ScriptedBackend({this.failOn});

  int? failOn;
  int calls = 0;
  final asked = <String>[];

  @override
  String get name => 'scripted';

  @override
  Future<Map<String, dynamic>> chat({
    required String system,
    required String user,
    required Map<String, Object> schema,
  }) async {
    calls++;
    if (failOn != null && calls == failOn) {
      throw const TaggingUnavailable('scripted failure');
    }
    if (system == themeSystem) {
      asked.add('theme');
      return {
        'overall_theme': user.contains('sea') ? 'Nautical Adventure' : 'Drama',
        'instrumentation': 'strings and brass',
        'genre_seed': user.contains('sea') ? 'sea-epic' : 'drama',
      };
    }
    final blocks = RegExp(r'\[(\d+)\]\s*([^\[]*)').allMatches(user);
    if (system == arcScanSystem) {
      asked.add('scan');
      return {
        'chapters': [
          for (final m in blocks)
            {
              'index': int.parse(m[1]!),
              'break_score': m[2]!.contains('NEWARC') ? 1.0 : 0.1,
              'situation': 'situation ${m[1]}',
            },
        ],
      };
    }
    asked.add('tag');
    return {
      'paragraphs': [
        for (final m in blocks)
          {
            'index': int.parse(m[1]!),
            'mood': m[2]!.contains('fight') ? 'tense' : 'calm',
            'intensity': m[2]!.contains('fight') ? 0.8 : 0.3,
            'reason': 'scripted',
          },
      ],
    };
  }
}

/// A paragraph long enough not to fold into its neighbour.
String para(String what) =>
    '$what. ${'The prose goes on for a while so that it is a paragraph. ' * 2}';

List<({String title, String text})> book({
  int chapters = 12,
  Set<int> newArcAt = const {6},
  Set<int> fights = const {},
}) =>
    [
      for (var c = 0; c < chapters; c++)
        (
          title: 'Chapter ${c + 1}',
          text: [
            para(newArcAt.contains(c) ? 'NEWARC at sea' : 'Chapter $c opens'),
            para(fights.contains(c) ? 'a fight breaks out' : 'a quiet walk'),
            para(fights.contains(c) ? 'the fight goes on' : 'tea is poured'),
          ].join('\n\n'),
        ),
    ];
