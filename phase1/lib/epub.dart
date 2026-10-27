import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Reads an ePub into chapters of plain prose.
///
/// An ePub is a zip holding `META-INF/container.xml`, which points at an OPF
/// package document: metadata, a manifest of files, and a spine giving reading
/// order. The prose is XHTML.
///
/// Chapters are taken from the book's own navigation document (`toc.ncx`, or an
/// EPUB 3 `nav`) rather than guessed, because that is what the book declares
/// its own structure to be and it carries real chapter titles. Its entries
/// point at `file#anchor`, so a single XHTML file usually holds several
/// chapters -- Project Gutenberg's *Pride and Prejudice* is 61 chapters across
/// 16 files. Splitting per file would give sixteen twenty-minute "chapters".
///
/// Where there is no usable navigation, this falls back to splitting on `h1`
/// and `h2`, and failing that to one chapter per spine document.
class EpubChapter {
  const EpubChapter({required this.title, required this.text});

  final String title;

  /// Blank-line separated paragraphs, ready for [Book.fromText]. Nothing here
  /// collapses whitespace or folds short blocks -- that is the splitter's job,
  /// and it has to stay the only place it happens.
  final String text;
}

class EpubBook {
  const EpubBook({
    required this.title,
    required this.author,
    required this.chapters,
    this.cover,
  });

  final String title;
  final String? author;
  final List<EpubChapter> chapters;
  final Uint8List? cover;
}

class EpubException implements Exception {
  const EpubException(this.message);
  final String message;
  @override
  String toString() => 'Could not read this ePub: $message';
}

/// Blocks under this are covers, title pages and tables of contents rather
/// than chapters. Generic: it needs no knowledge of who made the file.
const _minChapterChars = 400;

/// Elements that end a paragraph. Anything else is inline.
const _blockTags = {
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'blockquote', 'li', 'pre', 'td', 'dd', 'dt', 'figcaption',
};

const _headingTags = {'h1', 'h2', 'h3'};

/// Named entities XHTML uses that XML does not define. Undeclared entities are
/// a parse error, so they are replaced before parsing rather than after.
const _entities = {
  'nbsp': ' ', 'mdash': '—', 'ndash': '–', 'hellip': '…',
  'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”',
  'copy': '©', 'reg': '®', 'trade': '™', 'deg': '°', 'pound': '£',
  'eacute': 'é', 'egrave': 'è', 'agrave': 'à', 'ccedil': 'ç', 'uuml': 'ü',
  'ouml': 'ö', 'auml': 'ä', 'szlig': 'ß', 'oelig': 'œ', 'aelig': 'æ',
  'dagger': '†', 'sect': '§', 'para': '¶', 'middot': '·', 'bull': '•',
  'frac12': '½', 'frac14': '¼', 'times': '×', 'pound2': '£',
};

/// One block of text, with every `id` found inside it. Navigation anchors point
/// at those ids, which is how a file gets cut into chapters.
class _Block {
  _Block(this.text, this.anchors, {this.heading = false});
  final String text;
  final Set<String> anchors;
  final bool heading;
}

