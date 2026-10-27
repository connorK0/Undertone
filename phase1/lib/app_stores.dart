import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'grammar.dart';
import 'library.dart';
import 'mood_cache.dart';

/// The app's two stores, in the platform's application-support directory.
///
/// Kept out of [Library] and [MoodCache] themselves so that those two stay
/// importable from a plain Dart VM. path_provider reaches `dart:ui`, and a
/// command-line tool that imports it does not fail at the call -- it fails to
/// compile, with a page of transitive import paths. The stores already took an
/// explicit path for exactly this reason; only the two convenience
/// constructors needed moving.
///
/// This is also the shape the eventual PC-side server needs: the library, the
/// cache and the classifier all runnable without a Flutter engine.
Future<Library> openAppLibrary() async =>
    Library.at(p.join((await getApplicationSupportDirectory()).path,
        'library.db'));

Future<MoodCache> openAppMoodCache() async =>
    MoodCache.at(p.join((await getApplicationSupportDirectory()).path,
        'mood_cache.db'));

Future<ProofCache> openAppProofCache() async =>
    ProofCache.at(p.join((await getApplicationSupportDirectory()).path,
        'proof_cache.db'));
