import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'arcs.dart';
import 'book.dart';
import 'grammar.dart';

/// The one model that classifies, by decision. Not configurable.
const ollamaModel = 'qwen2.5:7b';
const ollamaUrl = 'http://localhost:11434';

/// Ollama silently truncates the prompt to the model's context window, and
/// its default is small (2048 tokens on many models). A chapter runs 8-10k
/// tokens, so the theme pass needs headroom. 16k of KV cache fits beside a
/// 7B Q4 model in 8GB of VRAM.
const ollamaNumCtx = 16384;

/// A chapter fits the model's context; this guards whole books.
const maxThemeChars = 40000;

/// A 7B model on a laptop GPU answers a six-paragraph batch in a few seconds,
/// and a cold model load adds tens of seconds; past this something is wrong,
/// not slow.
///
/// This bounds real damage rather than being a formality. Calls run serially,
/// so one request that hangs -- an unresponsive endpoint, a model stuck
/// loading -- blocks every later batch until it gives up, and the banner sits
/// on "Classifying..." the whole time. Keep it long enough for a cold load,
/// short enough that a wedged endpoint surfaces while the reader still cares.
const ollamaTimeout = Duration(seconds: 45);

// --- Prompts and schemas, ported verbatim from phase0/classify.py. That is
// the wording that was checked against real output; don't drift it without
// measuring. The paragraph prompt has drifted once, measured: see
// tagPromptVersion. -------------------------------------------------------

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

/// Which wording of the paragraph prompt a cached tag was made under. Part of
/// the tag cache's key (see [tagModel]), so changing the wording below means
/// bumping this, and every chapter is classified again rather than served
/// tags the new wording would not have given.
///
/// 2 (SUMMARY 9.43): the phase0 wording gave the model eight mood names and
/// nothing about what each was for, and on an action novel it called 73 % of
/// paragraphs tense -- "clear sky", "Master's explanation" among them -- so
/// tense sounded 82 % of the time. Version 2 says what the music is for and
/// what each mood means, and reserves tense for conflict happening now. On
/// eight sample chapters: tense 61 % -> 37 %, its peak band 42 % -> 21 %.
const tagPromptVersion = 2;

/// The model column of a cached tag: the model, and the prompt it was asked.
const tagModel = '$ollamaModel tags-v$tagPromptVersion';

const paragraphSystem =
    'You are tagging prose paragraph by paragraph for an adaptive music engine. '
    'The tag picks the background music a reader hears under that paragraph, '
    "and the music's job is to keep them absorbed in the book, not to "
    'dramatise every line. Score the feeling the passage actually lands on a '
    "reader, not its plot function or the book's genre. "
    'Intensity is how much the music should assert itself: a quiet dread and a '
    'loud panic can share a mood and differ by half a point of intensity. '
    'Paragraphs arrive in reading order and adjacent ones are usually related; '
    'let a scene build rather than resetting on every paragraph.';

/// What each mood means, in the paragraph request. Tense is defined narrowly
/// on purpose: v2 of the trial said "most paragraphs are neutral" and pushed
/// neutral to 69 % and calm to nothing, so neutral is only the fallback here.
const moodDefinitions =
    '- neutral: ordinary narration, explanation, dialogue, planning, travel or '
    'description with no particular pull; use it when no other mood fits.\n'
    '- calm: rest, safety, quiet, meditation or routine practice, peaceful '
    'surroundings, gentle moments.\n'
    '- tense: danger, conflict or pressure unfolding right now: a fight, a '
    'chase, a threat being made, a confrontation, a narrow escape, a race '
    'against time, including what characters say in the middle of one. '
    'Talking about power, plans, ambition or past and future battles is not '
    'tense, and neither is a serious tone.\n'
    '- ominous: dread or foreboding; a menace not yet acted on; something '
    'wrong.\n'
    '- melancholic: loss, grief, regret, loneliness.\n'
    '- triumphant: victory, a breakthrough, achievement, awe at power gained.\n'
    '- romantic: affection, attraction, intimacy, tenderness.\n'
    '- whimsical: humour, playfulness, absurdity, light banter.\n';

const arcScanSystem =
    'You are finding the arc boundaries of a long serialised novel, the way an '
    'editor would decide where to split it into volumes. An arc is a stretch '
    'of story with its own situation and its own resolution: a location, a '
    'cast, a goal. It ends when that goal is settled and the story turns to '
    'something else. You are shown the opening and closing of each chapter, '
    'not the whole of it, which is enough to see where the story stands. '
    'Most chapters continue what came before -- score those low. Reserve high '
    'scores for the few chapters that genuinely start something new.';