EpubBook readEpub(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw EpubException('not a readable zip ($error)');
  }

  final files = <String, ArchiveFile>{};
  for (final file in archive.files) {
    if (file.isFile) files[file.name] = file;
  }

  String? readText(String path) {
    final file = files[path] ?? files[Uri.decodeFull(path)];
    if (file == null) return null;
    return utf8.decode(file.content as List<int>, allowMalformed: true);
  }

  // --- container -> OPF -------------------------------------------------
  final container = readText('META-INF/container.xml');
  if (container == null) {
    throw const EpubException('no META-INF/container.xml');
  }
  final rootPath = _parse(container)
      .findAllElements('rootfile')
      .map((e) => e.getAttribute('full-path'))
      .whereType<String>()
      .firstOrNull;
  if (rootPath == null) throw const EpubException('container names no OPF');

  final opfText = readText(rootPath);
  if (opfText == null) throw EpubException('missing OPF at $rootPath');
  final opf = _parse(opfText);
  final base = p.url.dirname(rootPath);
  String resolve(String href) => base == '.' || base.isEmpty
      ? href
      : p.url.normalize(p.url.join(base, href));

  // --- metadata and manifest --------------------------------------------
  String? meta(String name) => opf
      .findAllElements(name, namespaceUri: '*')
      .map((e) => e.innerText.trim())
      .where((t) => t.isNotEmpty)
      .firstOrNull;

  final manifest = <String, ({String href, String type, String properties})>{};
  for (final item in opf.findAllElements('item', namespaceUri: '*')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id == null || href == null) continue;
    manifest[id] = (
      href: resolve(href),
      type: item.getAttribute('media-type') ?? '',
      properties: item.getAttribute('properties') ?? '',
    );
  }

  final spine = <String>[];
  for (final ref in opf.findAllElements('itemref', namespaceUri: '*')) {
    final idref = ref.getAttribute('idref');
    final entry = idref == null ? null : manifest[idref];
    if (entry != null && entry.type.contains('html')) spine.add(entry.href);
  }
  if (spine.isEmpty) throw const EpubException('the spine is empty');

  // --- every block of prose, in reading order ---------------------------
  final blocks = <String, List<_Block>>{};
  for (final path in spine) {
    final xhtml = readText(path);
    blocks[path] = xhtml == null ? const [] : _blocksOf(xhtml);
  }
  _truncateAtLicence(spine, blocks);

  final chapters = _chaptersFromNav(opf, manifest, resolve, readText, spine, blocks) ??
      _chaptersFromHeadings(spine, blocks);

  // --- cover -------------------------------------------------------------
  Uint8List? cover;
  final coverId = opf
          .findAllElements('meta', namespaceUri: '*')
          .where((e) => e.getAttribute('name') == 'cover')
          .map((e) => e.getAttribute('content'))
          .whereType<String>()
          .firstOrNull ??
      manifest.entries
          .where((e) => e.value.properties.contains('cover-image'))
          .map((e) => e.key)
          .firstOrNull;
  final coverHref = coverId == null ? null : manifest[coverId]?.href;
  if (coverHref != null) {
    final file = files[coverHref] ?? files[Uri.decodeFull(coverHref)];
    if (file != null) {
      cover = Uint8List.fromList(file.content as List<int>);
    }
  }

  final kept = [
    for (final chapter in chapters)
      if (chapter.text.length >= _minChapterChars &&
          !_isBoilerplate(chapter) &&
          !_isFrontMatter(chapter))
        chapter,
  ];
  if (kept.isEmpty) throw const EpubException('no chapters with any prose in them');

  return EpubBook(
    title: meta('title') ?? 'Untitled',
    author: meta('creator'),
    chapters: kept,
    cover: cover,
  );
}

/// Drops everything from the Project Gutenberg licence onwards.
///
/// Dropping a *chapter* that begins with the licence is not enough: the last
/// chapter has no navigation entry after it, so it runs to the end of the book
/// and swallows the licence whole. Alice's chapter XII came out with the entire
/// legal text stapled to it, which would then be classified and scored as if
/// Carroll had written it.
void _truncateAtLicence(List<String> spine, Map<String, List<_Block>> blocks) {
  const markers = [
    'START: FULL LICENSE',
    'END OF THE PROJECT GUTENBERG EBOOK',
    'END OF THIS PROJECT GUTENBERG EBOOK',
  ];
  for (final path in spine) {
    final list = blocks[path];
    if (list == null) continue;
    final cut = list.indexWhere(
      (b) => markers.any((m) => b.text.toUpperCase().contains(m)),
    );
    if (cut < 0) continue;
    blocks[path] = list.sublist(0, cut);
    // Everything after this document is licence too.
    for (final later in spine.skipWhile((s) => s != path).skip(1)) {
      blocks[later] = const [];
    }
    return;
  }
}

/// Tables of contents, illustration lists and title pages, told apart from
/// prose by shape rather than by title, so it works whatever they are called.
///
/// A chapter is long paragraphs; a list is many one-line entries. Alice's
/// contents page averages 18 characters per block and the *Carol*'s title
/// fragments 58 to 96, where a real chapter runs 300 to 500. Both conditions
/// have to hold, so a genuinely short chapter of ordinary prose survives.
bool _isFrontMatter(EpubChapter chapter) {
  final blocks = chapter.text.split('\n\n');
  final average = chapter.text.length / blocks.length;
  return average < 120 && chapter.text.length < 2000;
}

/// Project Gutenberg appends its licence as a final chapter-sized section. It
/// is real text and would otherwise be classified and scored like prose.
/// Narrow and deliberate: it drops that one thing and nothing else.
bool _isBoilerplate(EpubChapter chapter) {
  final head = chapter.text.length < 600 ? chapter.text : chapter.text.substring(0, 600);
  return head.contains('PROJECT GUTENBERG LICENSE') ||
      head.contains('START: FULL LICENSE') ||
      chapter.title.toUpperCase().contains('FULL PROJECT GUTENBERG');
}

