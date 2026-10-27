/// The books on this device.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:music_book_core/music_book_core.dart';
import 'package:music_book_player/music_book_player.dart';

import 'reader_screen.dart';
import 'shelf.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.shelf, required this.player});

  final Shelf shelf;
  final ScorePlayer player;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Workspace>? _books;
  final _problems = <String>[];
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _problems.clear();
    final books = await widget.shelf.books(problems: _problems);
    if (mounted) setState(() => _books = books);
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose a book pack',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    setState(() => _busy = 'Unpacking…');
    try {
      await widget.shelf.import(path);
    } catch (error) {
      _problems.add('$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    await _refresh();
  }

  Future<void> _remove(Workspace ws) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text('Remove "${ws.title}"?'),
        content: const Text('Its text, tags and music are deleted from this '
            'device. The pack it came from is not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await widget.shelf.remove(ws);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: 'Import a book pack',
            icon: const Icon(Icons.add),
            onPressed: _busy == null ? _import : null,
          ),
        ],
      ),
      body: books == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator.adaptive(
              onRefresh: _refresh,
              child: ListView(
                children: [
                  if (_busy != null) LinearProgressIndicator(semanticsLabel: _busy),
                  for (final problem in _problems)
                    ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: Text(problem,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (books.isEmpty) const _HowToGetBooks(),
                  for (final ws in books)
                    ListTile(
                      title: Text(ws.title),
                      subtitle: Text([
                        if (ws.author != null) ws.author!,
                        '${ws.info['chapters']} chapters',
                        hasMusic(ws) ? 'with music' : 'no music yet',
                      ].join(' · ')),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ReaderScreen(ws: ws, player: widget.player),
                        ),
                      ),
                      onLongPress: () => _remove(ws),
                    ),
                ],
              ),
            ),
    );
  }
}

class _HowToGetBooks extends StatelessWidget {
  const _HowToGetBooks();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No books yet', style: text.titleMedium),
          const SizedBox(height: 12),
          Text(
            'Books are prepared for music on a computer, then carried over:\n\n'
            '1. dart run music_book ingest book.epub <folder>\n'
            '2. dart run music_book prepare <folder> --arc 0\n'
            '3. python -m music_book_gen generate <folder> --arc 0\n'
            '4. dart run music_book pack <folder> book.zip\n\n'
            'Then tap + and choose book.zip, or drop it into this app\'s '
            'folder in the Files app and pull down to refresh.',
            style: text.bodyMedium,
          ),
        ],
      ),
    );
  }
}