// --- Proofreading (lib/grammar.dart). Not from phase0: written for this and
// checked against the book in SUMMARY §9.41. Bump the version on any change to
// the wording or the schema, so cached answers to the old one are not served.

const proofreadPromptVersion = 3;

const proofreadSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'corrections': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'paragraph': {'type': 'integer'},
          'original': {'type': 'string'},
          'corrected': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': ['grammar', 'wrong_word', 'spelling'],
          },
          'reason': {'type': 'string'},
          'deliberate': {'type': 'boolean'},
        },
        'required': [
          'paragraph',
          'original',
          'corrected',
          'kind',
          'reason',
          'deliberate',
        ],
      },
    },
  },
  'required': ['corrections'],
};

const proofreadSystem =
    'You are a careful copy editor for a long web novel written in English by '
    'a non-native speaker. You fix only clear grammar mistakes and wrong '
    'words, with the smallest edit that fixes each one. You never rewrite for '
    'style, and you never change a word that is already correct.\n\n'
    'Fix:\n'
    '- a verb in the wrong form for the words around it: a gerund or an '
    'infinitive where the other is needed, a wrong tense, a subject and verb '
    'that disagree\n'
    '- a word or phrase that makes the sentence say something other than what '
    'it plainly means, such as a connective with the wrong meaning ("despite" '
    'where "because" is meant)\n'
    '- a missing or wrong small word (article, preposition, pronoun) when the '
    'sentence is clearly broken without the fix\n'
    '- misspelled words\n\n'
    'Never change:\n'
    '- punctuation of any kind: commas, full stops, exclamation marks, '
    'quotation marks, apostrophes, hyphens, colons\n'
    '- capitalisation, chapter titles or headings\n'
    '- a correct word for a synonym you prefer, or a phrase you would word '
    'differently\n'
    '- anything that could be deliberate: how a character speaks, slang, '
    'fragments or run-on sentences used for effect\n'
    "- names, titles, numbers, invented words and the story's own terms\n\n"
    'Only return a correction that changes at least one word. When unsure, '
    'leave it alone: most paragraphs need nothing, and an empty list is a '
    'good answer.';

/// The second look: one proposed fix, judged on its own. A 7B model proposing
/// fixes across a batch mixes real mistakes with style and the odd change of
/// meaning; asked about one edit at a time it tells them apart far better
/// (SUMMARY §9.41: 12 of 13 real fixes kept, 2 of 14 harmful ones).
const confirmFixSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'original_is_wrong': {'type': 'boolean'},
    'meaning_unchanged': {'type': 'boolean'},
    'accept': {'type': 'boolean'},
    'why': {'type': 'string'},
  },
  'required': ['original_is_wrong', 'meaning_unchanged', 'accept', 'why'],
};

const confirmFixSystem =
    'You check one proposed fix to a sentence in a novel. Accept it only if '
    'BOTH are true:\n'
    '1. The original words are clearly wrong English: a grammar error, or a '
    'word that makes the sentence say something the author plainly did not '
    'mean. Words that are merely informal, unusual, repetitive or improvable '
    'are NOT wrong.\n'
    '2. The fix changes nothing else: it adds no information, removes none, '
    'and does not change what the sentence means.\n'
    'Reject a fix that swaps a correct word for a synonym, adds a word "for '
    'clarity", removes a word the author chose, or changes what a character '
    'says aloud (unless it is a plain misspelling).';

// --- Results -----------------------------------------------------------------

/// The one-per-book palette every paragraph is scored against.
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

  /// Stable per-book id derived from the theme text itself.
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

  @override
  String toString() => '$mood ${intensity.toStringAsFixed(2)}';
}

/// Ollama could not be reached, refused, or had no such model. The app keeps
/// reading; tagging is simply off until the next trigger finds it back.
class OllamaUnavailable implements Exception {
  const OllamaUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

// --- Client ------------------------------------------------------------------

class OllamaClient {
  OllamaClient({http.Client? client, this.baseUrl = ollamaUrl})
      : _http = client ?? http.Client();

  final http.Client _http;

  /// Where Ollama listens. Mutable so a test can point at a dead port.
  String baseUrl;

  /// Requests attempted, successful or not. The pipeline log and the tests
  /// read it to prove cache hits made no calls.
  int requests = 0;

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
    final result = await _chat(system: themeSystem, user: user, schema: themeSchema);
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
    final user = 'The book\'s overall theme is "$overallTheme". Use it for '
        'context only; judge each paragraph on what it actually says.\n\n'
        'Classify each numbered paragraph below. Return one entry per '
        'paragraph, echoing its index.\n\n'
        'Moods:\n$moodDefinitions\n'
        '- intensity: 0.0-1.0, relative to this book: 0.5 is an ordinary '
        'passage of its mood; keep 0.8 and above for its strongest moments\n'
        '- reason: one short phrase, for debugging only\n\n'
        '--- PARAGRAPHS ---\n$blocks';
    final result =
        await _chat(system: paragraphSystem, user: user, schema: paragraphSchema);

