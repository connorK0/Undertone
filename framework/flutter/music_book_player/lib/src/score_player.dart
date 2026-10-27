/// Makes a book's score audible, from the reader's position.
///
/// All the deciding is [ScoreFollower]'s (music_book_core): which cue, how
/// loud, when to change, what to prepare for. This only turns those decisions
/// into sound on flutter_soloud -- the reader app's MusicEngine with the
/// deciding taken out, and with its constants, each of which is measured or
/// argued in SUMMARY.md and repeated here only as far as it explains a number.
///
/// Reading is never gated on the music. With no audio device, or a file that
/// will not load, every call is a no-op and [note] says why.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:music_book_core/music_book_core.dart';

/// A chapter's tags, one per paragraph, null where untagged.
typedef TagSource = Future<List<MoodTag?>> Function(int chapter);

class ScorePlayer extends ChangeNotifier {
  ScorePlayer({
    this.crossfade = const Duration(milliseconds: 2500),
    this.energyFade = const Duration(milliseconds: 1500),
    this.firstFade = const Duration(seconds: 20),
    this.warmupParagraphs = 16,
  });

  /// A change of cue. Long enough that neither bed is a cut, short enough to
  /// belong to the page turn.
  final Duration crossfade;

  /// A change of loudness within one cue: a ramp, no crossfade.
  final Duration energyFade;

  /// The first cue of a session, heard against silence: slow enough that
  /// there is no moment it begins.
  final Duration firstFade;

  /// Paragraphs over which the score comes up from [warmupFloor] --
  /// listening tests found music welcome only once the reader was in.
  final int warmupParagraphs;

  /// The beds sit around -17 dBFS, so this is background by construction.
  static const masterVolume = 0.9;
  static const warmupFloor = 0.45;

  /// A lead voice is a colour under the current bed, not a second piece.
  static const leadGain = 0.25;
  static const leadFade = Duration(seconds: 6);

  static const idleTimeout = Duration(minutes: 12);
  static const idleFade = Duration(seconds: 8);

  /// Energy moves brightness as well as level: across a long stretch on one
  /// cue the mapper's energy is only ~3 dB, but a low-pass sweep is a large
  /// change at constant loudness. Well under Nyquist (beds are 22,050 Hz).
  static const darkestCutoff = 320.0;
  static const brightestCutoff = 5000.0;

  SoLoud? _soloud;
  bool _available = false;

  /// Why there is no sound, if there is none.
  String? get note => _note;
  String? _note;

  bool get available => _available;

  BookScore? _score;
  ScoreFollower? _follower;
  TagSource? _tags;
  final _tagCache = <int, Future<List<MoodTag?>>>{};

  String? _setDirectory;
  BedSet? _set;
  BedSet? get bedSet => _set;

  final _sources = <String, AudioSource>{};
  final _rotation = <String, int>{};
  final _pendingStops = <Timer>[];

  SoundHandle? _handle;
  AudioSource? _playingSource;
  String? _playing;

  /// The cue sounding now, or null.
  String? get playing => _playing;

  String? _leading;
  SoundHandle? _leadHandle;
  AudioSource? _leadSource;
  String? _leadBed;

  /// The cue being prepared for, or null.
  String? get leading => _leading;

  /// The follower's last answer, for an inspector: including why there is,
  /// or is not, a lead.
  ScoreDecision? get lastDecision => _lastDecision;
  ScoreDecision? _lastDecision;

  int _paragraphsRead = 0;
  (int, int)? _lastPosition;
  Timer? _idle;
  bool _dozing = false;
  double _userVolume = 1;
  bool _enabled = true;

  /// Bring up the audio device. Safe to call more than once.
  Future<void> init() async {
    try {
      final soloud = SoLoud.instance;
      if (!soloud.isInitialized) await soloud.init();
      _soloud = soloud;
      _available = true;
      _note = null;
    } catch (error) {
      _available = false;
      _note = 'no audio: $error';
      debugPrint('[score] $_note');
    }
    notifyListeners();
  }

