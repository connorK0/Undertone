import 'package:flutter/foundation.dart';

import 'library.dart';
import 'music_library.dart';
import 'reading_style.dart';

/// What the reader has chosen: about the music, and about the page.
///
/// Phase 3 shipped with no way to turn the score down or off, which was
/// defensible only while it was a demo. Stored in the library database, since
/// these are the reader's own choices rather than derived data.
class Settings extends ChangeNotifier {
  Settings(this._library);

  final Library _library;

  static const _volumeKey = 'music.volume';
  static const _enabledKey = 'music.enabled';
  static const _libraryKey = 'music.library';
  static const _fontKey = 'reading.font';
  static const _fontSizeKey = 'reading.fontSize';
  static const _spacingKey = 'reading.spacing';
  static const _themeKey = 'reading.theme';
  static const _scoringKey = 'music.scoring';
  static const _proofreadKey = 'reading.proofread';

  double _volume = 0.7;
  bool _enabled = true;
  MusicLibrary _loops = activeLibrary;
  ReadingStyle _reading = defaultReadingStyle;
  bool _scoring = true;
  bool _proofread = false;

  /// 0 to 1. Multiplies the engine's own level, which is already a background
  /// one -- the loops sit around -17 dBFS.
  double get volume => _volume;
  bool get enabled => _enabled;

  /// Which set of loops to play. Was a source edit until now.
  MusicLibrary get loops => _loops;

  /// How the page looks: face, size, line spacing and brightness.
  ReadingStyle get reading => _reading;

  /// Whether books get scored at all.
  ///
  /// Distinct from [enabled], which only silences the output. With this off no
  /// classifier runs, so a book opens the moment it is tapped instead of after
  /// a theme pass and a first batch -- about fifteen seconds cold, and the
  /// whole of it spent staring at page one. For when you just want to read.
  bool get scoring => _scoring;

  /// Whether clear grammar mistakes are fixed on the page, underlined so the
  /// reader can see where the text is not word for word the author's. Never
  /// changes the stored chapter. See lib/grammar.dart.
  ///
  /// Off by default: with the local 7B model, about one applied fix in eight
  /// changed what a sentence meant (SUMMARY §9.41).
  bool get proofread => _proofread;

  Future<void> load() async {
    final stored = await _library.loadSettings();
    _volume = double.tryParse(stored[_volumeKey] ?? '') ?? _volume;
    _enabled = (stored[_enabledKey] ?? 'true') == 'true';
    _loops = MusicLibrary.values
            .where((l) => l.name == stored[_libraryKey])
            .firstOrNull ??
        _loops;
    // Enums are stored by name and looked up the same way, so a value written
    // by an older build -- or a hand-edited row -- falls back to the default
    // rather than throwing on the way into the library screen.
    _scoring = (stored[_scoringKey] ?? 'true') == 'true';
    _proofread = (stored[_proofreadKey] ?? 'false') == 'true';
    _reading = ReadingStyle(
      font: _named(ReaderFont.values, stored[_fontKey], _reading.font),
      fontSize: (double.tryParse(stored[_fontSizeKey] ?? '') ??
              _reading.fontSize)
          .clamp(ReadingStyle.minFontSize, ReadingStyle.maxFontSize),
      spacing: _named(LineSpacing.values, stored[_spacingKey], _reading.spacing),
      theme: _named(ReaderTheme.values, stored[_themeKey], _reading.theme),
    );
    notifyListeners();
  }

  static T _named<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((v) => v.name == name).firstOrNull ?? fallback;

  /// Change the page. Takes the whole style so that the paginator sees one
  /// change rather than up to four, each of which would re-cut every page.
  Future<void> setReading(ReadingStyle value) async {
    final was = _reading;
    _reading = value;
    notifyListeners();
    if (was.font != value.font) {
      await _library.saveSetting(_fontKey, value.font.name);
    }
    if (was.fontSize != value.fontSize) {
      await _library.saveSetting(_fontSizeKey, '${value.fontSize}');
    }
    if (was.spacing != value.spacing) {
      await _library.saveSetting(_spacingKey, value.spacing.name);
    }
    if (was.theme != value.theme) {
      await _library.saveSetting(_themeKey, value.theme.name);
    }
  }

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0, 1);
    notifyListeners();
    await _library.saveSetting(_volumeKey, '$_volume');
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    await _library.saveSetting(_enabledKey, '$value');
  }

  Future<void> setScoring(bool value) async {
    _scoring = value;
    notifyListeners();
    await _library.saveSetting(_scoringKey, '$value');
  }

  Future<void> setProofread(bool value) async {
    _proofread = value;
    notifyListeners();
    await _library.saveSetting(_proofreadKey, '$value');
  }

  Future<void> setLoops(MusicLibrary value) async {
    _loops = value;
    notifyListeners();
    await _library.saveSetting(_libraryKey, value.name);
  }
}
