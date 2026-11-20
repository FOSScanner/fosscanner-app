import 'package:flutter_test/flutter_test.dart';

import 'package:fosscanner/services/intake_report.dart';

void main() {
  test('groups digits', () {
    expect(groupDigits(0), '0');
    expect(groupDigits(999), '999');
    expect(groupDigits(8192), '8,192');
    expect(groupDigits(20000000), '20,000,000');
    expect(groupDigits(-1234), '-1,234');
  });

  test('a clean intake has nothing to report', () {
    expect(IntakeReport(total: 3).message, isNull);
  });

  test('a single rejected image gets the detailed explanation', () {
    final report = IntakeReport(total: 1)
      ..reject(IntakeRejection.unsupportedSize);
    expect(
      report.message,
      'This image is too small or has unsupported dimensions. '
      'Choose another image, or resize a large image and try again.',
    );
  });

  test('a batch gets one summary with a count per reason', () {
    final report = IntakeReport(total: 4)
      ..reject(IntakeRejection.unsupportedSize)
      ..reject(IntakeRejection.notImage);
    expect(
      report.message,
      "2 of 4 images couldn't be added: 1 unsupported size, 1 not an image.",
    );
  });

  test('reasons that read the same are counted together', () {
    final report = IntakeReport(total: 3)
      ..reject(IntakeRejection.unavailable)
      ..reject(IntakeRejection.unreadable);
    expect(
      report.message,
      "2 of 3 images couldn't be added: 2 unreadable files.",
    );
  });

  test('every image rejected omits "of"', () {
    final report = IntakeReport(total: 2)
      ..reject(IntakeRejection.notImage, count: 2);
    expect(report.message, "2 images couldn't be added: 2 not images.");
  });

  test('PDF intakes count pages', () {
    final report = IntakeReport(total: 5, noun: 'page')
      ..reject(IntakeRejection.notRendered);
    expect(
      report.message,
      "1 of 5 pages couldn't be added: 1 too large to render.",
    );
  });

  test('an early end follows the rejections, and the first end wins', () {
    final report = IntakeReport(total: 3)
      ..reject(IntakeRejection.fileTooLarge)
      ..end('Import stopped.')
      ..end('Page limit reached.');
    expect(
      report.message,
      "1 of 3 images couldn't be added: 1 file over 32 MB. Import stopped.",
    );
    expect(IntakeReport(total: 0).hasOutcome, isFalse);
  });

  test('zero counts are ignored', () {
    final report = IntakeReport(total: 2)
      ..reject(IntakeRejection.unavailable, count: 0);
    expect(report.rejected, 0);
    expect(report.message, isNull);
  });
}