XmlDocument _parse(String source) {
  var text = source;
  // Strip the DOCTYPE: it names an external DTD that cannot be fetched, and
  // its absence is what makes XHTML's named entities undefined.
  text = text.replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
  text = text.replaceAllMapped(RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);'), (match) {
    final name = match[1]!;
    if (name == 'amp' || name == 'lt' || name == 'gt' ||
        name == 'quot' || name == 'apos') {
      return match[0]!;
    }
    return _entities[name] ?? '';
  });
  try {
    return XmlDocument.parse(text);
  } catch (error) {
    throw EpubException('malformed XML ($error)');
  }
}

/// Flattens a document to blocks of text, deepest block element wins so a
/// `div` wrapping paragraphs does not emit them twice.
List<_Block> _blocksOf(String xhtml) {
  final XmlDocument document;
  try {
    document = _parse(xhtml);
  } on EpubException {
    return const []; // one unreadable document should not fail the whole book
  }

  final blocks = <_Block>[];
  final body = document.findAllElements('body', namespaceUri: '*').firstOrNull ??
      document.rootElement;

  // Ids seen on container elements, waiting for the next block to claim them.
  // Navigation anchors frequently sit on a wrapping `section` or `div` rather
  // than on the paragraph itself, and dropping those loses most of a book's
  // chapter boundaries.
  final pending = <String>{};

  void walk(XmlElement element) {
    final tag = element.localName.toLowerCase();
    final hasBlockChild = element.descendantElements
        .any((e) => _blockTags.contains(e.localName.toLowerCase()));

    if (_blockTags.contains(tag) && !hasBlockChild) {
      final text = _clean(element.innerText);
      final anchors = <String>{
        ...pending,
        ?element.getAttribute('id'),
        for (final e in element.descendantElements) ?e.getAttribute('id'),
      };
      pending.clear();
      if (text.isNotEmpty || anchors.isNotEmpty) {
        blocks.add(_Block(text, anchors, heading: _headingTags.contains(tag)));
      }
      return;
    }
    final id = element.getAttribute('id');
    if (id != null) pending.add(id);
    for (final child in element.childElements) {
      walk(child);
    }
  }

  walk(body);
  return blocks;
}

String _clean(String text) =>
    text.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Chapters from the book's own navigation, when it has one worth using.
