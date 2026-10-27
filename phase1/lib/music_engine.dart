import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'cue_selector.dart' as cue_selector;
import 'cue_selector.dart';
import 'experiment_treatments.dart';
import 'mood_pipeline.dart';
import 'music_library.dart';
import 'music_params.dart';

/// One cue change that actually happened, kept so the inspector can show what
/// the score did rather than only what it is doing.
class CueEvent {
  const CueEvent({
    required this.at,
    required this.paragraph,
    required this.cue,
    required this.sourceMood,
    required this.intensity,
    required this.energy,
  });

  final DateTime at;
  final int paragraph;

  /// The key that was played: a mood, or a treatment under the experiment.
  final String cue;

  /// The classifier's mood at the paragraph that triggered it. Under the
  /// experiment library this differs from [cue], which is the whole point.
  final String sourceMood;

  final double intensity;
  final double energy;
}

/// Plays one looping bed per mood and crossfades between them.
///
/// Everything here is best-effort. If the audio device is missing -- a headless
/// test run, a machine with no output -- [start] records why and every later
/// call becomes a no-op. Reading is never gated on the music, exactly as it is
/// never gated on the classifier.
class MusicEngine extends ChangeNotifier {
  MusicEngine({
    CueSelector? selector,
    this.crossfade = const Duration(milliseconds: 2500),
    this.energyFade = const Duration(milliseconds: 1500),
    this.firstFade = const Duration(seconds: 20),
    this.warmupParagraphs = defaultWarmupParagraphs,
  }) : selector = selector ?? CueSelector();

  /// Decides *what* should play; this class only makes it audible.
  final CueSelector selector;

  /// How long a mood change takes. Long enough that neither bed is a cut,
  /// short enough that the change still reads as belonging to the page turn.
  final Duration crossfade;

  /// How long the *first* cue of a reading session takes to arrive.
  ///
  /// Not [crossfade]. A crossfade is heard against music that is already
  /// there, so 2.5s is plenty; the first cue is heard against silence, in the
  /// same seconds the reader is still deciding to start. At 2.5s that reads as
  /// music being switched on. Twenty seconds is slow enough that there is no
  /// moment it begins, which is the point -- the reader should look up two
  /// pages later and find it already playing.
  final Duration firstFade;

  /// How long a loudness change within one mood takes. No crossfade, just a
  /// ramp, so intensity moves without announcing itself.
  final Duration energyFade;

  /// The loops sit around -17 dBFS, so this is a background level by
  /// construction. The reader's own volume multiplies it.
  static const masterVolume = 0.9;

  /// How long an audition takes to arrive or leave. Short: this is a listening
  /// tool, and waiting 2.5 seconds between beds you are trying to compare is
  /// the crossfade getting in the way of the comparison.
  static const auditionFade = Duration(milliseconds: 400);

  /// The low-pass is **bypassed** while auditioning, rather than opened wide.
  ///
  /// It used to be opened wide: the cutoff went to 12 kHz, on the reasoning
  /// that the beds are 32 kHz so that sits clear of Nyquist and out of the
  /// way. The beds are **22,050 Hz**. Nyquist is 11,025, so 12 kHz was *above*
  /// it, and a resonant biquad asked for a cutoff above Nyquist produces
  /// invalid coefficients and passes nothing. Every audition was silent, on
  /// every set, from the day the feature shipped.
  ///
  /// It hid well. The voice is real and reports its full volume, so the engine
  /// believed it was playing and said so; only the audio was missing. The
  /// score never met it because [_cutoffFor] tops out at [brightestCutoff],
  /// well under Nyquist, so the one path that pushed the filter past it was
  /// the one nobody could test without ears.
  ///
  /// Bypassing is also what was actually wanted -- "the filter out of the way"
  /// -- and unlike a frequency it cannot be wrong at a sample rate nobody
  /// checked.
  ///
  /// Not exactly zero, and the reason is in flutter_soloud, not here. Its
  /// C++ getter refuses any parameter that fails `isnormal()`, and zero is
  /// not a normal float, so a wet of 0.0 can be *set* -- the declared range
  /// starts at 0 -- but never read back: the get throws. The app never reads
  /// it, so the audition worked; the integration test does, and could not
  /// confirm what it heard. A thousandth is -60 dB of low-passed signal under
  /// the dry one, inaudible, and it round-trips.
  static const auditionWet = 0.001;

  // --- Leading into a change (§8.9) --------------------------------------
  //
  // On the test book, chapter 2 moves between four cues, and the change at
  // its first paragraph is the starkest in the whole chapter -- 1.50x the
  // palette's average, measured.
  // A 2.5-second crossfade is not long enough to make that anything but a
  // cut. So when a big change is coming, the current page prepares for it
  // rather than the next page easing into it: by the time the score moves,
  // the ear has already been going that way.

  /// The three rules about *when* to prepare live in cue_selector.dart with
  /// [cueWindow], so that anything reasoning about what the score would do can
  /// have them without importing an audio engine -- tool/allocate.dart --leads
  /// replays a whole arc against exactly these numbers.

  /// The lead voice's level, as a fraction of the score's own.
  ///
  /// Quiet enough to be a colour under the current bed rather than a second
  /// piece of music arriving early.
  static const leadGain = 0.25;

  /// How long the lead voice takes to arrive, and to leave when the reader
  /// turns out not to be going where the tags said.
  static const leadFade = Duration(seconds: 6);

  /// Where the score sits at the very start of a reading session, as a
  /// fraction of its settled level.
  ///
  /// From listening tests, which are the only evidence there is: the music
  /// was welcome *once the reader was inside the book*, and before that it
  /// was something else asking for attention. Immersion is not instant and
  /// the score should not behave as though it were.
  ///
  /// 0.45 is 20*log10(1/0.45) = **6.9 dB** below settled -- subjectively about
  /// half as loud, plainly further back, still unmistakably there. Silence for
  /// the first pages would be a different design (and a worse one: the reader
  /// then hears the music *start*, which is the thing being avoided).
  static const warmupFloor = 0.45;