    final tagged = <int, MoodTag>{};
    for (final entry in result['paragraphs'] as List) {
      final map = entry as Map<String, dynamic>;
      tagged[map['index'] as int] = MoodTag(
        mood: map['mood'] as String,
        intensity: (map['intensity'] as num).toDouble().clamp(0.0, 1.0),
        reason: map['reason'] as String,
      );
    }
    return tagged;
  }

  /// Score a run of chapters for how much each one starts a new arc.
  ///
  /// Digests rather than whole chapters: twenty chapters of this book is
  /// 156,000 characters and would not fit in `num_ctx` at any batch size worth
  /// having. See [chapterDigest] for what is kept and why.
  ///
  /// The reply is keyed by the index the caller supplied, and indices the
  /// model failed to echo are simply absent -- the same contract as
  /// [paragraphs], and for the same reason: a missing score means "no opinion,
  /// score 0", which [chooseArcs] handles, while a wrong index would move a
  /// boundary to the wrong chapter.
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
    final result =
        await _chat(system: arcScanSystem, user: user, schema: arcScanSchema);

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

  /// Clear mistakes in [paragraphs], as the model proposes them. Nothing here
  /// decides what is applied -- see `rejectionOf` in grammar.dart, which
  /// checks every proposal against the text it claims to quote.
  Future<List<Correction>> proofread(List<(int, String)> paragraphs) async {
    if (paragraphs.isEmpty) return const [];
    final blocks = [
      for (final (index, text) in paragraphs) '[$index] $text',
    ].join('\n\n');
    final user = 'Each paragraph has its number in brackets. Return every '
        'clear mistake:\n'
        '- paragraph: the number in brackets\n'
        '- original: the exact words from the paragraph, copied character '
        'for character -- just enough to show the mistake, usually three to '
        'eight words, never the whole sentence\n'
        '- corrected: those same words with only the mistake fixed\n'
        '- kind: grammar, wrong_word or spelling\n'
        '- reason: a few words\n'
        '- deliberate: true if a character or the author could plausibly '
        'have meant it this way\n\n'
        '--- PARAGRAPHS ---\n$blocks';
    final result = await _chat(
        system: proofreadSystem, user: user, schema: proofreadSchema);
    return [
      for (final raw in result['corrections'] as List? ?? const [])
        Correction.fromJson(raw as Map<String, dynamic>),
    ];
  }

  /// Whether [c] is a real fix to [paragraph]: the original clearly wrong,
  /// and the meaning untouched. See [confirmFixSystem].
  Future<({bool accept, String why})> confirmFix(
    Correction c,
    String paragraph,
  ) async {
    final result = await _chat(
      system: confirmFixSystem,
      user: 'Paragraph:\n$paragraph\n\nOriginal words: ${c.original}\n'
          'Proposed fix: ${c.corrected}',
      schema: confirmFixSchema,
    );
    return (
      accept: result['accept'] == true,
      why: (result['why'] as String? ?? '').trim(),
    );
  }

  Future<Map<String, dynamic>> _chat({
    required String system,
    required String user,
    required Map<String, Object> schema,
  }) async {
    final body = jsonEncode({
      'model': ollamaModel,
      'stream': false,
      'format': schema,
      'options': {'temperature': 0, 'num_ctx': ollamaNumCtx},
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
    });

    requests++;
    http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse('$baseUrl/api/chat'),
            headers: const {'content-type': 'application/json'},
            body: body,
          )
          .timeout(ollamaTimeout);
    } on SocketException catch (e) {
      throw OllamaUnavailable("Ollama isn't running at $baseUrl (${e.message})");
    } on http.ClientException catch (e) {
      throw OllamaUnavailable("Ollama isn't running at $baseUrl (${e.message})");
    } on TimeoutException {
      throw OllamaUnavailable(
        'Ollama did not answer within ${ollamaTimeout.inSeconds}s',
      );
    }
    if (response.statusCode != 200) {
      throw OllamaUnavailable(
        'Ollama returned ${response.statusCode}: ${response.body.trim()}',
      );
    }

    final message = jsonDecode(response.body) as Map<String, dynamic>;
    final content = (message['message'] as Map<String, dynamic>)['content'];
    return jsonDecode(content as String) as Map<String, dynamic>;
  }
}

/// Short hex digest, used for the theme id.
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();