  /// A new book: its generated score, its theme, and where its tags come
  /// from. Starts the warm-up over.
  Future<void> openBook({
    required BookScore score,
    required BookTheme theme,
    required TagSource tags,
  }) async {
    await _teardown();
    _score = score;
    _follower = ScoreFollower(theme: theme);
    _tags = tags;
    _tagCache.clear();
    _paragraphsRead = 0;
    _lastPosition = null;
    notifyListeners();
  }

  /// The reader is on [paragraph] of [chapter]. Call on every movement; the
  /// same position twice is harmless.
  Future<void> onPosition(int chapter, int paragraph) async {
    final score = _score;
    final follower = _follower;
    if (score == null || follower == null) return;

    // A bed set changes under the reader at an arc boundary. Swapped outright
    // rather than crossfaded, as the app does: two arcs' beds are in
    // different keys, and a chapter turn is already a break.
    final directory = await score.directoryFor(chapter);
    if (directory != _setDirectory) await _switchSet(score, chapter, directory);
    final set = _set;
    if (set == null) return;

    if ((chapter, paragraph) != _lastPosition) {
      _lastPosition = (chapter, paragraph);
      if (_paragraphsRead < warmupParagraphs) _paragraphsRead++;
    }
    final decision = follower.observe(
      set: set,
      chapter: await _tagsOf(chapter),
      next: await _tagsOf(chapter + 1),
      paragraph: paragraph,
      now: DateTime.now(),
    );
    _lastDecision = decision;
    if (decision == null) return;
    _wake();
    _touch();
    await _apply(decision);
    await _updateLead(decision);
    notifyListeners();
  }

  /// The reader's own level, 0-1.
  void setVolume(double volume) {
    _userVolume = volume.clamp(0.0, 1.0);
    _reapplyLevel();
  }

