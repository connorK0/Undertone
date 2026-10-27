/// A workspace as one file, for carrying to a device that plays it.
///
/// A phone cannot prepare a book -- no local model for tagging, no GPU for
/// MusicGen -- so books are prepared elsewhere and carried over. A pack is a
/// zip of the workspace minus what only preparation needs:
///
///   * `jobs/`, the over-generated pools kept for re-culling (~570 MB an arc);
///   * `*.raw.wav`, the model's unlooped output beside every bed, kept only to
///     tell a bad generation from a bad loop-fix -- nearly half of a set;
///   * `*.tmp`, a write in flight.
///
/// Unpacking replaces an older copy of the same book but keeps its
/// `reader.json`, so re-packing a book after generating another arc does not
/// cost the reader their place.
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'workspace.dart';

/// Whether [relative] (a path inside a workspace, '/'-separated) travels.
bool travels(String relative) {
  final parts = relative.split('/');
  if (parts.first == 'jobs') return false;
  final name = parts.last;
  return !name.endsWith('.raw.wav') && !name.endsWith('.tmp');
}

/// Zip [ws] to [zipPath]. Returns how many files went in.
Future<int> packWorkspace(Workspace ws, String zipPath) async {
  final encoder = ZipFileEncoder()..create(zipPath);
  var count = 0;
  try {
    final files = ws.directory
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => (
              file: f,
              name: p.relative(f.path, from: ws.directory.path)
                  .replaceAll(r'\', '/'),
            ))
        .where((f) => travels(f.name))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final f in files) {
      await encoder.addFile(f.file, f.name);
      count++;
    }
  } finally {
    await encoder.close();
  }
  return count;
}

/// Unpack a pack into `booksDir/<book id>/` and open it.
///
/// Extracted beside the destination first and swapped in only once it opens
/// as a workspace, so a truncated or foreign zip never replaces a good book.
/// The extractor refuses entries that would land outside the target.
Future<Workspace> unpackWorkspace(String zipPath, String booksDir) async {
  final staging = Directory(p.join(booksDir,
      '.unpacking-${DateTime.now().microsecondsSinceEpoch}'));
  await staging.create(recursive: true);
  try {
    await extractFileToDisk(zipPath, staging.path);
    final unpacked = await Workspace.open(staging.path);
    final target = Directory(p.join(booksDir, unpacked.bookId));
    if (await target.exists()) {
      final place = File(p.join(target.path, 'reader.json'));
      if (await place.exists()) {
        await place.copy(p.join(staging.path, 'reader.json'));
      }
      await target.delete(recursive: true);
    }
    await staging.rename(target.path);
    return await Workspace.open(target.path);
  } catch (_) {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }
}
