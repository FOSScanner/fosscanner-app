import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path_provider/path_provider.dart';

/// Prefix of the per-export cache directories holding a finished PDF.
///
/// Each export gets its own directory so the PDF can carry its user-facing
/// file name (share targets see the real file name) without colliding with an
/// earlier export that has not been removed yet.
const pdfExportDirectoryPrefix = 'fosscanner_export_';

typedef DirectoryProvider = Future<Directory> Function();

/// A cache directory owning one exported PDF until it has been handed off.
class PdfExportDirectory {
  PdfExportDirectory._(this.directory);

  final Directory directory;

  /// Where an exporter should write a PDF called [fileName].
  File fileNamed(String fileName) => File('${directory.path}/$fileName');

  /// Removes the directory and anything an exporter left in it.
  ///
  /// Synchronous so the export flow can release its file before it unlocks
  /// the UI: it removes at most one file, which unlinks quickly regardless of
  /// size. Best effort: a failure leaves the files for [sweepStalePdfExports].
  void delete() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      if (kDebugMode) {
        debugPrint('Export cleanup failed (${error.runtimeType}).');
      }
    }
  }
}

/// Creates a fresh export directory in the app's cache.
Future<PdfExportDirectory> createPdfExportDirectory({
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  final cache = await temporaryDirectory();
  return PdfExportDirectory._(await cache.createTemp(pdfExportDirectoryPrefix));
}

/// Deletes export directories left behind by a previous process, for example
/// when the app was killed while the share sheet was open.
///
/// Call once at startup, before any export can begin. Never throws.
Future<void> sweepStalePdfExports({
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  try {
    final cache = await temporaryDirectory();
    await for (final entry in cache.list(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
      );
      if (entry is Directory && name.startsWith(pdfExportDirectoryPrefix)) {
        try {
          await entry.delete(recursive: true);
        } on FileSystemException {
          // Best effort; the next launch tries again.
        }
      }
    }
  } catch (error) {
    if (kDebugMode) {
      debugPrint('Stale export sweep failed (${error.runtimeType}).');
    }
  }
}

/// The default name of an exported PDF, used for both sharing and saving.
///
/// Locale-independent so it sorts by date everywhere, e.g.
/// `Scan 2026-11-19 14-05.pdf` or `Scan 2026-11-19 14-05 (searchable).pdf`.
String pdfExportFileName(DateTime time, {required bool searchable}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final date =
      '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)}';
  final clock = '${two(time.hour)}-${two(time.minute)}';
  return sanitizePdfFileName(
    'Scan $date $clock${searchable ? ' (searchable)' : ''}.pdf',
  );
}

const _searchableSuffix = ' (searchable).pdf';

/// [fileName] without the ` (searchable)` marker [pdfExportFileName] adds,
/// for an export that fell back to an image-only PDF; null when [fileName]
/// does not end with it (for example because the user renamed the file).
String? withoutSearchableSuffix(String fileName) {
  if (!fileName.toLowerCase().endsWith(_searchableSuffix)) return null;
  final base = fileName.substring(
    0,
    fileName.length - _searchableSuffix.length,
  );
  return base.trim().isEmpty ? null : sanitizePdfFileName('$base.pdf');
}

const _maxFileNameBaseLength = 100;

/// Makes [name] safe as a single file name on Android, iOS and common
/// receiving systems: no path separators, reserved or control characters,
/// no leading dots, bounded length, always ending in `.pdf`.
String sanitizePdfFileName(String name) {
  var base = name
      .replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (base.toLowerCase().endsWith('.pdf')) {
    base = base.substring(0, base.length - 4);
  }
  // Leading dots would hide the file on many systems.
  base = base.replaceFirst(RegExp(r'^[.\s]+'), '').trim();
  if (base.isEmpty) base = 'Scan';
  if (base.length > _maxFileNameBaseLength) {
    base = base.substring(0, _maxFileNameBaseLength).trim();
  }
  return '$base.pdf';
}
