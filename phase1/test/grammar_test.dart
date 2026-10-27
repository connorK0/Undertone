// Proofreading: which proposals reach the page, and where they land. The two
// sentences below are written to carry the two kinds of mistake the
// proofreader exists for: a wrong verb form, and "other than" where "as well
// as" is meant (SUMMARY §9.41).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reader_shell/book.dart';
import 'package:reader_shell/grammar.dart';
import 'package:reader_shell/ollama_client.dart';

const founders = 'The founders were used to invest a lot in untested designs '
    'and gadgets, and they would never give up on a prototype built after the '
    'war of tier 6 machines.';
const treaty = "Any breach in the treaty would ruin one of Lady Mirren's "
    'centers of power other than make the Varro family untrustworthy.';
const plain = 'Tomas stayed silent while the storm raged above the valley and '
    'the wind tore at the old trees.';

/// A proposal, confirmed by the second look unless [confirmed] says not.
Correction fix(int paragraph, String original, String corrected,
        {bool deliberate = false, bool? confirmed = true}) =>
    Correction(
      paragraph: paragraph,
      original: original,
      corrected: corrected,
      kind: 'grammar',
      reason: '',
      deliberate: deliberate,
      confirmed: confirmed,
    );

void main() {
  group('what is applied', () {
    test('the two mistakes are fixed, and only there', () {
      final result = proofread([founders, treaty, plain], [
        fix(0, 'used to invest a lot', 'used to investing a lot'),
        fix(1, 'other than make the Varro', 'as well as make the Varro'),
      ]);
      expect(result.paragraphs[0],
          startsWith('The founders were used to investing a lot in untested'));
      expect(result.paragraphs[1], contains('power as well as make the Varro'));
      expect(result.paragraphs[2], plain);
      expect(result.applied, 2);
    });

    test('a mark covers the corrected words, after earlier fixes shift them',
        () {
      final result = proofread([founders], [
        fix(0, 'tier 6 machines', 'tier 6 engines'),
        fix(0, 'used to invest', 'used to investing'),
      ]);
      final text = result.paragraphs.single;
      final marks = result.marks[0]!;
      expect([for (final m in marks) text.substring(m.start, m.end)],
          ['used to investing', 'tier 6 engines']);
    });

    test('never adds or removes a paragraph', () {
      final result = proofread([founders, plain], [
        fix(0, 'used to invest', 'used to investing'),
      ]);
      expect(result.paragraphs, hasLength(2));
    });
  });

  group('what is turned down', () {
    String? why(Correction c, [List<String>? paragraphs]) =>
        proofread(paragraphs ?? [founders, treaty], [c]).proposals.single.rejected;

    test('anything the model thinks could be deliberate', () {
      expect(why(fix(0, 'used to invest', 'used to investing',
              deliberate: true)),
          'possibly deliberate');
    });

    test('a quotation that is not in the text', () {
      expect(why(fix(0, 'used to investing a lot', 'were used to investing')),
          'not in the text');
    });

    test('a quotation that appears twice, so the place is unknown', () {
      expect(why(fix(0, 'and', 'or'), [founders]), 'appears 2 times');
    });

    test('a rewrite rather than a fix', () {
      expect(
          why(fix(1, 'other than make the Varro family untrustworthy',
              'and it would also cause everyone to distrust the Varro')),
          'too large a change');
    });

    test('a changed name', () {
      expect(why(fix(1, "Lady Mirren's centers", "Lady Miren's centers")),
          'changes a capitalised word');
    });

    test('punctuation, quotes, hyphens and case alone', () {
      expect(why(fix(1, "Lady Mirren's centers of power other",
              "Lady Mirren's centers of power, other")),
          'punctuation only');
      expect(why(fix(0, 'tier 6 machines', 'tier-6 machines')),
          'punctuation only');
    });

    test('a possessive is still the same name', () {
      expect(why(fix(1, "Lady Mirren's centers", 'Lady Mirren centers')), isNull);
    });

    test('a fix the second look turned down, or never saw', () {
      expect(why(fix(0, 'used to invest', 'used to investing',
              confirmed: false)),
          'not confirmed');
      expect(why(fix(0, 'used to invest', 'used to investing',
              confirmed: null)),
          'never confirmed');
    });

    test('a proposal that changes nothing', () {
      expect(why(fix(0, 'used to invest', 'used to invest')), 'no change');
    });

    test('a paragraph that does not exist', () {
      expect(why(fix(9, 'x', 'y')), 'no such paragraph');
    });

    test('a second fix over the same words', () {
      final result = proofread([founders], [
        fix(0, 'used to invest a lot', 'used to investing a lot'),
        fix(0, 'invest a lot in', 'investing heavily in'),
      ]);
      expect(result.proposals.last.rejected, 'overlaps another fix');
      expect(result.applied, 1);
    });
  });

  group('the cache', () {
    test('never asked is null; checked and clean is an empty list', () async {
      final cache = await ProofCache.inMemory();
      expect(await cache.proposals('ch-1'), isNull);
      await cache.put('ch-1', const []);
      expect(await cache.proposals('ch-1'), isEmpty);
      await cache.close();
    });

    test('a proposal round-trips whole', () async {
      final cache = await ProofCache.inMemory();
      await cache.put('ch-1', [
        fix(0, 'used to invest', 'used to investing', deliberate: true)
            .judged(confirmed: false, verdict: 'style'),
      ]);
      final back = (await cache.proposals('ch-1'))!.single;
      expect(back.original, 'used to invest');
      expect(back.corrected, 'used to investing');
      expect(back.deliberate, isTrue);
      expect(back.confirmed, isFalse);
      expect(back.verdict, 'style');
      await cache.close();
    });
  });

  group('the proofreader', () {
    test('proposes, takes a second look, then reads the cache', () async {
      var proposals = 0;
      var looks = 0;
      final http.Client model = MockClient((request) async {
        final second = request.body.contains('You check one proposed fix');
        second ? looks++ : proposals++;
        final content = jsonEncode(second
            ? {
                'original_is_wrong': true,
                'meaning_unchanged': true,
                'accept': true,
                'why': 'wrong verb form',
              }
            : {
                'corrections': [
                  fix(0, 'used to invest', 'used to investing',
                          confirmed: null)
                      .toJson(),
                  // Turned down by the rules, so never shown a second time.
                  fix(0, 'and', 'or', confirmed: null).toJson(),
                ],
              });
        return http.Response(
            jsonEncode({
              'message': {'content': content},
            }),
            200);
      });
      final reader = Proofreader(
          await ProofCache.inMemory(), OllamaClient(client: model));
      final chapter = Book(title: 'Chapter 12', paragraphs: [founders, plain]);

      expect(await reader.cached(chapter), isNull,
          reason: 'cached() never asks the model');
      final first = await reader.check(chapter);
      expect(first.paragraphs.first, contains('used to investing'));
      expect(first.proposals.first.correction.verdict, 'wrong verb form');
      await reader.check(chapter);
      expect((await reader.cached(chapter))!.applied, 1);
      expect((proposals, looks), (1, 1));
    });
  });
}