  /// Music on or off. Off fades out; on resumes from where the prose is.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      _stopLeadNow();
      _fadeOutCurrent(crossfade);
    } else {
      final at = _lastPosition;
      if (at != null) unawaited(onPosition(at.$1, at.$2));
    }
    notifyListeners();
  }

  /// Level between 0 and 1 of the warm-up ramp: a raised cosine from
  /// [warmupFloor], whose steepest step is under the ~1 dB anyone notices.
  double get warmth {
    if (warmupParagraphs <= 0) return 1;
    final progress = (_paragraphsRead / warmupParagraphs).clamp(0.0, 1.0);
    return warmupFloor +
        (1 - warmupFloor) * (0.5 - 0.5 * math.cos(math.pi * progress));
  }

  // --- Sets and sources ----------------------------------------------------

  Future<void> _switchSet(BookScore score, int chapter, String directory)
  async {
    _stopLeadNow();
    final handle = _handle;
    if (_available && handle != null) await _soloud!.stop(handle);
    _handle = null;
    _playingSource = null;
    _playing = null;
    _sources.clear();
    _rotation.clear();
    if (_available) await _soloud!.disposeAllSources();
    _setDirectory = directory;
    _set = await score.setFor(chapter);
    _follower?.reset();
    if (_set == null) {
      _note = 'no beds generated for chapter ${chapter + 1}';
    }
  }

  Future<List<MoodTag?>> _tagsOf(int chapter) {
    // Only the chapter and its neighbours are kept: a 2,000-chapter book's
    // tags need not all sit in memory.
    _tagCache.removeWhere((c, _) => (c - chapter).abs() > 2);
    return _tagCache[chapter] ??= _tags!(chapter);
  }

  /// The next bed for [cue], advancing its rotation -- once per fade-in, so a
  /// held cue never has its file swapped under it.
  String? _nextBed(String cue) {
    final beds = _set?.variantsOf(cue) ?? const <String>[];
    if (beds.isEmpty) return null;
    final at = _rotation[cue] ?? 0;
    _rotation[cue] = at + 1;
    return beds[at % beds.length];
  }

  Future<AudioSource?> _source(String path) async {
    if (!_available) return null;
    final cached = _sources[path];
    if (cached != null) return cached;
    try {
      final source = await _soloud!.loadFile(path);
      source.filters.biquadFilter.activate();
      _sources[path] = source;
      return source;
    } catch (error) {
      _note = 'could not load $path: $error';
      debugPrint('[score] $_note');
      return null;
    }
  }

  double _gainFor(double energy) =>
      masterVolume * _userVolume * warmth * (0.30 + 0.70 * energy);

  /// Exponential: brightness is heard that way.
  double _cutoffFor(double energy) =>
      darkestCutoff * math.pow(brightestCutoff / darkestCutoff, energy);

  // --- Applying a decision -------------------------------------------------

  Future<void> _apply(ScoreDecision decision) async {
    if (!_available || !_enabled || _dozing) return;
    final gain = _gainFor(decision.energy);

    if (!decision.changed && decision.cue == _playing) {
      // Intensity moved within the cue: ramp level and brightness.
      final handle = _handle;
      final source = _playingSource;
      if (handle != null) _soloud!.fadeVolume(handle, gain, energyFade);
      if (handle != null && source != null) {
        source.filters.biquadFilter
            .frequency(soundHandle: handle)
            .fadeFilterParameter(to: _cutoffFor(decision.energy),
                time: energyFade);
      }
      return;
    }
    if (decision.cue == _playing) return;

    // The change the score has been leading into: bring the lead voice up
    // rather than starting a second copy from its beginning at the exact
    // moment of the change.
    final promoting = _leading == decision.cue && _leadHandle != null;
    final bed = promoting ? _leadBed : _nextBed(decision.cue);
    if (bed == null) return;
    final source = promoting ? _leadSource : await _source(bed);
    if (source == null) return;
    if (!promoting) _stopLead();

    final outgoing = _handle;
    final over = outgoing == null ? firstFade : crossfade;
    final SoundHandle handle;
    if (promoting) {
      handle = _leadHandle!;
      _leading = null;
      _leadHandle = null;
      _leadSource = null;
      _leadBed = null;
    } else {
      handle = _soloud!.play(source, looping: true, volume: 0);
    }
    _soloud!.fadeVolume(handle, gain, over);
    final cutoff = source.filters.biquadFilter.frequency(soundHandle: handle);
    if (promoting) {
      // Already audible, so it sweeps rather than stepping.
      cutoff.fadeFilterParameter(to: _cutoffFor(decision.energy), time: over);
    } else {
      cutoff.value = _cutoffFor(decision.energy);
    }
    if (outgoing != null) {
      _soloud!.fadeVolume(outgoing, 0, over);
      _stopLater(outgoing, over);
    }
    _handle = handle;
    _playingSource = source;
    _playing = decision.cue;
  }

  Future<void> _updateLead(ScoreDecision decision) async {
    if (!_available || !_enabled || _dozing) return;
    final lead = decision.lead;
    if (lead == null) return _stopLead();
    if (_leading == lead.cue) return; // already preparing; do not re-fade
    _stopLead();
    _leading = lead.cue;

    // The brightness sweep happens whatever the tonal distance: it is the
    // current voice moving, so there is nothing to collide with.
    final handle = _handle;
    final source = _playingSource;
    if (handle != null && source != null) {
      source.filters.biquadFilter
          .frequency(soundHandle: handle)
          .fadeFilterParameter(to: _cutoffFor(lead.energy), time: leadFade);
    }
    if (!lead.overlap) return; // tonally too far apart to sound together

    // The bed the change itself would take, so promoting it later is the same
    // sound arriving rather than a different one swapped in.
    final bed = _nextBed(lead.cue);
    final leadSource = bed == null ? null : await _source(bed);
    if (bed == null || leadSource == null) return;
    final voice = _soloud!.play(leadSource, looping: true, volume: 0);
    _soloud!.fadeVolume(voice, _gainFor(lead.energy) * leadGain, leadFade);
    leadSource.filters.biquadFilter.frequency(soundHandle: voice).value =
        _cutoffFor(lead.energy);
    _leadHandle = voice;
    _leadSource = leadSource;
    _leadBed = bed;
  }

  /// Stop preparing, as unremarkably as it began.
  void _stopLead() {
    if (_leading == null) return;
    final voice = _leadHandle;
    if (_available && voice != null) {
      _soloud!.fadeVolume(voice, 0, leadFade);
      _stopLater(voice, leadFade);
    }
    _leading = null;
    _leadHandle = null;
    _leadSource = null;
    _leadBed = null;
  }

  /// Drop the lead at once: for teardown, where a fade would outlive what it
  /// belongs to.
  void _stopLeadNow() {
    final voice = _leadHandle;
    _leading = null;
    _leadHandle = null;
    _leadSource = null;
    _leadBed = null;
    if (_available && voice != null) unawaited(_soloud!.stop(voice));
  }

  void _fadeOutCurrent(Duration over) {
    final handle = _handle;
    if (!_available || handle == null) return;
    _soloud!.fadeVolume(handle, 0, over);
    _stopLater(handle, over);
    _handle = null;
    _playingSource = null;
    _playing = null;
  }

  void _stopLater(SoundHandle handle, Duration after) {
    _pendingStops.add(Timer(after + const Duration(milliseconds: 250), () {
      unawaited(_soloud!.stop(handle));
    }));
  }

  void _reapplyLevel() {
    final handle = _handle;
    final decision = _lastDecision;
    if (!_available || handle == null || decision == null || _dozing) return;
    _soloud!.fadeVolume(handle, _gainFor(decision.energy), energyFade);
  }

  // --- Walking away --------------------------------------------------------

  void _touch() {
    _idle?.cancel();
    if (_enabled) _idle = Timer(idleTimeout, _doze);
  }

  void _doze() {
    final handle = _handle;
    if (!_available || handle == null || _dozing) return;
    _dozing = true;
    _soloud!.fadeVolume(handle, 0, idleFade);
    _pendingStops.add(Timer(idleFade + const Duration(milliseconds: 250), () {
      if (_dozing) _soloud!.setPause(handle, true);
    }));
    notifyListeners();
  }

  void _wake() {
    if (!_dozing) return;
    _dozing = false;
    final handle = _handle;
    final decision = _lastDecision;
    if (_available && handle != null) {
      _soloud!.setPause(handle, false);
      _soloud!.fadeVolume(
          handle, _gainFor(decision?.energy ?? 0.5), energyFade);
    }
  }

  // --- Teardown ------------------------------------------------------------

  Future<void> _teardown() async {
    _idle?.cancel();
    for (final timer in _pendingStops) {
      timer.cancel();
    }
    _pendingStops.clear();
    _stopLeadNow();
    final handle = _handle;
    if (_available && handle != null) await _soloud!.stop(handle);
    _handle = null;
    _playingSource = null;
    _playing = null;
    _sources.clear();
    _rotation.clear();
    if (_available) await _soloud!.disposeAllSources();
    _setDirectory = null;
    _set = null;
    _dozing = false;
  }

  /// The book is closed. Fades out rather than cutting.
  Future<void> closeBook() async {
    // Nothing is left to doze: without this, a closed book's idle timer
    // outlives it by up to twelve minutes.
    _idle?.cancel();
    _idle = null;
    _fadeOutCurrent(crossfade);
    _stopLead();
    _score = null;
    _follower = null;
    _tags = null;
    _tagCache.clear();
    _setDirectory = null;
    _set = null;
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
