import 'package:flutter/material.dart';

import 'music_engine.dart';
import 'music_library.dart';
import 'reading_style.dart';
import 'settings.dart';

/// Everything the reader can change, in two sections.
///
/// Reading comes first because it is the one you reach for mid-chapter -- the
/// music settings get set once and forgotten, while the size of the type is
/// something you change because the light in the room changed.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({
    super.key,
    required this.settings,
    required this.engine,
  });

  final Settings settings;
  final MusicEngine engine;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => AlertDialog(
        title: const Text('Settings'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ReadingSection(settings: settings),
                const Divider(height: 32),
                _MusicSection(settings: settings, engine: engine),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(
          text,
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
}

class _ReadingSection extends StatelessWidget {
  const _ReadingSection({required this.settings});

  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final style = settings.reading;
    void change(ReadingStyle next) => settings.setReading(next);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading('Reading'),

        // A sample, not a description. Every one of these settings is about
        // how the page looks, and none of them can be judged from a label:
        // "Palatino 21" means nothing until you see it.
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: style.theme.background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text(
            'Marley was dead: to begin with. There is no doubt whatever about '
            'that.',
            style: style.textStyle,
          ),
        ),

        const _Label('Font'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final font in ReaderFont.values)
              ChoiceChip(
                label:
                    Text(font.label, style: TextStyle(fontFamily: font.family)),
                selected: style.font == font,
                onSelected: (_) => change(style.copyWith(font: font)),
              ),
          ],
        ),

        const _Label('Size'),
        Row(
          children: [
            const Text('A', style: TextStyle(fontSize: 13)),
            Expanded(
              child: Slider(
                value: style.fontSize,
                min: ReadingStyle.minFontSize,
                max: ReadingStyle.maxFontSize,
                divisions: (ReadingStyle.maxFontSize - ReadingStyle.minFontSize)
                    .round(),
                label: '${style.fontSize.round()}',
                onChanged: (value) =>
                    change(style.copyWith(fontSize: value.roundToDouble())),
              ),
            ),
            const Text('A', style: TextStyle(fontSize: 22)),
          ],
        ),

        const _Label('Line spacing'),
        SegmentedButton<LineSpacing>(
          segments: [
            for (final spacing in LineSpacing.values)
              ButtonSegment(value: spacing, label: Text(spacing.label)),
          ],
          selected: {style.spacing},
          onSelectionChanged: (selection) =>
              change(style.copyWith(spacing: selection.first)),
        ),

        const _Label('Page'),
        SegmentedButton<ReaderTheme>(
          segments: [
            for (final theme in ReaderTheme.values)
              ButtonSegment(value: theme, label: Text(theme.label)),
          ],
          selected: {style.theme},
          onSelectionChanged: (selection) =>
              change(style.copyWith(theme: selection.first)),
        ),

        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fix clear grammar mistakes'),
          subtitle: const Text(
            'Experimental. Small fixes that keep every name are shown with '
            'a dotted underline, and anything that could be deliberate is '
            'left as written; the stored book is never changed. In testing, '
            'about one fix in eight changed what a sentence meant, so check '
            'the inspector when something reads oddly.',
          ),
          value: settings.proofread,
          onChanged: settings.setProofread,
        ),
      ],
    );
  }
}

class _MusicSection extends StatelessWidget {
  const _MusicSection({required this.settings, required this.engine});

  final Settings settings;
  final MusicEngine engine;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading('Music'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Play music'),
          value: settings.enabled,
          onChanged: (value) {
            settings.setEnabled(value);
            engine.enabled = value;
          },
        ),
        const _Label('Volume'),
        Slider(
          value: settings.volume,
          onChanged: (value) {
            settings.setVolume(value);
            engine.userVolume = value;
          },
        ),
        const _Label('Loops'),
        SegmentedButton<MusicLibrary>(
          segments: const [
            ButtonSegment(
              value: MusicLibrary.generated,
              label: Text('Generated'),
            ),
            ButtonSegment(
              value: MusicLibrary.licensed,
              label: Text('Licensed'),
            ),
            // Phase 5 Task 0 scaffolding; goes with the rest of it.
            ButtonSegment(
              value: MusicLibrary.experiment,
              label: Text('Theme test'),
            ),
            ButtonSegment(
              value: MusicLibrary.perBook,
              label: Text('Per book'),
            ),
          ],
          selected: {settings.loops},
          onSelectionChanged: (selection) {
            settings.setLoops(selection.first);
            engine.useLibrary(selection.first);
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Generated loops are seamless and level-matched. The licensed '
          'CC0/CC-BY set is real music but was never auditioned, so its '
          'crossfades may lurch. "Theme test" is an experiment: four '
          'treatments of one tune, chosen by intensity instead of mood, to see '
          'whether that moves enough to be worth building. "Per book" plays '
          'beds written for that book by a music model from its own theme, and '
          'falls back to the generated set for books that have none yet.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Text(
          'However it is set, the score starts about 7 dB back and comes up to '
          'level over the first ${MusicEngine.defaultWarmupParagraphs} '
          'paragraphs of a book, so it stays behind you while you are still '
          'settling in.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
