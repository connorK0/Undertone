import 'package:flutter/foundation.dart';

import 'mood_pipeline.dart';

enum ReadingMode { pages, scroll }

/// Where the reader is right now, and what told us.
class ReadingPosition {
  const ReadingPosition({
    required this.paragraphIndex,
    required this.mode,
    required this.reason,
    this.page,
    this.pageCount,
  });

  final int paragraphIndex;
  final ReadingMode mode;

  /// What produced this position: 'opened', 'page turn' or 'scroll settled'.
  final String reason;

  /// 1-based, paginated mode only.
  final int? page;
  final int? pageCount;

  String describe() {
    final where = mode == ReadingMode.pages ? 'page $page/$pageCount' : 'scroll';
    return 'paragraph $paragraphIndex ($where, $reason)';
  }
}

class MoodTriggerEvent {
  const MoodTriggerEvent(this.number, this.position, this.at);

  final int number;
  final ReadingPosition position;
  final DateTime at;
}

/// The pipeline that answers a trigger. Set once, in main().
///
/// Null in the widget tests that only exercise the readers' trigger timing,
/// which is why every use below is null-safe.
MoodPipeline? moodPipeline;

/// The one place the mood pipeline plugs in.
///
/// Called exactly once when a book is opened, once per page turn, and once
/// each time a scroll settles. It records the trigger and hands the position
/// to the pipeline, which keeps the paragraphs around the reader tagged.
void onMoodTrigger(ReadingPosition position) {
  final number = (lastMoodTrigger.value?.number ?? 0) + 1;
  debugPrint('[mood] #$number ${position.describe()}');
  lastMoodTrigger.value = MoodTriggerEvent(number, position, DateTime.now());
  moodPipeline?.onPosition(position.paragraphIndex);
}

/// The most recent trigger, for the on-screen banner and for tests.
final ValueNotifier<MoodTriggerEvent?> lastMoodTrigger = ValueNotifier(null);

int get moodTriggerCount => lastMoodTrigger.value?.number ?? 0;

void resetMoodTriggerLog() => lastMoodTrigger.value = null;
