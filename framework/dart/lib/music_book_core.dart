/// Music for books: everything between the text and the speakers except the
/// reader and the audio device.
///
///   * **Ingest** -- ePub or chapters of text into a [Workspace], split into
///     paragraphs by one rule ([Book.fromText]).
///   * **Prepare** -- the [Pipeline]: the book's theme, arc boundaries, arc
///     themes and grouping, mood tags per paragraph, and a bed plan per set,
///     asked of any model through a [TaggingBackend] ([OllamaBackend] built
///     in).
///   * **Play** -- [BookScore] and [BedSet] read a generated set;
///     [ScoreFollower] decides what should sound where the reader is and what
///     to prepare for. A player turns its decisions into audio.
///
/// Generation itself -- prompts, MusicGen, the audibility guard, the movement
/// cull and register gate, measurement, cloud offload -- is Python, in
/// framework/python, and reads and writes the same workspace. See
/// framework/FORMAT.md for the files, and framework/README.md for how a host
/// integrates.
library;

export 'src/allocation.dart';
export 'src/arcs.dart';
export 'src/bed_set.dart';
export 'src/book.dart';
export 'src/cue_selector.dart';
export 'src/epub.dart';
export 'src/music_params.dart';
export 'src/ollama_backend.dart';
export 'src/pack.dart';
export 'src/palette.dart';
export 'src/pipeline.dart';
export 'src/played.dart';
export 'src/score_follower.dart';
export 'src/tagging.dart';
export 'src/theme_similarity.dart';
export 'src/watermark.dart';
export 'src/workspace.dart';
