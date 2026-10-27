/// What the language model is asked, and what comes back.
///
/// Three questions, all structured: the musical character of a book (or an
/// arc), the mood and intensity of each paragraph, and how much each chapter
/// starts a new storyline. The wording is ported verbatim from
/// phase0/classify.py by way of the reader app's `ollama_client.dart` -- that
/// is the wording that was checked against real output, so don't drift it.
///
/// What is *not* here is how the question reaches a model. That is a
/// [TaggingBackend], which only has to answer one structured chat call, so the
/// same prompts run on a local Ollama, a hosted API, or an on-device model on a
/// phone. [Tagger] puts the two together.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'arcs.dart';
import 'book.dart';

/// The eight moods every paragraph is tagged with. Fixed: the music side has
/// one prompt texture per mood (see music_params.dart and the Python
/// generator's MOOD_PARAMS), so a ninth mood here would be a mood with no bed.
const moods = [
  'tense',
  'calm',
  'melancholic',
  'triumphant',
  'romantic',
  'ominous',
  'whimsical',
  'neutral',
];

/// A chapter fits the model's context; this guards whole books.
const maxThemeChars = 40000;

const themeSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'overall_theme': {
      'type': 'string',
      'description':
          '2-4 word description of the general tone/genre for a musical score',
    },
    'instrumentation': {
      'type': 'string',
      'description':
          'Suggested instrument palette, e.g. "solo piano, sparse strings"',
    },
    'genre_seed': {
      'type': 'string',
      'description':
          'Short genre/style token suitable for an adaptive music API',
    },
  },
  'required': ['overall_theme', 'instrumentation', 'genre_seed'],
  'additionalProperties': false,
};

const paragraphSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'paragraphs': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'index': {
            'type': 'integer',
            'description': "The paragraph's index from the input",
          },
          'mood': {'type': 'string', 'enum': moods},
          'intensity': {
            'type': 'number',
            'description': '0.0 (barely present) to 1.0 (overwhelming)',
          },
          'reason': {
            'type': 'string',
            'description': 'One short phrase, for debugging',
          },
        },
        'required': ['index', 'mood', 'intensity', 'reason'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['paragraphs'],
  'additionalProperties': false,
};

const arcScanSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'chapters': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'index': {
            'type': 'integer',
            'description': "The chapter's index from the input",
          },
          'break_score': {
            'type': 'number',
            'description': '0.0 continues the same storyline, 1.0 begins a '
                'new one',
          },
          'situation': {
            'type': 'string',
            'description': '3-6 words naming what is going on: who, where, '
                'what is at stake',
          },
        },
        'required': ['index', 'break_score', 'situation'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['chapters'],
  'additionalProperties': false,
};

const themeSystem =
    'You are scoring a book for an adaptive music engine, the way a composer '
    'reads a script before writing a cue sheet. Judge the prose as written, '
    'not the subject matter in the abstract.';

const paragraphSystem =
    'You are tagging prose paragraph by paragraph for an adaptive music engine. '
    'The tag drives what a reader hears while reading that paragraph, so score '
    'the feeling the passage lands on a reader, not its plot function. '
    'Intensity is how much the music should assert itself: a quiet dread and a '
    'loud panic can share a mood and differ by half a point of intensity. '
    'Paragraphs arrive in reading order and adjacent ones are usually related; '
    'let a scene build rather than resetting on every paragraph.';

const arcScanSystem =
    'You are finding the arc boundaries of a long serialised novel, the way an '
    'editor would decide where to split it into volumes. An arc is a stretch '
    'of story with its own situation and its own resolution: a location, a '
    'cast, a goal. It ends when that goal is settled and the story turns to '
    'something else. You are shown the opening and closing of each chapter, '
    'not the whole of it, which is enough to see where the story stands. '
    'Most chapters continue what came before -- score those low. Reserve high '
    'scores for the few chapters that genuinely start something new.';

// --- Results -----------------------------------------------------------------

/// The palette every paragraph of a book (or an arc) is scored against, and
/// the part of every generation prompt that varies between books.
class BookTheme {
  BookTheme({
    required this.overallTheme,
    required this.instrumentation,
    required this.genreSeed,
    String? themeId,
  }) : themeId = themeId ?? deriveThemeId(overallTheme);

  final String overallTheme;
  final String instrumentation;
  final String genreSeed;

  /// Stable id derived from the theme text itself.
  final String themeId;

  /// Slug of the theme plus a short hash, as phase0/cache.py does it.
  static String deriveThemeId(String overallTheme) {
    final slug = overallTheme
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final digest = sha256Hex(overallTheme).substring(0, 6);
    return '$slug-$digest';
  }

  Map<String, dynamic> toJson() => {
        'overall_theme': overallTheme,
        'instrumentation': instrumentation,
        'genre_seed': genreSeed,
        'theme_id': themeId,
      };

  static BookTheme fromJson(Map<String, dynamic> json) => BookTheme(
        overallTheme: json['overall_theme'] as String,
        instrumentation: json['instrumentation'] as String,
        genreSeed: json['genre_seed'] as String,
        themeId: json['theme_id'] as String?,
      );
}

class MoodTag {
  const MoodTag({
    required this.mood,
    required this.intensity,
    required this.reason,
  });

  final String mood;
  final double intensity;
  final String reason;

  Map<String, dynamic> toJson() =>
      {'mood': mood, 'intensity': intensity, 'reason': reason};

  static MoodTag fromJson(Map<String, dynamic> json) => MoodTag(
        mood: json['mood'] as String,
        intensity: (json['intensity'] as num).toDouble(),
        reason: json['reason'] as String? ?? '',
      );

