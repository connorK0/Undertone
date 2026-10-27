// Proofread chapters with the app's own code, and show every decision.
//
//     dart run tool/proofread.dart <bookId> <chapter> [<last chapter>]
//
// Chapters are numbered as the chapter list shows them, from 1. Every
// proposal the model makes is printed with what the rules in lib/grammar.dart
// decided about it, so a prompt or a rule can be judged against real prose
// before a reader ever sees the result.
//
// It fills the app's own proof_cache.db, so a chapter checked here opens
// already corrected -- and a chapter already checked under this prompt version
// is not asked again. Needs Ollama. Close the app first: a running app holds
// the build's sqlite3.dll, which `dart run` rebuilds.

import 'dart:io';

import 'package:reader_shell/grammar.dart';
import 'package:reader_shell/library.dart';
import 'package:reader_shell/ollama_client.dart';

String get _appSupport =>
    '${Platform.environment['APPDATA']}\\com.example\\reader_shell';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/proofread.dart <bookId> <chapter> '
        '[<last chapter>]');
    exit(2);
  }
  final id = args[0];
  final first = int.parse(args[1]);
  final last = args.length > 2 ? int.parse(args[2]) : first;

  final library = await Library.at('$_appSupport\\library.db');
  final reader = Proofreader(
      await ProofCache.at('$_appSupport\\proof_cache.db'), OllamaClient());

  var proposed = 0;
  var applied = 0;
  for (var number = first; number <= last; number++) {
    final chapter = await library.chapter(id, number - 1);
    if (chapter == null) {
      stderr.writeln('no chapter $number in $id');
      break;
    }
    final started = DateTime.now();
    final proof = await reader.check(chapter);
    final took = DateTime.now().difference(started).inSeconds;
    proposed += proof.proposals.length;
    applied += proof.applied;
    stdout.writeln('\n=== chapter $number: ${chapter.paragraphs.length} '
        'paragraphs, ${proof.proposals.length} proposed, ${proof.applied} '
        'applied, ${took}s (prompt v$proofreadPromptVersion)');
    for (final p in proof.proposals) {
      final c = p.correction;
      stdout.writeln('  ${p.rejected == null ? 'FIXED ' : '  --  '}'
          '[${c.paragraph}] ${c.kind}'
          '${p.rejected == null ? '' : ' -- ${p.rejected}'}\n'
          '        ${c.original}\n'
          '     -> ${c.corrected}\n'
          '        (${c.reason})'
          '${c.verdict.isEmpty ? '' : '\n        second look: ${c.verdict}'}');
    }
  }
  stdout.writeln('\n$applied of $proposed proposal(s) applied');
  await reader.cache.close();
  await library.close();
}
