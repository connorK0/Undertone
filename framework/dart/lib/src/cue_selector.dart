/// Decides which cue should be playing, and refuses to change it too often.
///
/// This is the part most likely to decide whether the music helps or annoys.
/// The classifier is happy to call one paragraph 'tense' between two 'calm'
/// ones, and a reader flipping pages produces a trigger every few hundred
/// milliseconds. Following either literally gives a score that lurches, which
/// is worse than silence.
///
/// Two rules, both deliberately blunt:
///
///   * a new mood must be seen on [confirmations] separate paragraphs before it
///     is believed -- so a single odd paragraph never changes the music;
///   * a cue must have been playing for [minDwell] before it can be replaced --
///     so page-flipping cannot produce a burst of crossfades however many
///     paragraphs go past.
///
/// Kept free of audio so it can be tested without a sound device, which is
/// also the only way it gets tested at all: `flutter test` runs headless.
library;

/// The mood a stretch of paragraphs is mostly in.
///
/// Measured on chapter 1 of Dracula, the classifier returns six different moods
/// across seventeen paragraphs, changing almost every one: neutral, neutral,
/// melancholic, tense, tense, ominous, neutral, tense... That is a fair reading
/// of each paragraph and a hopeless thing to score, because music works on the
/// timescale of a scene and the tags work on the timescale of a sentence.
///
/// Damping that with a timer alone gives a score that freezes on whatever was
/// playing first. Taking the dominant mood of a short window instead throws
/// away the single-paragraph flicker while still turning when the scene does,
/// and it costs nothing: the pipeline has already classified these paragraphs
/// because they are inside its prefetch window.
///
/// Be clear about what this does not fix. Classifying the same eighteen
/// paragraphs three times -- same model, same prose, only an irrelevant change
/// of theme string -- agrees on about 70% of moods, and *widening this window
/// does not improve that number at any width from one to eight*. The
/// disagreement is not independent per-paragraph noise that averaging cancels;
/// the model differs about whole passages, because it classifies them in
/// batches with shared context. So this makes the cue change less often, not
/// make it more nearly correct. See the README.
///
/// [window] is in reading order from where the reader is. Nearer paragraphs
/// weigh more, and ties go to the nearest, so what is on screen still leads.
/// How many paragraphs [dominantTag] is given.
///
/// Four: long enough that one odd paragraph cannot carry the window, short
/// enough that the cue still turns when the scene does. Lives here rather than
/// on MusicEngine so that anything reasoning about what *would* sound can have
/// it without importing an audio engine -- see lib/played.dart.
const cueWindow = 4;

/// How far past the scoring window to look for what is coming next.
///
/// [cueWindow] paragraphs decide the *current* cue; these are the ones after
/// them, read only to prepare for a change and never to make one. Free to
/// read: an arc that has been through `tool/allocate.dart --arc N` is
/// classified to its last paragraph, so there is nothing to wait for (§9.15).
const leadWindow = 4;

/// How much bigger than a set's average change is worth preparing for.
///
/// Distances are measured from the finished audio and normalised so that 1.0
/// is that set's average change -- see `LoopLibrary.distanceBetween`. Above 1
/// by construction, so a set with no measurements, which reports exactly 1.0
/// for every pair, never leads in and behaves as it always did.
const leadThreshold = 1.25;

/// How far apart two tonal centres may be and still be allowed to sound
/// together.
///
/// §9.11 found the key clause inert, so two beds of one palette sit in
/// unrelated tonal centres, and §9.17 measured how far apart. A crossfade
/// passes through that in 2.5 seconds; a lead-in would *hold* it. Beyond this
/// the brightness still sweeps but the beds never overlap.
const leadChromaCeiling = 1.2;