  @override
  String toString() => '$mood ${intensity.toStringAsFixed(2)}';
}

/// The model could not be reached, refused, or had no such model. Nothing is
/// written for the batch that failed; a later run asks for it again.
class TaggingUnavailable implements Exception {
  const TaggingUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

// --- Backends ----------------------------------------------------------------

/// Anything that can answer one structured chat call.
///
/// [schema] is a JSON Schema; the reply must be a JSON object that satisfies
/// it. Throw [TaggingUnavailable] when the model cannot be reached -- the
/// pipeline treats that as "stop here and resume later", never as a result.
abstract interface class TaggingBackend {
  /// What produced the tags, recorded beside them: a tag is only comparable
  /// with tags from the same model (SUMMARY: the classifier bake-off).
  String get name;

  Future<Map<String, dynamic>> chat({
    required String system,
    required String user,
    required Map<String, Object> schema,
  });
}

/// The three questions, asked of any backend.
class Tagger {
  Tagger(this.backend);

  final TaggingBackend backend;

  /// Requests attempted, successful or not.
  int requests = 0;

  Future<Map<String, dynamic>> _ask(
      String system, String user, Map<String, Object> schema) {
    requests++;
    return backend.chat(system: system, user: user, schema: schema);
  }

  Future<BookTheme> theme(Book book) async {
    final user = 'Identify the musical character of this book from the '
        'following excerpt.\n\n'
        '- overall_theme: 2-4 word description of the general tone/genre for a '
        'musical score\n'
        '- instrumentation: a suggested instrument palette\n'
        '- genre_seed: a short genre/style token suitable for an adaptive music '
        'API\n\n'
        '--- EXCERPT ---\n'
        '${book.themeText.length > maxThemeChars ? book.themeText.substring(0, maxThemeChars) : book.themeText}';
    final result = await _ask(themeSystem, user, themeSchema);
    return BookTheme(
      overallTheme: result['overall_theme'] as String,
      instrumentation: result['instrumentation'] as String,
      genreSeed: result['genre_seed'] as String,
    );
  }

  /// Scores one batch. Several paragraphs go in one call: it costs far less
  /// than one each, and it gives the model the surrounding scene, which is
  /// most of what mood continuity depends on.
  Future<Map<int, MoodTag>> paragraphs(
    List<(int, String)> numbered,
    String overallTheme,
  ) async {
    final blocks = [for (final (index, text) in numbered) '[$index]\n$text']
        .join('\n\n');
    final user = 'The book\'s overall theme is "$overallTheme".\n\n'
        'Classify each numbered paragraph below. Return one entry per '
        'paragraph, echoing its index.\n\n'
        '- mood: one of ${moods.join(', ')}\n'
        '- intensity: 0.0-1.0\n'
        '- reason: one short phrase, for debugging only\n\n'
        '--- PARAGRAPHS ---\n$blocks';
    final result = await _ask(paragraphSystem, user, paragraphSchema);

    // Only indices that were asked for, and only known moods: a backend with
    // weaker schema enforcement than Ollama's must not be able to plant a tag
    // on a paragraph nobody asked about, or a mood with no bed.
    final wanted = {for (final (index, _) in numbered) index};
    final tagged = <int, MoodTag>{};
    for (final entry in result['paragraphs'] as List) {
      final map = entry as Map<String, dynamic>;
      final index = (map['index'] as num).toInt();
      final mood = map['mood'] as String;
      if (!wanted.contains(index) || !moods.contains(mood)) continue;
      tagged[index] = MoodTag(
        mood: mood,
        intensity: (map['intensity'] as num).toDouble().clamp(0.0, 1.0),
        reason: map['reason'] as String? ?? '',
      );
    }
    return tagged;
  }

  /// Score a run of chapters for how much each one starts a new arc.
  ///
  /// The reply is keyed by the index the caller supplied, and indices the
  /// model failed to echo are simply absent: a missing score means "no
  /// opinion, score 0", which [chooseArcs] handles, while a wrong index would
  /// move a boundary to the wrong chapter.
  Future<Map<int, ChapterBreak>> chapterBreaks(
    List<(int, String)> digests,
    String overallTheme,
  ) async {
    if (digests.isEmpty) return const {};
    final blocks = [
      for (final (index, digest) in digests) '[$index] $digest',
    ].join('\n\n');
    final user = 'The book\'s overall theme is "$overallTheme".\n\n'
        'Below are consecutive chapters of one long novel, each shown as its '
        'title, its opening, and its closing. For each, judge whether it '
        'begins a new story arc.\n\n'
        '- index: echo the number in brackets\n'
        '- break_score: 0.0-0.2 continues the same scene or thread; '
        '0.3-0.5 a new scene within the same storyline; '
        '0.6-0.8 a clear shift of place, cast or goal; '
        '0.9-1.0 the previous storyline has resolved and a new one begins\n'
        '- situation: 3-6 words naming what is going on\n\n'
        '--- CHAPTERS ---\n$blocks';
    final result = await _ask(arcScanSystem, user, arcScanSchema);

    final wanted = {for (final (index, _) in digests) index};
    final scored = <int, ChapterBreak>{};
    for (final entry in result['chapters'] as List) {
      final map = entry as Map<String, dynamic>;
      final index = (map['index'] as num).toInt();
      if (!wanted.contains(index)) continue;
      scored[index] = ChapterBreak(
        index: index,
        score: (map['break_score'] as num).toDouble().clamp(0.0, 1.0),
        situation: (map['situation'] as String? ?? '').trim(),
      );
    }
    return scored;
  }
}

/// Hex SHA-256, used for the theme id.
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();
