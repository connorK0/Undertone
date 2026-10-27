import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_stores.dart';
import 'grammar.dart';
import 'home_screen.dart';
import 'library.dart';
import 'mood_cache.dart';
import 'mood_pipeline.dart';
import 'mood_trigger.dart';
import 'music_engine.dart';
import 'music_library.dart';
import 'ollama_client.dart';
import 'reading_style.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final library = await openAppLibrary();
  await seedSamples(library);
  final settings = Settings(library);
  await settings.load();

  final cache = await openAppMoodCache();
  final pipeline = MoodPipeline(client: OllamaClient(), cache: cache);
  moodPipeline = pipeline;
  final proofreader = Proofreader(
    await openAppProofCache(),
    pipeline.client,
    isBusy: () => pipeline.busy,
  );

  final engine = MusicEngine();
  await engine.start();
  engine.attach(pipeline);
  engine.userVolume = settings.volume;
  engine.enabled = settings.enabled;
  if (settings.loops != activeLibrary) {
    await engine.useLibrary(settings.loops);
  }

  runApp(ReaderApp(
    library: library,
    cache: cache,
    pipeline: pipeline,
    engine: engine,
    settings: settings,
    proofreader: proofreader,
  ));
}

/// The chapters that ship with the app, asset file to display title.
///
/// Chosen for range: a chapter the classifier hears as one mood throughout
/// gives the score nothing to do. Stave I of the Carol actually moves, and
/// Alice covers the light end that nothing else here does.
const sampleBooks = {
  'christmas_carol_stave1.txt': 'A Christmas Carol, stave I',
  'dracula_ch1.txt': 'Dracula, chapter I',
  'alice_ch1.txt': 'Alice in Wonderland, chapter I',
  'chapter1.txt': "The Lamplighter's Round",
};

/// Put the bundled chapters in the library the first time the app runs, so a
/// first run has something in it. They are ordinary one-chapter books
/// afterwards, and can be removed like any other.
Future<void> seedSamples(Library library) async {
  for (final entry in sampleBooks.entries) {
    final id = 'sample-${entry.key.replaceAll('.txt', '')}';
    if (await library.has(id)) continue;
    await library.addPlainText(
      id: id,
      title: entry.value,
      text: await rootBundle.loadString('assets/books/${entry.key}'),
    );
  }
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({
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
  Widget build(BuildContext context) {
    // The whole app takes the reader's page brightness, not just the prose:
    // a dark chapter under a bright app bar is worse than either alone.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Undertone',
        theme: settings.reading.theme.themeData,
        home: HomeScreen(
          library: library,
          cache: cache,
          pipeline: pipeline,
          engine: engine,
          settings: settings,
          proofreader: proofreader,
        ),
      ),
    );
  }
}