({String mood, double intensity})? dominantTag(
  List<({String mood, double intensity})> window,
) {
  if (window.isEmpty) return null;

  final weight = <String, double>{};
  final intensity = <String, double>{};
  for (var i = 0; i < window.length; i++) {
    final falloff = 1 / (1 + i);
    final entry = window[i];
    weight[entry.mood] = (weight[entry.mood] ?? 0) + falloff;
    intensity[entry.mood] =
        (intensity[entry.mood] ?? 0) + entry.intensity * falloff;
  }

  // Dart maps iterate in insertion order, so the first mood seen -- the one
  // nearest the reader -- wins a tie.
  var best = window.first.mood;
  var bestWeight = 0.0;
  for (final entry in weight.entries) {
    if (entry.value > bestWeight) {
      best = entry.key;
      bestWeight = entry.value;
    }
  }
  return (mood: best, intensity: intensity[best]! / weight[best]!);
}

class CueDecision {
  const CueDecision({
    required this.mood,
    required this.energy,
    required this.changed,
  });

  /// The mood that should be playing now.
  final String mood;

  /// Target loudness, 0-1, from the mapper's blended energy.
  final double energy;

  /// True only on the observation that switched cues -- i.e. crossfade now.
  final bool changed;
}

class CueSelector {
  CueSelector({
    this.minDwell = const Duration(seconds: 15),
    this.confirmations = 2,
  });

  /// How long a cue must hold before anything may replace it.
  ///
  /// Real reading spends much longer than this on a page, so it almost never
  /// binds while reading; it exists for the reader who flips.
  final Duration minDwell;

  /// Separate paragraphs a new mood must appear on before it is believed.
  final int confirmations;

  String? _mood;
  DateTime? _since;
  double _energy = 0;

  String? _candidate;
  int _candidateSeen = 0;
  int? _lastIndex;

  String? get mood => _mood;
  double get energy => _energy;

  /// The mood being counted towards a change, if any. For the banner.
  String? get pending => _candidate;

  /// How many separate paragraphs [pending] has been seen on. With
  /// [confirmations] that is the whole of the confirmation rule, which the
  /// inspector shows because "why has the music not changed yet" is otherwise
  /// invisible.
  int get confirmationsSeen => _candidateSeen;

  /// When the current cue was committed, or null before anything has played.
  /// The other half of the answer: a confirmed mood still waits for [minDwell].
  DateTime? get since => _since;

  /// Report where the reader is and what that paragraph was tagged.
  ///
  /// Returns null before anything has ever been chosen and there is nothing to
  /// play; otherwise the cue that should be sounding, with [CueDecision.changed]
  /// set only when it just changed.
  CueDecision? observe({
    required int paragraphIndex,
    required String mood,
    required double energy,
    required DateTime now,
  }) {
    // The pipeline notifies on every batch that lands, not just on movement,
    // so the same paragraph is seen many times. Counting those towards a
    // change would let a single paragraph confirm itself.
    final isNewParagraph = paragraphIndex != _lastIndex;
    _lastIndex = paragraphIndex;

    if (_mood == null) {
      _commit(mood, energy, now);
      return CueDecision(mood: mood, energy: energy, changed: true);
    }

    if (mood == _mood) {
      // Back on the current mood: forget any part-built case for changing.
      _candidate = null;
      _candidateSeen = 0;
      _energy = energy;
      return CueDecision(mood: _mood!, energy: _energy, changed: false);
    }

    if (isNewParagraph) {
      if (mood == _candidate) {
        _candidateSeen++;
      } else {
        _candidate = mood;
        _candidateSeen = 1;
      }
    }

    final confirmed = _candidateSeen >= confirmations;
    final settled = now.difference(_since!) >= minDwell;
    if (confirmed && settled) {
      _commit(mood, energy, now);
      return CueDecision(mood: mood, energy: energy, changed: true);
    }

    // Still on the old cue. Its volume tracks the paragraphs that belong to it,
    // not the ones arguing for a change, so leave energy where it was.
    return CueDecision(mood: _mood!, energy: _energy, changed: false);
  }

  void _commit(String mood, double energy, DateTime now) {
    _mood = mood;
    _energy = energy;
    _since = now;
    _candidate = null;
    _candidateSeen = 0;
  }

  /// Forget everything. Used when a different book is opened.
  void reset() {
    _mood = null;
    _since = null;
    _energy = 0;
    _candidate = null;
    _candidateSeen = 0;
    _lastIndex = null;
  }
}