List<EpubChapter>? _chaptersFromNav(
  XmlDocument opf,
  Map<String, ({String href, String type, String properties})> manifest,
  String Function(String) resolve,
  String? Function(String) readText,
  List<String> spine,
  Map<String, List<_Block>> blocks,
) {
  // EPUB 2 keeps it in an NCX; EPUB 3 in an XHTML nav document.
  final ncxHref = manifest.values
      .where((e) => e.type.contains('ncx') || e.href.endsWith('.ncx'))
      .map((e) => e.href)
      .firstOrNull;
  final navHref = manifest.values
      .where((e) => e.properties.contains('nav'))
      .map((e) => e.href)
      .firstOrNull;

  final targets = <({String label, String path, String? anchor})>[];

  if (ncxHref != null) {
    final ncx = readText(ncxHref);
    if (ncx != null) {
      final base = p.url.dirname(ncxHref);
      // Direct children of navMap only. navPoints nest, and the nested ones are
      // not chapters -- A Christmas Carol lists its Leech illustrations as
      // children of the staves they appear in, and following those cuts every
      // stave in half at the picture.
      final navMap = _parse(ncx)
          .findAllElements('navMap', namespaceUri: '*')
          .firstOrNull;
      final points = navMap == null
          ? const <XmlElement>[]
          : navMap.childElements.where((e) => e.localName == 'navPoint');
      for (final point in points) {
        // The label and src of *this* point, not of a nested one.
        final label = point
            .findElements('navLabel', namespaceUri: '*')
            .expand((e) => e.findAllElements('text', namespaceUri: '*'))
            .map((e) => _clean(e.innerText))
            .firstOrNull;
        final src = point
            .findElements('content', namespaceUri: '*')
            .map((e) => e.getAttribute('src'))
            .whereType<String>()
            .firstOrNull;
        if (label == null || src == null) continue;
        final hash = src.indexOf('#');
        final file = hash < 0 ? src : src.substring(0, hash);
        final anchor = hash < 0 ? null : src.substring(hash + 1);
        targets.add((
          label: label,
          path: p.url.normalize(p.url.join(base == '.' ? '' : base, file)),
          anchor: anchor,
        ));
      }
    }
  } else if (navHref != null) {
    final nav = readText(navHref);
    if (nav != null) {
      final base = p.url.dirname(navHref);
      for (final link in _parse(nav).findAllElements('a', namespaceUri: '*')) {
        final href = link.getAttribute('href');
        if (href == null) continue;
        final hash = href.indexOf('#');
        final file = hash < 0 ? href : href.substring(0, hash);
        targets.add((
          label: _clean(link.innerText),
          path: p.url.normalize(p.url.join(base == '.' ? '' : base, file)),
          anchor: hash < 0 ? null : href.substring(hash + 1),
        ));
      }
    }
  }

  if (targets.length < 2) return null;

  // Turn each target into a position in the flattened block stream.
  final flat = <_Block>[];
  final startOf = <String, int>{};
  for (final path in spine) {
    startOf[path] = flat.length;
    flat.addAll(blocks[path] ?? const []);
  }

  final cuts = <({String label, int index})>[];
  final used = <String>{};
  for (final target in targets) {
    final offset = startOf[target.path];
    if (offset == null) continue;
    var index = offset;
    if (target.anchor != null) {
      final within = (blocks[target.path] ?? const <_Block>[])
          .indexWhere((b) => b.anchors.contains(target.anchor));
      if (within >= 0) {
        index = offset + within;
      } else if (used.contains(target.path)) {
        // The anchor is gone and this file already has a chapter starting at
        // its top, so falling back there would put a second cut in the same
        // place -- ahead of the real last chapter, swallowing it. That is what
        // happens to the licence heading once its blocks are truncated away.
        continue;
      }
    }
    used.add(target.path);
    cuts.add((label: target.label, index: index));
  }
  if (cuts.length < 2) return null;
  cuts.sort((a, b) => a.index.compareTo(b.index));

  final chapters = <EpubChapter>[];
  for (var i = 0; i < cuts.length; i++) {
    final from = cuts[i].index;
    final to = i + 1 < cuts.length ? cuts[i + 1].index : flat.length;
    if (to <= from) continue;
    final text = flat
        .sublist(from, to)
        .map((b) => b.text)
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    chapters.add(EpubChapter(title: _title(cuts[i].label, i), text: text));
  }
  return chapters;
}

/// No usable navigation: cut on headings, and if there are none, per document.
List<EpubChapter> _chaptersFromHeadings(
  List<String> spine,
  Map<String, List<_Block>> blocks,
) {
  final flat = [for (final path in spine) ...?blocks[path]];
  final cuts = [
    for (var i = 0; i < flat.length; i++)
      if (flat[i].heading && flat[i].text.isNotEmpty) i,
  ];

  if (cuts.length < 2) {
    return [
      for (var i = 0; i < spine.length; i++)
        EpubChapter(
          title: 'Chapter ${i + 1}',
          text: (blocks[spine[i]] ?? const <_Block>[])
              .map((b) => b.text)
              .where((t) => t.isNotEmpty)
              .join('\n\n'),
        ),
    ];
  }

  final chapters = <EpubChapter>[];
  for (var i = 0; i < cuts.length; i++) {
    final from = cuts[i];
    final to = i + 1 < cuts.length ? cuts[i + 1] : flat.length;
    chapters.add(EpubChapter(
      title: _title(flat[from].text, i),
      text: flat
          .sublist(from, to)
          .map((b) => b.text)
          .where((t) => t.isNotEmpty)
          .join('\n\n'),
    ));
  }
  return chapters;
}

/// Chapter headings often carry an illustration caption ahead of the number --
/// "He rode a black horse. CHAPTER III." Prefer the part that names a chapter.
String _title(String raw, int index) {
  final text = _clean(raw);
  if (text.isEmpty) return 'Chapter ${index + 1}';
  final match = RegExp(
    r'((?:chapter|stave|book|part|canto)\s+[\dIVXLCM]+\.?)',
    caseSensitive: false,
  ).firstMatch(text);
  final chosen = match?.group(1) ?? text;
  return chosen.length > 70 ? '${chosen.substring(0, 67)}...' : chosen;
}
