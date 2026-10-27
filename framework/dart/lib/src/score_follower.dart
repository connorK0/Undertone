/// What should be sounding for where the reader is, and what to prepare for.
///
/// The decision half of the reader app's MusicEngine, with no audio in it:
/// given the tags around the reader's paragraph and the bed set that plays
/// there, it answers "which cue, how loud, did it just change, and is a big
/// change coming". A player on any platform turns those answers into
/// crossfades; the rules that decide them live here once.
///
/// The rules, all the app's:
///
///   * the cue is the weighted-dominant tag of the [cueWindow] paragraphs from
///     the reader onward ([dominantTag]), stopping at the first untagged one,
///     and not crossing into the next chapter;
///   * its intensity and energy are the mapper's ([mapToMusicParams]), and the
///     cue is what the set actually has ([BedSet.cueFor]);
///   * a change must be confirmed and must wait out the dwell ([CueSelector]);
///   * the [leadWindow] paragraphs *after* the window -- across the chapter
///     turn, which was the one change nothing could prepare for -- are read
///     only to prepare: a lead-in when the coming cue is at least
///     [leadThreshold] of the set's average change away, as a second voice
///     when the two are tonally close enough ([leadChromaCeiling]) and as a
///     brightness sweep only when they are not.
library;

import 'bed_set.dart';
import 'cue_selector.dart';
import 'music_params.dart';
import 'tagging.dart';

/// Something worth preparing for.
class Lead {
  const Lead({
    required this.cue,
    required this.energy,
    required this.timbre,
    required this.chroma,
  });

  final String cue;
  final double energy;

  /// How far away, in the set's average change.
  final double timbre;
  final double chroma;

  /// Whether the coming bed may sound under the current one, or only the
  /// current one's brightness should move toward it.
  bool get overlap => chroma <= leadChromaCeiling;
}

class ScoreDecision {
  const ScoreDecision({
    required this.cue,
    required this.energy,
    required this.changed,
    required this.lead,
    required this.leadNote,
  });

  /// The cue that should be sounding.
  final String cue;

  /// Target loudness, 0-1.
  final double energy;

  /// True only on the observation that switched cues: crossfade now.
  final bool changed;

  /// What to prepare for, or null.
  final Lead? lead;

  /// Why there is, or is not, a lead -- "nothing" covers four different
  /// situations, and two of them were once bugs that looked like the feature.
  final String leadNote;
}

class ScoreFollower {
  ScoreFollower({required this.theme, CueSelector? selector})
      : selector = selector ?? CueSelector();

  /// The book's theme: the mapper needs it for energy and tempo.
  final BookTheme theme;
  final CueSelector selector;

  /// One observation: the reader is on [paragraph] of a chapter whose tags
  /// are [chapter] (null where untagged), and [next] holds the next chapter's
  /// tags for looking ahead across the turn. Null until anything is tagged.
  ScoreDecision? observe({
    required BedSet set,
    required List<MoodTag?> chapter,
    List<MoodTag?> next = const [],
    required int paragraph,
    required DateTime now,
  }) {
    final window = <({String mood, double intensity})>[];
    for (var i = paragraph; i < paragraph + cueWindow; i++) {
      final tag = i < chapter.length ? chapter[i] : null;
      if (tag == null) break;
      window.add((mood: tag.mood, intensity: tag.intensity));
    }
    final dominant = dominantTag(window);
    if (dominant == null) return null;
    final params = mapToMusicParams(dominant.mood, dominant.intensity, theme);
    final decision = selector.observe(
      paragraphIndex: paragraph,
      mood: set.cueFor(params.sourceMood, params.intensity),
      energy: params.energy,
      now: now,
    );
    if (decision == null) return null;

    final after = <({String mood, double intensity})>[];
    final start = paragraph + cueWindow;
    for (var i = start; i < start + leadWindow; i++) {
      final tag = i < chapter.length
          ? chapter[i]
          : (i - chapter.length < next.length ? next[i - chapter.length] : null);
      if (tag == null) break;
      after.add((mood: tag.mood, intensity: tag.intensity));
    }
    final coming = dominantTag(after);
    final (lead, note) = _lead(set, decision.mood, coming);
    return ScoreDecision(
      cue: decision.mood,
      energy: decision.energy,
      changed: decision.changed,
      lead: lead,
      leadNote: note,
    );
  }

  (Lead?, String) _lead(BedSet set, String current,
      ({String mood, double intensity})? coming) {
    if (coming == null) return (null, 'no tags far enough ahead yet');
    final params = mapToMusicParams(coming.mood, coming.intensity, theme);
    final cue = set.cueFor(params.sourceMood, params.intensity);
    if (cue == current) return (null, 'the stretch ahead is still $cue');
    if (!set.measured) return (null, 'this set has no measured distances');
    final apart = set.distanceBetween(current, cue);
    if (apart.timbre < leadThreshold) {
      return (
        null,
        '$cue is ${apart.timbre.toStringAsFixed(2)}x away, '
            'under ${leadThreshold}x'
      );
    }
    final lead = Lead(
      cue: cue,
      energy: params.energy,
      timbre: apart.timbre,
      chroma: apart.chroma,
    );
    return (lead, lead.overlap ? 'leading into $cue' : 'brightness only');
  }

  /// Forget everything; a different book was opened.
  void reset() => selector.reset();
}
