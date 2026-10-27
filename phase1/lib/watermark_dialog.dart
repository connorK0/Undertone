import 'package:flutter/material.dart';

import 'watermark.dart';

/// Shows what would be removed, and asks.
///
/// This dialog is the feature's actual guarantee. The rules in watermark.dart
/// make the list short enough to read; a person reading it is what makes the
/// removal safe. So it shows the literal text, how many times it appears, in
/// how many chapters, and how much of the book it adds up to -- everything
/// needed to say no.
///
/// Returns the canonical keys to remove, or null if the reader kept everything.
Future<Set<String>?> confirmWatermarks(
  BuildContext context, {
  required String title,
  required List<Watermark> found,
  required int totalChars,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => _WatermarkDialog(
      title: title,
      found: found,
      totalChars: totalChars,
    ),
  );
}

class _WatermarkDialog extends StatefulWidget {
  const _WatermarkDialog({
    required this.title,
    required this.found,
    required this.totalChars,
  });

  final String title;
  final List<Watermark> found;
  final int totalChars;

  @override
  State<_WatermarkDialog> createState() => _WatermarkDialogState();
}

class _WatermarkDialogState extends State<_WatermarkDialog> {
  late final Set<String> _chosen = {
    for (final mark in widget.found) mark.canonical,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final removed = _chosen.isEmpty
        ? 0
        : widget.found
            .where((m) => _chosen.contains(m.canonical))
            .fold<int>(0, (n, m) => n + m.sample.length * m.occurrences);
    final share = widget.totalChars == 0
        ? 0.0
        : 100 * removed / widget.totalChars;

    return AlertDialog(
      title: const Text('Repeated lines found'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These lines repeat through "${widget.title}" and point the '
              'reader somewhere else, which is what a distributor\'s stamp '
              'does and what an author\'s prose does not. Nothing is removed '
              'unless you say so.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.found.length,
                itemBuilder: (context, i) {
                  final mark = widget.found[i];
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _chosen.contains(mark.canonical),
                    onChanged: (on) => setState(() {
                      if (on ?? false) {
                        _chosen.add(mark.canonical);
                      } else {
                        _chosen.remove(mark.canonical);
                      }
                    }),
                    title: Text(
                      mark.sample,
                      style: const TextStyle(fontFamily: 'Consolas'),
                    ),
                    subtitle: Text(
                      '${mark.occurrences} times in ${mark.chapters} '
                      'chapter${mark.chapters == 1 ? '' : 's'} · '
                      '${mark.reason}'
                      '${mark.inline ? ' · sits at the end of a paragraph, '
                          'and only that sentence is cut' : ''}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 24),
            // The number that says at a glance whether something has gone
            // wrong. A watermark clean is a fraction of a percent of a book;
            // anything that looks like a chapter is not a watermark.
            Text(
              _chosen.isEmpty
                  ? 'Nothing selected — the book will be left exactly as it is.'
                  : 'Removes about $removed characters, '
                      '${share.toStringAsFixed(2)}% of the book. '
                      'Everything else is left exactly as it is.',
              style: text.bodySmall?.copyWith(
                color: share > 2 ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep everything'),
        ),
        FilledButton(
          onPressed:
              _chosen.isEmpty ? null : () => Navigator.of(context).pop(_chosen),
          child: const Text('Remove selected'),
        ),
      ],
    );
  }
}