  /// Paragraphs of reading over which the score comes up to full level.
  ///
  /// Counted in paragraphs, not seconds, because immersion is a function of
  /// reading rather than of elapsed time -- a reader who opens a book and
  /// walks away should not come back to a score at full level. (Walking away
  /// is separately handled by [idleTimeout], but the ramp should not have been
  /// climbing meanwhile either.)
  ///
  /// Sixteen is a chosen value, not a measured one: at a typical 20-40s per
  /// paragraph it is the first five to ten minutes. What *is* derived is that
  /// the climb cannot be heard as it happens. The steepest single step of the
  /// raised cosine below is
  ///
  ///     (1 - 0.45) * 0.5 * pi/16 = 0.054   at the halfway point,
  ///
  /// which against a warmth of 0.725 there is 20*log10(0.779/0.725) = 0.62 dB,
  /// spread over an [energyFade]. Well under the ~1 dB that is noticeable on a
  /// sustained sound, so the reader gets the 6.9 dB without ever hearing a
  /// change. Raising this makes each step smaller, never larger.
  final int warmupParagraphs;

  /// The value [warmupParagraphs] takes unless a test overrides it. Named so
  /// that the settings dialog can quote it rather than repeat it.
  static const defaultWarmupParagraphs = 16;

  /// How long without a page turn before the score fades out.
  ///
  /// A page takes one to three minutes, and a slow reader on a dense page
  /// perhaps five to eight; twelve gives that room and still catches someone
  /// who has walked away. The fade is deliberately slow -- a score that
  /// vanishes abruptly is more noticeable than one that is still there.
  static const idleTimeout = Duration(minutes: 12);
  static const idleFade = Duration(seconds: 8);

  /// Intensity moves the bed's brightness, not just its volume.
  ///
  /// Volume alone cannot carry it. Across the Carol's 56-paragraph stretch on
  /// one cue the classifier's intensity swings 0.30 to 1.00, and the mapper
  /// turns that whole range into **3.1 dB** -- near enough inaudible, which is
  /// why a long stretch sounds like a held chord. A low-pass sweep is a large
  /// perceptual change at constant loudness, so it gives the score something
  /// to do on the axis that actually moves paragraph to paragraph.
  ///
  /// The beds carry content from 82 Hz to about 1 kHz, so closing to 320 Hz
  /// leaves little but the fundamentals, and 5 kHz is fully open.
  static const darkestCutoff = 320.0;
  static const brightestCutoff = 5000.0;

  /// Paragraphs the cue is chosen from, starting at the reader's own.
  ///
  /// Four, by measurement rather than taste. Against three independent
  /// labellings of the same eighteen paragraphs of Dracula, a four-paragraph
  /// window cuts cue changes from 13 to about 10 while costing nothing in
  /// agreement, and it sits well inside the pipeline's eight-paragraph prefetch
  /// window so the tags it wants have already been asked for. Wider keeps
  /// trimming changes but starts losing agreement past six, and adds lag.
  ///
  /// What it does not buy is a reproducible score -- see [dominantTag].
  static const cueWindow = cue_selector.cueWindow;

  SoLoud? _soloud;
  LoopLibrary? _library;
  final _sources = <String, AudioSource>{};

  /// How many times each cue has been faded into, so the next entry takes the
  /// next bed. Round-robin rather than random: random repeats itself, and the
  /// whole point is to put as much distance as possible between two plays of
  /// one file.
  final _rotation = <String, int>{};
  final _pendingStops = <Timer>[];

  MoodPipeline? _pipeline;
  VoidCallback? _listener;

  SoundHandle? _handle;

  /// The source behind [_handle]. Filters are addressed through the source, so
  /// driving the cutoff needs both it and the handle.
  AudioSource? _playingSource;
  String? _playing;
  MusicParams? _current;
  bool _available = false;
  bool _open = false;
  String? _note;

  double _userVolume = 1;
  bool _enabled = true;
  bool _dozing = false;
  Timer? _idleTimer;

  int _paragraphsRead = 0;
  int? _lastParagraph;

  /// Paragraphs the reader has moved through this session. Drives [warmth]
  /// and nothing else.
  int get paragraphsRead => _paragraphsRead;

  /// The warm-up multiplier on the score's level: [warmupFloor] at the start
  /// of a session, 1 once [warmupParagraphs] have gone by.
  ///
  /// A raised cosine rather than a straight line, so the ramp has no corner at
  /// either end. A linear ramp arrives at full level with its slope intact,
  /// and the moment it stops climbing is itself an event -- small, but this
  /// whole mechanism exists to avoid exactly that kind of small event.
  double get warmth {
    if (warmupParagraphs <= 0) return 1;
    final progress = (_paragraphsRead / warmupParagraphs).clamp(0.0, 1.0);
    return warmupFloor +
        (1 - warmupFloor) * (0.5 - 0.5 * math.cos(math.pi * progress));
  }

  /// Begin a reading session: the score starts back at [warmupFloor].
  ///
  /// Called when a *book* is opened, not a chapter. Preparation closes the
  /// engine between chapters, so tying the ramp to that would dip the level
  /// every time the reader turned a chapter -- by which point they are as
  /// immersed as they are going to get, and a dip would read as the volume
  /// drifting on its own.
  void restartWarmup() {
    _paragraphsRead = 0;
    _lastParagraph = null;
  }

