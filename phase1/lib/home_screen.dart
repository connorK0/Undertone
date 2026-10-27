import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'epub.dart';
import 'library.dart';
import 'grammar.dart';
import 'mood_cache.dart';
import 'mood_pipeline.dart';
import 'music_engine.dart';
import 'preparation.dart';
import 'reader_screen.dart';
import 'settings.dart';
import 'settings_dialog.dart';
import 'watermark.dart';
import 'watermark_dialog.dart';

/// The shelf. Everything starts here.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.library,
    required this.cache,
    required this.pipeline,
    required this.engine,
    required this.settings,
    this.proofreader,
  });

  final Library library;
  final MoodCache cache;
  final MoodPipeline pipeline;
  final MusicEngine engine;
  final Settings settings;
  final Proofreader? proofreader;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<LibraryEntry> _entries = const [];
  bool _loading = true;
  String? _importing;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final entries = await widget.library.entries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose an ePub',
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );
    final path = picked.firstOrNull?.path;
    if (path == null) return;

    setState(() => _importing = 'Reading ${path.split(Platform.pathSeparator).last}...');
    try {
      final bytes = await File(path).readAsBytes();
      // Cleaned before it is stored, and so before Book.fromText ever sees it.
      // A stamp is usually short enough that the splitter would fold it
      // forward into the paragraph after it -- at which point it is no longer
      // a line that can be removed, it is a contaminated paragraph.
      final parsed = await _unstamp(readEpub(bytes));
      final id = await widget.library.addEpub(parsed, bytes);
      await _refresh();
      if (!mounted) return;

      // The cold start belongs to import, not to opening: a first chapter is
      // scored here so that opening the book is immediate and has music. With
      // scoring off there is nothing to pay for and nothing to wait for.
      if (!widget.settings.scoring) return;
      setState(() => _importing = 'Scoring the opening of "${parsed.title}"...');
      final first = await widget.library.chapter(id, 0);
      if (first != null) {
        final preparation = BookPreparation(
          pipeline: widget.pipeline,
          engine: widget.engine,
        );
        await preparation.run(first);
        if (preparation.stage == PrepareStage.failed && mounted) {
          _say('Imported "${parsed.title}", but could not score it: '
              '${preparation.note}. It will read silently.');
        }
      }
    } on EpubException catch (error) {
      if (mounted) _say('$error');
    } on FileSystemException catch (error) {
      if (mounted) _say('Could not read that file: ${error.message}');
    } finally {
      if (mounted) setState(() => _importing = null);
    }
  }

  /// Offer to take out anything that repeats through the book and points the
  /// reader somewhere else. Returns the book to store -- unchanged if there is
  /// nothing to remove, or if the reader would rather keep it.
  Future<EpubBook> _unstamp(EpubBook parsed) async {
    final texts = [for (final chapter in parsed.chapters) chapter.text];
    final found = findWatermarks(texts);
    if (found.isEmpty || !mounted) return parsed;

    final chosen = await confirmWatermarks(
      context,
      title: parsed.title,
      found: found,
      totalChars: texts.fold<int>(0, (n, t) => n + t.length),
    );
    if (chosen == null || chosen.isEmpty) return parsed;

    return EpubBook(
      title: parsed.title,
      author: parsed.author,
      cover: parsed.cover,
      chapters: [
        for (final chapter in parsed.chapters)
          EpubChapter(
            title: chapter.title,
            text: removeWatermarks(chapter.text, chosen),
          ),
      ],
    );
  }

  /// The same clean, for a book that is already on the shelf.
  ///
  /// Books imported before this existed, and books whose stamps only became
  /// obvious once they were being read.
  Future<void> _unstampStored(LibraryEntry entry) async {
    final chapters = await widget.library.chapterBodies(entry.id);
    final texts = [for (final (_, body) in chapters) body];
    final found = findWatermarks(texts);
    if (!mounted) return;
    if (found.isEmpty) {
      _say('Nothing repeats through "${entry.title}" that looks like a '
          'watermark. Left alone.');
      return;
    }

    final chosen = await confirmWatermarks(
      context,
      title: entry.title,
      found: found,
      totalChars: texts.fold<int>(0, (n, t) => n + t.length),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;

    final removed = removalSize(texts, chosen);
    final changed = await widget.library.replaceChapterBodies(
      entry.id,
      [for (final text in texts) removeWatermarks(text, chosen)],
    );
    // Only the chapters that actually changed. Their tags were written against
    // the old text and their keys fold in a hash of it, so those rows are
    // already unreachable and deleting them is tidying. Every *other* chapter
    // still hashes to the same key and its tags are still good -- deleting
    // those was throwing away work that costs about a second a paragraph to
    // rebuild. The theme is keyed on the book id and survives regardless.
    for (final index in changed) {
      await widget.cache.forgetTags('${bookKeyPrefix(entry.id)}$index-');
    }
    if (!mounted) return;
    _say('Removed $removed characters from "${entry.title}". '
        'It will be classified again the next time you open it.');
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openBook(LibraryEntry entry) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
        library: widget.library,
        entry: entry,
        pipeline: widget.pipeline,
        engine: widget.engine,
        settings: widget.settings,
        proofreader: widget.proofreader,
        startChapter: entry.chapterIndex,
        startParagraph: entry.paragraphIndex,
      ),
    ));
    await _refresh(); // progress may have moved
  }

  Future<void> _remove(LibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${entry.title}"?'),
        content: const Text(
          'The book and everything the classifier learned about it will be '
          'deleted. Importing it again means scoring it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.library.remove(entry.id);
    await widget.cache.forgetBook(entry.id, bookKeyPrefix(entry.id));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(
                settings: widget.settings,
                engine: widget.engine,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing == null ? _import : null,
        icon: const Icon(Icons.add),
        label: const Text('Add ePub'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_importing != null)
                  Material(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: ListTile(
                      leading: const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      title: Text(_importing!),
                      subtitle: const Text(
                        'Scoring the opening now means the book has music the '
                        'moment you open it.',
                      ),
                    ),
                  ),
                _ScoringBar(settings: widget.settings, engine: widget.engine),
                Expanded(
                  child: _entries.isEmpty
                      ? const Center(child: Text('No books yet.'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _entries.length,
                          itemBuilder: (context, i) {
                            final entry = _entries[i];
                            return ListTile(
                              leading: _Cover(entry: entry),
                              title: Text(entry.title),
                              subtitle: Text(entry.subtitle),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Remove repeated watermark lines',
                                    icon: const Icon(
                                        Icons.cleaning_services_outlined),
                                    onPressed: () => _unstampStored(entry),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _remove(entry),
                                  ),
                                ],
                              ),
                              onTap: () => _openBook(entry),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      height: 56,
      child: entry.cover != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Image.memory(entry.cover!, fit: BoxFit.cover),
            )
          : Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Icon(Icons.menu_book, size: 20, color: scheme.outline),
            ),
    );
  }
}

/// The one switch that decides whether a book is scored at all.
///
/// On the shelf rather than in the settings dialog because it is a decision
/// about *this reading session* -- "I just want to read" -- and it has to be
/// made before a book is opened, since opening one with scoring on is what
/// starts the fifteen seconds of classifying.
class _ScoringBar extends StatelessWidget {
  const _ScoringBar({required this.settings, required this.engine});

  final Settings settings;
  final MusicEngine engine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Material(
        color: scheme.surfaceContainerHighest,
        child: SwitchListTile(
          dense: true,
          secondary: Icon(
            settings.scoring ? Icons.graphic_eq : Icons.menu_book,
            color: scheme.onSurfaceVariant,
          ),
          title: Text(settings.scoring ? 'Music scoring on' : 'Just reading'),
          subtitle: Text(
            settings.scoring
                ? 'Books are read by the classifier and scored as you go. '
                    'Opening one waits a few seconds for its theme.'
                : 'No classifier, no music, no waiting — books open straight '
                    'to the page.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          value: settings.scoring,
          onChanged: (value) {
            settings.setScoring(value);
            // Nothing should be left sounding from the last book.
            if (!value) engine.close();
          },
        ),
      ),
    );
  }
}
