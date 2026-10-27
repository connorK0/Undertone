/// Undertone for iOS: a reader whose score follows the page.
///
/// Books arrive prepared -- tagged, planned and generated on a computer with
/// the framework (framework/), packed, and carried over (see shelf.dart). This
/// app reads them and plays their music; it runs no model of its own.
library;

import 'package:flutter/material.dart';
import 'package:music_book_player/music_book_player.dart';

import 'library_screen.dart';
import 'shelf.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reading is never gated on the music: a player with no audio device is a
  // silent player, not a failed launch.
  final player = ScorePlayer();
  await player.init();
  final shelf = await Shelf.open();
  runApp(MusicBookApp(shelf: shelf, player: player));
}

class MusicBookApp extends StatelessWidget {
  const MusicBookApp({super.key, required this.shelf, required this.player});

  final Shelf shelf;
  final ScorePlayer player;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Undertone',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6B4F2A),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF6B4F2A),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: LibraryScreen(shelf: shelf, player: player),
    );
  }
}