  /// The reader's volume, 0 to 1, on top of [masterVolume].
  double get userVolume => _userVolume;
  set userVolume(double value) {
    _userVolume = value.clamp(0, 1);
    _reapplyLevel();
    notifyListeners();
  }

  /// Whether music plays at all.
  bool get enabled => _enabled;
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _idleTimer?.cancel();
      _fadeOutCurrent(energyFade);
    } else {
      _listener?.call();
    }
    notifyListeners();
  }

  /// True while the score has faded out because nobody has turned a page.
  bool get dozing => _dozing;

  /// Whether audio came up. False means silent, not broken.
  bool get available => _available;

  /// Why audio is unavailable, when it is.
  String? get note => _note;

  /// The mood currently sounding.
  String? get playing => _playing;

  /// The full parameters behind the current cue, for the banner.
  MusicParams? get current => _current;

  /// Which loop library is in use, once loaded.
  MusicLibrary? get library => _library?.library;

  /// Where the fader has got to on the cue that is sounding. Climbs from 0
  /// across a crossfade, which is how a test can tell a fade from a cut.
  double? get playingVolume => _available && _handle != null
      ? _soloud!.getVolume(_handle!)
      : null;

  /// Beds audible right now: two while a crossfade is in flight, one after.
  int get voices => _available ? _soloud!.getActiveVoiceCount() : 0;

  /// Cue changes since the engine started, the first fade-in included. The
  /// number that says whether the score is tracking the prose or thrashing.
  int get crossfades => _crossfades;
  int _crossfades = 0;

  /// How many cue changes to remember. Long enough to cover a reading session's
  /// worth of them without growing without bound.
  static const historyLimit = 60;

  final _history = <CueEvent>[];

  /// Cue changes so far, newest first.
  List<CueEvent> get history => List.unmodifiable(_history.reversed);

  List<({String mood, double intensity})> _window = const [];
  ({String mood, double intensity})? _dominant;
  int _windowStart = 0;

  /// The paragraphs the last decision was actually taken over, nearest first,
  /// and what they came to. Recorded rather than recomputed on demand, so the
  /// inspector shows what drove the cue instead of what would drive it now.
  List<({String mood, double intensity})> get window => _window;
  ({String mood, double intensity})? get dominant => _dominant;

  /// The paragraph [window] starts at.
  int get windowStart => _windowStart;

  /// The manifest row behind a cue: how it was made and what it is meant to
  /// be. Takes a key rather than reading [playing] so the inspector can
  /// describe the cue the score *chose* -- which is knowable even when audio
  /// is off, unavailable, or dozing, and is exactly when you want to know.
  Map<String, dynamic> detailsFor(String? cue) =>
      cue == null ? const {} : (_library?.details[cue] ?? const {});

  /// The file behind a cue, on the same terms.
  ///
  /// The cue's first bed. A cue with several is *playing* one of them, which
  /// [playingBed] reports; this answers the inspector's question, which is
  /// which cue was chosen and what it is made of, not which take is in the air.
  String? assetFor(String? cue) => cue == null ? null : _library?.assets[cue];

  /// How many beds the current cue owns, and which of them is sounding. 1 and 0
  /// for a cue with a single bed, which is every cue of an unallocated set.
  int get playingBedCount =>
      _playing == null ? 0 : (_library?.variantsOf(_playing!).length ?? 0);
  String? get playingBed => _playingBed;
  String? _playingBed;

  /// Which take of the current cue is sounding, counting from 1. Zero when
  /// nothing is, so a caller can say "3 of 8" without recomputing the list.
  int get playingBedNumber {
    final cue = _playing;
    final bed = _playingBed;
    if (cue == null || bed == null) return 0;
    return (_library?.variantsOf(cue).indexOf(bed) ?? -1) + 1;
  }

  Map<String, dynamic> get playingDetails => detailsFor(_playing);
  String? get playingAsset => assetFor(_playing);

  /// The loaded library's own manifest fields, minus the loops.
  Map<String, dynamic> get libraryManifest => _library?.manifest ?? const {};

  /// Bring up the audio device and read the loop manifest.
  Future<void> start() async {
    try {
      final soloud = SoLoud.instance;
      if (!soloud.isInitialized) await soloud.init();
      _library = await LoopLibrary.load();
      _soloud = soloud;
      _available = true;
      // The experiment library is keyed by treatment, not by mood, so the set
      // of cues it must cover is a different one.
      final missing = _library!.missing(
        _library!.library == MusicLibrary.experiment
            ? treatmentKeys
            : moodParams.keys,
      );
      debugPrint('[music] ${_library!.library.name} library ready'
          '${missing.isEmpty ? '' : ', no loop for ${missing.join(', ')}'}');
    } catch (error) {
      _available = false;
      _note = '$error';
      debugPrint('[music] audio unavailable, reading on in silence: $error');
    }
    notifyListeners();
  }

  /// Follow a pipeline: every tag it produces for the reader's paragraph is an
  /// observation. The pipeline notifies on batches landing as well as on
  /// movement, which is why [CueSelector] counts paragraphs rather than calls.
  void attach(MoodPipeline pipeline) {
    detach();
    _pipeline = pipeline;
    _listener = () {
      // Tags land during preparation too, before the reader has seen a word.
      // Music belongs to the open book, so stay silent until [open].
      if (!_open) return;
      final theme = pipeline.theme;
      if (theme == null) return;

      // Score the stretch the reader is in, not the single paragraph under
      // their eye -- see dominantTag. The window stops at the first paragraph
      // the classifier has not reached yet rather than skipping over it.
      final window = <({String mood, double intensity})>[];
      for (var i = pipeline.position; i < pipeline.position + cueWindow; i++) {
        final tag = pipeline.tagAt(i);
        if (tag == null) break;
        window.add((mood: tag.mood, intensity: tag.intensity));
      }
      final dominant = dominantTag(window);
      _window = window;
      _dominant = dominant;
      _windowStart = pipeline.position;

      // What the paragraphs *after* the window are asking for. Read only to
      // prepare for a change, never to make one: the cue is still decided by
      // the window above and the selector's confirmations.
      final after = <({String mood, double intensity})>[];
      for (var i = pipeline.position + cueWindow;
          i < pipeline.position + cueWindow + leadWindow;
          i++) {
        // Across the chapter boundary, unlike the window above: a chapter
        // turn was the one change nothing could prepare for.
        final tag = pipeline.tagAcross(i);
        if (tag == null) break;
        after.add((mood: tag.mood, intensity: tag.intensity));
      }
      final coming = dominantTag(after);
      _coming = coming == null
          ? null
          : mapToMusicParams(coming.mood, coming.intensity, theme);

      if (dominant == null) return;

      observe(
        paragraphIndex: pipeline.position,
        params: mapToMusicParams(dominant.mood, dominant.intensity, theme),
      );
    };
    pipeline.addListener(_listener!);
  }

  /// The reader is on screen: start playing, fading in from silence.
  void open() {
    _open = true;
    _touch();
    _listener?.call();
  }

  void detach() {
    if (_pipeline != null && _listener != null) {
      _pipeline!.removeListener(_listener!);
    }
    _pipeline = null;
    _listener = null;
  }

  /// One observation of where the reader is and what it was tagged.
  Future<void> observe({
    required int paragraphIndex,
    required MusicParams params,
  }) async {
    final cueKey =
        cueKeyFor(mood: params.sourceMood, intensity: params.intensity);

    // The pipeline notifies on every batch that lands, not only on movement,
    // so the same paragraph arrives many times; counting those would run the
    // warm-up out while the reader sat on page one.
    if (paragraphIndex != _lastParagraph) {
      _lastParagraph = paragraphIndex;
      if (_paragraphsRead < warmupParagraphs) _paragraphsRead++;
    }

    final decision = selector.observe(
      paragraphIndex: paragraphIndex,
      mood: cueKey,
      energy: params.energy,
      now: DateTime.now(),
    );
    if (decision == null) return;
    // A page turned, so the reader is still here.
    _wake();
    _touch();
    if (decision.changed || _current == null) _current = params;
    if (decision.changed) {
      _history.add(CueEvent(
        at: DateTime.now(),
        paragraph: paragraphIndex,
        cue: decision.mood,
        sourceMood: params.sourceMood,
        intensity: params.intensity,
        energy: decision.energy,
      ));
      if (_history.length > historyLimit) _history.removeAt(0);
    }
    notifyListeners();
    await _apply(decision);
    await _updateLead(_coming == null
        ? null
        : cueKeyFor(
            mood: _coming!.sourceMood, intensity: _coming!.intensity));
  }

  /// Which loop a tag will ask for, given the library that is loaded.
  ///
  /// EXPERIMENT (Phase 5, Task 0). Under the experiment library the cue key is
  /// a treatment of one theme chosen by intensity rather than a mood. Nothing
  /// downstream changes: the selector, the crossfade and the filter sweep all
  /// treat the key as opaque, which is the point -- if treatments turn out to
  /// be worth building properly, this is the shape it takes. Delete with
  /// lib/experiment_treatments.dart.
  String cueKeyFor({required String mood, required double intensity}) {
    final library = _library;
    if (library == null) return mood;
    if (library.library == MusicLibrary.experiment) {
      return treatmentFor(intensity);
    }
    // Otherwise the loaded set decides its own vocabulary: a mood-keyed set
    // asks for the mood, a banded one for the mood and its intensity band.
    // Nothing downstream changes either way -- the key is opaque to the
    // selector, the crossfade and the filter sweep alike.
    return library.cueFor(mood, intensity);
  }

  /// Load a cue's loop before it is needed, so opening a book does not start
  /// with a gap while a file is decoded.
  ///
  /// The first bed of the cue, and deliberately without advancing the rotation:
  /// preloading is a guess about what might be wanted, and a guess should not
  /// change which bed the reader actually gets.
  Future<void> preload(String cue) async {
    final first = _library?.variantsOf(cue).firstOrNull;
    if (first != null) await _source(first);
  }

  /// The next bed for [cue], advancing its rotation.
  ///
  /// Called once per fade-in rather than once per paragraph: the selector holds
  /// a cue for as long as the prose stays in it, and swapping the file
  /// underneath a held cue would be a cut in the middle of a scene.
  String? _nextBed(String cue) {
    final beds = _library?.variantsOf(cue) ?? const [];
    if (beds.isEmpty) {
      debugPrint('[music] no loop for "$cue" in ${_library?.library.name}');
      return null;
    }
    final at = _rotation[cue] ?? 0;
    _rotation[cue] = at + 1;
    return beds[at % beds.length];
  }

  Future<AudioSource?> _source(String asset) async {
    if (!_available) return null;
    final cached = _sources[asset];
    if (cached != null) return cached;
    try {
      // Generated beds are written per book at import, so they are real files
      // under the app's support directory rather than bundled assets.
      final source = _library!.fromFiles
          ? await _soloud!.loadFile(asset)
          : await _soloud!.loadAsset(asset);
      // Activated once per source, before it is ever played. Its defaults are
      // already a low-pass (type 0) with gentle resonance; only the cutoff is
      // driven, per playing voice.
      source.filters.biquadFilter.activate();
      _sources[asset] = source;
      return source;
    } catch (error) {
      debugPrint('[music] could not load $asset: $error');
      return null;
    }
  }

  double _gainFor(double energy) =>
      masterVolume * _userVolume * warmth * (0.30 + 0.70 * energy);

  void _reapplyLevel() {
    if (!_available || !_enabled || _dozing) return;
    final handle = _handle;
    if (handle != null) {
      _soloud!.fadeVolume(handle, _gainFor(selector.energy), energyFade);
    }
  }

  void _fadeOutCurrent(Duration over) {
    final handle = _handle;
    if (!_available || handle == null) return;
    _soloud!.fadeVolume(handle, 0, over);
    _pendingStops.add(Timer(over + const Duration(milliseconds: 250), () {
      unawaited(_soloud!.stop(handle));
    }));
    _handle = null;
    _playingSource = null;
    _playing = null;
  }

  /// Nobody has turned a page for [idleTimeout]. Fade out and pause, keeping
  /// the cue so that coming back is instant rather than another cold start.
  void _doze() {
    final handle = _handle;
    if (!_available || handle == null || _dozing) return;
    _dozing = true;
    _soloud!.fadeVolume(handle, 0, idleFade);
    _pendingStops.add(Timer(idleFade + const Duration(milliseconds: 250), () {
      if (_dozing) _soloud!.setPause(handle, true);
    }));
    debugPrint('[music] no page turn for ${idleTimeout.inMinutes}m, fading out');
    notifyListeners();
  }

  void _wake() {
    if (!_dozing) return;
    _dozing = false;
    final handle = _handle;
    if (_available && handle != null) {
      _soloud!.setPause(handle, false);
      _soloud!.fadeVolume(handle, _gainFor(selector.energy), energyFade);
    }
    debugPrint('[music] reading resumed, fading back in');
    notifyListeners();
  }

  void _touch() {
    _idleTimer?.cancel();
    if (_open && _enabled) _idleTimer = Timer(idleTimeout, _doze);
  }

  /// Which book's generated beds are loaded, when [MusicLibrary.perBook] is in
  /// use. Kept so opening a second book reloads rather than playing the first
  /// book's music under it.
  String? _bookId;
  String? get bookId => _bookId;

  /// Which arc of that book is loaded. Always 0 for a whole-book set.
  int _arc = 0;
  int get arc => _arc;

  /// A bed set to play in place of the one the chapter asks for, or null to
  /// follow the book. For comparing arcs by ear: the same prose under another
  /// arc's beds. The score decides exactly as it would; only which files it
  /// plays changes, and a cue the pinned set lacks falls back as it does
  /// anywhere. Not saved, and opening another book clears it.
  int? get pinnedSet => _pinnedSet;
  int? _pinnedSet;

  /// The pin the loaded library was loaded under, and the chapter it was
  /// asked for -- which [pinSet] needs to reload in place.
  int? _loadedPin;
  int _libraryChapter = 0;

  /// Play [set]'s beds whatever chapter is open, or follow the book again
  /// with null. Stops an audition first: it is a bed of the set being left.
  Future<void> pinSet(int? set) async {
    if (set == _pinnedSet) return;
    _pinnedSet = set;
    if (_auditioning != null) await stopAudition();
    final book = _bookId;
    if (book != null) {
      await useLibrary(MusicLibrary.perBook,
          bookId: book, chapter: _libraryChapter);
    }
    notifyListeners();
  }

  /// Every cue the loaded set has, and the beds each owns.
  ///
  /// For auditioning: hearing a palette should not require reading for half an
  /// hour and hoping the prose goes somewhere that reaches the cue you wanted.
  Map<String, List<String>> get beds => _library?.variants ?? const {};

  /// The bed being auditioned, as `cue` and one-based take, or null.
  ({String cue, int take})? get auditioning => _auditioning;
  ({String cue, int take})? _auditioning;

  /// Why the last audition made no sound, or null if it played.
  ///
  /// Every way [audition] can decline used to be a silent `return`. That is
  /// the wrong failure for a debug tool: the panel is where you go to find out
  /// why the music is doing something, so it has to be able to say why it is
  /// doing nothing. Reported in the panel rather than only the console,
  /// because the reader auditioning a palette is not watching a console.
  String? get auditionProblem => _auditionProblem;
  String? _auditionProblem;

  void _failAudition(String why) {
    _auditionProblem = why;
    debugPrint('[music] audition did nothing: $why');
    notifyListeners();
  }

  /// What the paragraphs past the scoring window are asking for, if anything.
  MusicParams? _coming;

  /// The cue the score is preparing for, or null when it is not preparing.
  ///
  /// This is never the cue that is *playing*: leading in deliberately does not
  /// touch [CueSelector], which still decides when the score actually moves.
  /// Preparing for a change and making it are different things, and confusing
  /// them would reintroduce the lurching the confirmation rule prevents.
  String? get leading => _leading;
  String? _leading;
  SoundHandle? _leadHandle;
  AudioSource? _leadSource;
  String? _leadBed;

  /// Why the score is, or is not, preparing for a change.
  ///
  /// "nothing" covered four different situations -- no tags far enough ahead,
  /// nothing playing to lead *from*, the same cue continuing, and a change too
  /// small to bother with -- and two of those were bugs that looked exactly
  /// like the feature working. Naming which one costs a string.
  String get leadNote => _leadNote;
  String _leadNote = 'nothing ahead yet';

  /// Whether the lead is a second voice or only a brightness sweep -- see
  /// [leadChromaCeiling]. Shown in the inspector, because "it is preparing but
  /// you will not hear a second bed" is otherwise indistinguishable from a bug.
  bool get leadingAudibly => _leadHandle != null;

  /// Prepare for a change that has not been decided yet.
  ///
  /// Called after every observation. Cheap when nothing is coming, which is
  /// almost always: the distance lookup is a map read.
  Future<void> _updateLead(String? coming) async {
    if (!_available || !_enabled || _auditioning != null || _dozing) {
      _leadNote = _auditioning != null ? 'not while auditioning' : 'not now';
      return;
    }
    final current = _playing;
    if (coming == null) {
      _leadNote = 'no tags far enough ahead yet';
      return _stopLead();
    }
    if (current == null) {
      _leadNote = 'nothing playing to lead from';
      return _stopLead();
    }
    if (coming == current) {
      _leadNote = 'the stretch ahead is still $coming';
      return _stopLead();
    }
    final apart = _library?.distanceBetween(current, coming);
    if (apart == null) {
      _leadNote = 'this set has no measured distances';
      return _stopLead();
    }
    if (apart.timbre < leadThreshold) {
      _leadNote = '$coming is ${apart.timbre.toStringAsFixed(2)}x away, '
          'under ${leadThreshold}x';
      return _stopLead();
    }
    // Already preparing for this one. Re-entering would restart the fade and
    // make the lead pulse once per paragraph.
    if (_leading == coming) return;

    await _stopLead();
    _leading = coming;

    // The brightness sweep happens whatever the tonal distance: it is the
    // current voice moving, so there is nothing to collide with.
    final handle = _handle;
    final source = _playingSource;
    final energy = _coming?.energy;
    if (handle != null && source != null && energy != null) {
      source.filters.biquadFilter
          .frequency(soundHandle: handle)
          .fadeFilterParameter(to: _cutoffFor(energy), time: leadFade);
    }

    if (apart.chroma > leadChromaCeiling) {
      _leadNote = 'brightness only';
      debugPrint('[music] leading into $coming by brightness only '
          '(${apart.timbre.toStringAsFixed(2)}x apart, tonally '
          '${apart.chroma.toStringAsFixed(2)}x -- too far to overlap)');
      notifyListeners();
      return;
    }

    // Take the bed the change itself would take, so promoting it later is the
    // same sound arriving rather than a different one swapped in.
    final bed = _nextBed(coming);
    final leadSource = bed == null ? null : await _source(bed);
    if (bed == null || leadSource == null) {
      _leadNote = 'no bed to lead with';
      notifyListeners();
      return;
    }
    final lead = _soloud!.play(leadSource, looping: true, volume: 0);
    _soloud!.fadeVolume(lead, _gainFor(energy ?? 0.5) * leadGain, leadFade);
    leadSource.filters.biquadFilter.frequency(soundHandle: lead).value =
        _cutoffFor(energy ?? 0.5);
    _leadHandle = lead;
    _leadSource = leadSource;
    _leadBed = bed;
    _leadNote = 'under the current bed';
    debugPrint('[music] leading into $coming under $current '
        '(${apart.timbre.toStringAsFixed(2)}x apart) '
        'at ${(leadGain * 100).round()}%');
    notifyListeners();
  }

  /// Stop preparing: either the change arrived, or it stopped coming.
  ///
  /// The reader is allowed to not go where the tags pointed -- they skim back,
  /// or the selector never confirms. Retreating has to be as unremarkable as
  /// arriving, or the score gains textures that swell and recede for no reason
  /// the reader can perceive, which is worse than the stark change.
  Future<void> _stopLead() async {
    if (_leading == null) return;
    final lead = _leadHandle;
    if (lead != null) {
      _soloud!.fadeVolume(lead, 0, leadFade);
      _pendingStops.add(Timer(leadFade + const Duration(milliseconds: 250), () {
        unawaited(_soloud!.stop(lead));
      }));
      debugPrint('[music] stopped leading into $_leading');
    }
    _leading = null;
    _leadHandle = null;
    _leadSource = null;
    _leadBed = null;
    notifyListeners();
  }

  /// Drop the lead voice at once, without the fade.
  ///
  /// For teardown, where fading would outlive what the fade belongs to: a
  /// library swap is about to free the source the lead is playing, and
  /// [close] ends the chapter the preparation was for. [_stopLead] is the one
  /// to use while reading continues.
  void _dropLead() {
    final lead = _leadHandle;
    _leading = null;
    _leadHandle = null;
    _leadSource = null;
    _leadBed = null;
    _coming = null;
    if (_available && lead != null) unawaited(_soloud!.stop(lead));
  }

  /// Play one bed on its own, ignoring the score.
  ///
  /// Deliberately not what the score would do: full level rather than the
  /// warm-up ramp and energy scaling, and the low-pass wide open rather than
  /// tracking intensity. The question audition answers is "what does this bed
  /// sound like", and the shaping would be answering a different one.
  ///
  /// The score keeps being computed while this holds -- [observe] still runs,
  /// the selector still moves -- it simply does not touch the audio. So
  /// [stopAudition] picks up wherever the prose has got to rather than
  /// resuming something stale.
  Future<void> audition(String cue, int take) async {
    _auditionProblem = null;
    if (!_available) return _failAudition('no audio device');
    final beds = _library?.variantsOf(cue) ?? const [];
    if (beds.isEmpty) return _failAudition('the loaded set has no $cue');
    if (take < 1 || take > beds.length) {
      return _failAudition('$cue has ${beds.length} take(s), not $take');
    }
    final source = await _source(beds[take - 1]);
    if (source == null) return _failAudition('could not load ${beds[take - 1]}');

    // A tap is the reader saying they are still here. Without this the idle
    // timer keeps running against the last *page turn*, so working through a
    // palette -- which is exactly sitting on one page for a long time -- dozes
    // mid-session and fades out what is being auditioned.
    _touch();
    _fadeOutCurrent(auditionFade);
    _auditioning = (cue: cue, take: take);
    // Straight in at full level, rather than starting silent and fading up
    // like the score does. The score has to fade: it is crossfading against a
    // bed that is still sounding, and arriving at full volume would be the cut
    // the whole design avoids. An audition has nothing to cross with, so the
    // fade buys nothing -- and starting at zero makes the sound depend on a
    // fade actually running, which is one more thing between a tap and a
    // noise. Fading out on the way *out* still matters and still happens.
    final level = masterVolume * _userVolume;
    final handle = _soloud!.play(source, looping: true, volume: level);
    // Guarded because a filter that will not take a parameter must not leave a
    // voice playing that nothing holds the handle to: the throw used to escape
    // before _handle was assigned, so the bed became unstoppable.
    try {
      source.filters.biquadFilter.wet(soundHandle: handle).value = auditionWet;
    } catch (error) {
      debugPrint('[music] audition filter refused: $error');
    }
    _handle = handle;
    _playingSource = source;
    _playing = cue;
    _playingBed = beds[take - 1];
    // Started -- but is it making a noise? Reading the level back separates
    // "the tap did nothing" from "the tap worked and the voice is silent",
    // which are the same thing to a listener and completely different bugs.
    // Both the reader's own volume and a voice that failed to take its level
    // land here.
    final actual = playingVolume;
    if (actual == null || actual <= 0.0001) {
      _auditionProblem = 'started $cue take $take, but the voice is at '
          '${actual?.toStringAsFixed(3) ?? 'no handle'} '
          '(asked for ${level.toStringAsFixed(2)}: master $masterVolume '
          '× your volume ${_userVolume.toStringAsFixed(2)})';
      debugPrint('[music] audition silent — $_auditionProblem');
    }
    // Logged like a crossfade, because otherwise an audition is invisible in
    // the console: _apply does the logging and an audition deliberately does
    // not go through it, so the log would show the score's cue before and
    // after with nothing in between to explain the sound.
    debugPrint('[music] audition -> $cue take $take of ${beds.length} '
        '(${beds[take - 1].split(RegExp(r"[\/]")).last})');
    notifyListeners();
  }

  /// Stop auditioning and let the score have the audio back.
  ///
  /// Forgetting [_playing] is the point: the selector's cue has not changed, so
  /// without this the next observation would decide nothing needed doing and
  /// leave the reader in silence.
  Future<void> stopAudition() async {
    _auditionProblem = null;
    if (_auditioning == null) return;
    _auditioning = null;
    // Also clears _playing, which is the point: the selector's cue has not
    // changed, so without forgetting it the next observation would decide
    // nothing needed doing and leave the reader in silence.
    _fadeOutCurrent(auditionFade);
    _playingBed = null;
    debugPrint('[music] audition ended; the score has the audio back');
    notifyListeners();
    _listener?.call();
  }

  /// How many cues the loaded set offers. The number the four generation
  /// options actually differ by, so it is worth being able to see it.
  int get cueCount => _library?.assets.length ?? 0;

  /// Swap loop libraries. Stops rather than crossfades: this is an explicit
  /// choice in settings, not something the prose asked for.
  ///
  /// [bookId] is required for [MusicLibrary.perBook] and ignored otherwise. A
  /// book with no generated set falls back to the shipped one rather than
  /// playing nothing -- books imported before generation existed have none.
  Future<void> useLibrary(
    MusicLibrary library, {
    String? bookId,
    int chapter = 0,
  }) async {
    if (!_available) return;

    var wanted = library;
    if (library == MusicLibrary.perBook) {
      if (bookId == null || !await LoopLibrary.hasGenerated(bookId)) {
        debugPrint('[music] no generated beds for ${bookId ?? 'this book'}, '
            'falling back to ${activeLibrary.name}');
        wanted = activeLibrary;
      }
    }

    // A per-arc set changes under the reader at a chapter boundary, so the arc
    // is part of what identifies the loaded library -- otherwise crossing one
    // would go on playing the previous arc's beds. Resolved before the
    // early-out rather than after, or the boundary would never be noticed.
    final arc = wanted == MusicLibrary.perBook
        ? await LoopLibrary.arcForChapter(bookId!, chapter)
        : 0;
    final forBook = wanted == MusicLibrary.perBook ? bookId : null;
    // A pin is one book's set number; it means nothing in another book.
    if (forBook != _bookId && _library != null) _pinnedSet = null;
    final pinned = forBook == null ? null : _pinnedSet;
    _libraryChapter = chapter;
    // Pinned, the arc boundary no longer changes the beds, so crossing one
    // must not restart them.
    final sameSet = pinned != null
        ? _loadedPin == pinned
        : _loadedPin == null && _arc == arc;
    if (_library?.library == wanted && _bookId == forBook && sameSet) {
      _arc = arc;
      return;
    }

    _dropLead();
    final handle = _handle;
    if (handle != null) await _soloud!.stop(handle);
    _handle = null;
    _playingSource = null;
    _playing = null;
    _sources.clear();
    _rotation.clear();
    await _soloud!.disposeAllSources();
    _library = await LoopLibrary.load(wanted, null, bookId, chapter, pinned);
    _bookId = forBook;
    _arc = arc;
    _loadedPin = pinned;
    selector.reset();
    debugPrint('[music] switched to the ${wanted.name} loops'
        '${_bookId == null ? '' : ' for $_bookId'}'
        '${_library!.arcSize <= 0 ? '' : ' arc $arc '
            '(${_library!.arcSize} chapters each)'}'
        '${pinned == null ? '' : ', pinned to set $pinned'}'
        '${_library!.banded ? ', banded' : ''}'
        ' — ${_library!.assets.length} bed(s)');
    _listener?.call();
    notifyListeners();
  }

  /// Exponential, because pitch and brightness are heard that way: an equal
  /// step in energy should be an equal musical step, not an equal number of Hz.
  double _cutoffFor(double energy) =>
      darkestCutoff * math.pow(brightestCutoff / darkestCutoff, energy);

  /// Where the current bed's low-pass sits. Read by the tests, since this is
  /// the part of "does it move" that can be measured without ears.
  double? get cutoff {
    final source = _playingSource;
    final handle = _handle;
    if (!_available || source == null || handle == null) return null;
    return source.filters.biquadFilter.frequency(soundHandle: handle).value;
  }

  /// How much of the low-pass the current voice is hearing: 1 under the
  /// score, [auditionWet] while auditioning.
  ///
  /// Read by the tests. Asserting the *cutoff* is what let a silent audition
  /// pass for months: a filter set to an impossible frequency still reports
  /// that frequency back, so the assertion held while the audio did not.
  double? get filterWet {
    final source = _playingSource;
    final handle = _handle;
    if (!_available || source == null || handle == null) return null;
    return source.filters.biquadFilter.wet(soundHandle: handle).value;
  }

  Future<void> _apply(CueDecision decision) async {
    if (!_available || !_enabled) return;
    // An audition owns the audio until it is stopped. The decision above still
    // happened and the selector still holds it, so nothing is lost by not
    // playing it -- see stopAudition.
    if (_auditioning != null) return;
    final gain = _gainFor(decision.energy);

    if (!decision.changed && decision.mood == _playing) {
      // Intensity moved within the mood: ramp loudness and brightness, no
      // crossfade. This is the only thing that happens over a long stretch on
      // one cue, so it is what stops that stretch sounding static.
      final handle = _handle;
      final source = _playingSource;
      if (handle != null) _soloud!.fadeVolume(handle, gain, energyFade);
      if (handle != null && source != null) {
        source.filters.biquadFilter
            .frequency(soundHandle: handle)
            .fadeFilterParameter(
              to: _cutoffFor(decision.energy),
              time: energyFade,
            );
      }
      return;
    }
    if (decision.mood == _playing) return;

    // If the change is one the score has been leading into, that bed is
    // already sounding quietly: bring it up rather than starting a second
    // copy. Starting one would put the bed back to its beginning at the exact
    // moment of the change, which is audible and is the opposite of leading
    // in. Promoting it is what makes the preparation pay off.
    final promoting = _leading == decision.mood && _leadHandle != null;
    final bed = promoting ? _leadBed : _nextBed(decision.mood);
    if (bed == null) return;
    final source = promoting ? _leadSource : await _source(bed);
    if (source == null) return;
    // Preparing for somewhere the score did not go. Retreat, or the lead
    // voice would hang under the new cue with nothing ever stopping it.
    if (!promoting) unawaited(_stopLead());

    // Start silent and fade up, so the first cue of a session fades in rather
    // than arriving at full volume. Nothing outgoing means nothing is masking
    // the arrival, so that first one gets the long fade.
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
    if (promoting) {
      // Already audible, so this one sweeps: setting it outright would be a
      // step change in brightness on a voice the reader can hear.
      source.filters.biquadFilter
          .frequency(soundHandle: handle)
          .fadeFilterParameter(to: _cutoffFor(decision.energy), time: over);
    } else {
      // Set the brightness outright rather than fading it: the voice is
      // silent, so there is nothing to hear sweeping, and it should arrive
      // already at the right colour for this paragraph.
      source.filters.biquadFilter.frequency(soundHandle: handle).value =
          _cutoffFor(decision.energy);
    }

    if (outgoing != null) {
      _soloud!.fadeVolume(outgoing, 0, over);
      // Stopping before the fade finishes would be the cut this is avoiding.
      final timer = Timer(over + const Duration(milliseconds: 250), () {
        unawaited(_soloud!.stop(outgoing));
      });
      _pendingStops.add(timer);
    }

    final beds = _library?.variantsOf(decision.mood).length ?? 1;
    debugPrint('[music] ${outgoing == null ? 'in' : 'crossfade'} -> '
        '${decision.mood}'
        '${beds > 1 ? ' [${bed.split(RegExp(r"[\/]")).last} of $beds]' : ''}'
        ' at gain ${gain.toStringAsFixed(2)} '
        '(warmth ${warmth.toStringAsFixed(2)}, $_paragraphsRead/'
        '$warmupParagraphs) over ${over.inMilliseconds}ms');
    _handle = handle;
    _playingSource = source;
    _playing = decision.mood;
    _playingBed = bed;
    _crossfades++;
    notifyListeners();
  }

  /// Fade out, forget the current cue, and go quiet until [open] again. Used
  /// when a different book is being prepared.
  Future<void> close() async {
    _open = false;
    _idleTimer?.cancel();
    _dozing = false;
    selector.reset();
    _current = null;
    // Paragraph numbers restart with the chapter, so a log spanning two of them
    // would read as one run that jumped backwards. For the same reason the
    // warm-up's last-seen index is dropped -- but not its count, which belongs
    // to the reading session and survives a chapter turn. See [restartWarmup].
    _history.clear();
    _lastParagraph = null;
    _window = const [];
    _dominant = null;
    _dropLead();
    final handle = _handle;
    _handle = null;
    _playingSource = null;
    _playing = null;
    if (_available && handle != null) {
      _soloud!.fadeVolume(handle, 0, energyFade);
      final timer = Timer(energyFade + const Duration(milliseconds: 250), () {
        unawaited(_soloud!.stop(handle));
      });
      _pendingStops.add(timer);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    _idleTimer?.cancel();
    for (final timer in _pendingStops) {
      timer.cancel();
    }
    _pendingStops.clear();
    if (_available) {
      final handle = _handle;
      if (handle != null) unawaited(_soloud!.stop(handle));
      _dropLead();
      _soloud!.deinit();
      _available = false;
    }
    super.dispose();
  }
}
