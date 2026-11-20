import 'dart:math' as math;

import 'image_metadata.dart';

/// Why one image (or PDF page) of an intake was not added.
enum IntakeRejection {
  /// Smaller than 3 × 3 px or above the edge or pixel limit.
  unsupportedSize('unsupported size', 'unsupported size'),

  /// The bytes could be read but are not a decodable image.
  notImage('not an image', 'not images'),

  /// The file could not be read at all.
  unreadable('unreadable file', 'unreadable files'),

  /// The encoded file is above [maxEncodedImageBytes].
  fileTooLarge('file over $_maxMegabytes MB', 'files over $_maxMegabytes MB'),

  /// Decoding it would exceed the image-processing memory budget.
  needsTooMuchMemory('too large to process', 'too large to process'),

  /// The platform could not hand the shared item over: not an image type,
  /// an unreadable URI, or over the size limit.
  unavailable('unreadable file', 'unreadable files'),

  /// A PDF page could not be rendered within the per-image limits.
  notRendered('too large to render', 'too large to render');

  const IntakeRejection(this.singular, this.plural);

  final String singular;
  final String plural;
}

const _maxMegabytes = maxEncodedImageBytes ~/ (1024 * 1024);

/// Formats [value] with comma thousands separators ("20,000,000").
String groupDigits(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// The explanation shown when a single image is rejected.
String intakeRejectionMessage(IntakeRejection reason) => switch (reason) {
  IntakeRejection.unsupportedSize =>
    'This image is too small or has unsupported dimensions. '
        'Choose another image, or resize a large image and try again.',
  IntakeRejection.notImage ||
  IntakeRejection.unreadable => 'Could not read this image.',
  IntakeRejection.fileTooLarge =>
    'This image is too large. Choose a file under $_maxMegabytes MB.',
  IntakeRejection.needsTooMuchMemory =>
    'Not enough memory for this image. Remove pages or choose a smaller '
        'image.',
  // The platform does not say why (not an image, no access, or over the
  // size limit), so the message names no cause.
  IntakeRejection.unavailable => 'Could not open the shared file.',
  IntakeRejection.notRendered => 'This PDF page is too large to add.',
};

/// Collects what happened to the items of one intake (a gallery selection,
/// a share, recovered picker results, a PDF, or one camera capture) so the
/// user gets one message after the review instead of one per item that the
/// next review route would hide.
class IntakeReport {
  IntakeReport({required this.total, this.noun = 'image'});

  /// Items in the intake, including those rejected before review.
  final int total;

  /// What an item is called in the summary ("image" or "page").
  final String noun;

  final _rejections = <IntakeRejection, int>{};

  /// Why the intake ended before every item was reviewed, if it did.
  String? _outcome;

  final _notes = <String>[];

  /// Items added as pages so far.
  int added = 0;

  int get rejected => _rejections.values.fold(0, (sum, count) => sum + count);

  Map<IntakeRejection, int> get rejections => Map.unmodifiable(_rejections);

  String? get outcome => _outcome;

  bool get hasOutcome => _outcome != null;

  void reject(IntakeRejection reason, {int count = 1}) {
    if (count <= 0) return;
    _rejections.update(reason, (value) => value + count, ifAbsent: () => count);
  }

  /// Records why the intake ended early. The first reason wins: later items
  /// are not reviewed after it.
  void end(String message) => _outcome ??= message;

  /// Adds something the user should know about pages that were added, said
  /// once after the rest of the summary.
  void note(String message) {
    if (!_notes.contains(message)) _notes.add(message);
  }

  /// One message for the whole intake, or null when there is nothing to say.
  String? get message {
    final parts = <String>[];
    final count = rejected;
    if (count == 1 && total == 1) {
      parts.add(intakeRejectionMessage(_rejections.keys.single));
    } else if (count > 0) {
      // "1 of 3 images", "2 images".
      final ofTotal = count < total ? ' of ${groupDigits(total)}' : '';
      final nouns = math.max(count, total) == 1 ? noun : '${noun}s';
      // Reasons that read the same (an unreadable share and an unreadable
      // file) are counted together.
      final byLabel = <IntakeRejection, int>{};
      for (final MapEntry(key: reason, value: n) in _rejections.entries) {
        final label = IntakeRejection.values.firstWhere(
          (other) => other.singular == reason.singular,
        );
        byLabel.update(label, (value) => value + n, ifAbsent: () => n);
      }
      final reasons = [
        for (final reason in IntakeRejection.values)
          if (byLabel[reason] case final n?)
            '${groupDigits(n)} ${n == 1 ? reason.singular : reason.plural}',
      ];
      parts.add(
        '${groupDigits(count)}$ofTotal $nouns couldn\'t be added: '
        '${reasons.join(', ')}.',
      );
    }
    if (_outcome case final outcome?) parts.add(outcome);
    parts.addAll(_notes);
    return parts.isEmpty ? null : parts.join(' ');
  }
}
