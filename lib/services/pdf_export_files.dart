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
