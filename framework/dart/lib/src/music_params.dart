import 'tagging.dart';

/// Mood + intensity + book theme -> music parameters.
///
/// Ported from phase0/mapper.py, which is where the mapping was checked against
/// real prose. Pinned to it by test/mapper_parity_test.dart; if you change a
/// number here, change it there and regenerate the fixture.
///
/// The shape follows what an adaptive music API takes -- a genre seed, a mood
/// token, an energy level, a tempo. The local loop engine only reads [mood] and
/// [energy]; the rest is carried so that swapping in a real music API later is
/// a small job. See README for what that means in practice.

/// Each mood owns a tempo range and an energy floor. The paragraph's intensity
/// slides the tempo across the range and lifts energy toward the ceiling; the
/// floor keeps a calm paragraph at intensity 1.0 quieter than a tense one at 0.5.
class MoodParams {
  const MoodParams({
    required this.musicMood,
    required this.bpmLow,
    required this.bpmHigh,
    required this.energy,
    required this.texture,
  });

  final String musicMood;
  final int bpmLow;
  final int bpmHigh;
  final double energy;
  final String texture;
}

const moodParams = <String, MoodParams>{
  'tense': MoodParams(
      musicMood: 'suspense',
      bpmLow: 84,
      bpmHigh: 132,
      energy: 0.70,
      texture: 'pulsing low strings, percussive attacks'),
  'calm': MoodParams(
      musicMood: 'ambient',
      bpmLow: 56,
      bpmHigh: 78,
      energy: 0.20,
      texture: 'sustained pads, wide reverb'),
  'melancholic': MoodParams(
      musicMood: 'melancholy',
      bpmLow: 52,
      bpmHigh: 74,
      energy: 0.30,
      texture: 'solo lead over minor harmony'),
  'triumphant': MoodParams(
      musicMood: 'epic',
      bpmLow: 88,
      bpmHigh: 130,
      energy: 0.85,
      texture: 'brass and full ensemble'),
  'romantic': MoodParams(
      musicMood: 'romantic',
      bpmLow: 64,
      bpmHigh: 92,
      energy: 0.45,
      texture: 'warm strings, close piano'),
  'ominous': MoodParams(
      musicMood: 'dark',
      bpmLow: 58,
      bpmHigh: 86,
      energy: 0.50,
      texture: 'low drones, sparse percussion'),
  'whimsical': MoodParams(
      musicMood: 'playful',
      bpmLow: 96,
      bpmHigh: 138,
      energy: 0.50,
      texture: 'pizzicato strings, light woodwind'),
  'neutral': MoodParams(
      musicMood: 'background',
      bpmLow: 68,
      bpmHigh: 92,
      energy: 0.30,
      texture: 'neutral bed, low profile'),
};

/// What the music engine is asked to play for one paragraph.
class MusicParams {
  const MusicParams({
    required this.genre,
    required this.mood,
    required this.intensity,
    required this.energy,
    required this.bpm,
    required this.instrumentation,
    required this.themeId,
    required this.sourceMood,
  });

  /// From the book theme's genre_seed.
  final String genre;

  /// The mood token a music API would take ('suspense', 'ambient', ...).
  final String mood;

  final double intensity;

  /// Mood floor blended with paragraph intensity. This is what drives volume.
  final double energy;

  final int bpm;
  final String instrumentation;
  final String themeId;

  /// The classifier's mood ('tense', 'calm', ...), before the API-token
  /// rename. The loop library is keyed by this.
  final String sourceMood;

  @override
  String toString() =>
      '$genre / $mood / e${energy.toStringAsFixed(2)} / ${bpm}bpm';
}

/// Python's `round(x, 2)` rounds the *exact* binary value of the double. The
/// obvious `(x * 100).round() / 100` does not: scaling by 100 is itself a
/// rounding step, and it moves values across the boundary. `0.70 * 0.5 + 0.01 *
/// 0.5` is 0.35499999999999998, which Python rounds down to 0.35 -- but
/// multiplied by 100 it lands on exactly 35.5 and rounds up to 0.36.
///
/// `toStringAsFixed` is specified to pick the decimal nearest the exact value,
/// which is what Python does -- except on an exact midpoint, where it goes away
/// from zero and Python goes to even. Midpoints do arise: tense at intensity
/// 0.55 is `0.35 + 0.275`, whose representation errors cancel to exactly 0.625,
/// and Python makes that 0.62 where the string route gives 0.63.
///
/// A true midpoint must be an odd multiple of 1/8 -- (2n+1)/200 is only
/// representable in binary when 25 divides 2n+1, leaving .125, .375, .625 and
/// .875. Detect that by scaling by 8, which is exact because it only shifts the
/// exponent. Scaling by 100 or 200 would not work: it rounds, and
/// 0.35499999999999998 * 200 lands on exactly 71.0, which is indistinguishable
/// from a real midpoint.
double _round2(double value) {
  final eighths = value * 8;
  if (eighths == eighths.roundToDouble() && eighths.toInt().isOdd) {
    final lower = (value * 100).floor();
    return (lower.isEven ? lower : lower + 1) / 100;
  }
  return double.parse(value.toStringAsFixed(2));
}

/// Python's round() to an integer is banker's rounding; Dart's is
/// half-away-from-zero, and they genuinely differ here -- calm at intensity
/// 0.75 gives exactly 72.5 bpm, which Python makes 72 and Dart would make 73.
int _roundHalfEven(double value) {
  final floor = value.floorToDouble();
  final fraction = value - floor;
  if (fraction > 0.5) return floor.toInt() + 1;
  if (fraction < 0.5) return floor.toInt();
  return (floor.toInt().isEven ? floor : floor + 1).toInt();
}

MusicParams mapToMusicParams(String mood, double intensity, BookTheme theme) {
  final params = moodParams[mood];
  if (params == null) throw ArgumentError('unknown mood: $mood');
  return MusicParams(
    genre: theme.genreSeed,
    mood: params.musicMood,
    intensity: _round2(intensity),
    energy: _round2(params.energy * 0.5 + intensity * 0.5),
    bpm: _roundHalfEven(
        params.bpmLow + (params.bpmHigh - params.bpmLow) * intensity),
    instrumentation: '${theme.instrumentation}; ${params.texture}',
    themeId: theme.themeId,
    sourceMood: mood,
  );
}
