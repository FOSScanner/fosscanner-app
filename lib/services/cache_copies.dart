import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path_provider/path_provider.dart';

import 'pdf_export_files.dart' show DirectoryProvider;

// Plugins copy documents into the app cache on Android and leave the copies
// there: share_plus copies every shared file into `cache/share_plus/` and only
// replaces it at the next share; image_picker copies each gallery image into
// `cache/<uuid>/<name>` and writes resized images to `cache/scaled_<name>`
// (camera captures start as `cache/<uuid><digits>.jpg`). These helpers remove
// those copies. They only look at the cache root and those two plugin layouts,
// never follow links, and never touch anything outside the app cache.

/// share_plus's folder for copies of shared files (Android).
const sharePlusCacheDirectoryName = 'share_plus';

final _exportFileName = RegExp(
  r'^Scan \d{4}-\d{2}-\d{2} \d{2}-\d{2}( \(searchable\))?\.pdf$',
);
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _cameraFile = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-?\d*\.jpg$',
);
final _scaledImage = RegExp(
  r'^scaled_.+\.(jpe?g|png|webp|gif|bmp|heic|heif)$',
  caseSensitive: false,
);

/// Whether [name] is a PDF name this app gives its exports (see
/// `pdfExportFileName`), so a share copy with that name is ours to remove.
bool isExportFileName(String name) => _exportFileName.hasMatch(name);

/// Whether [name] is image_picker's per-pick copy directory in the cache.
bool isImagePickerCopyDirectoryName(String name) => _uuid.hasMatch(name);

/// Whether [name] is a file image_picker leaves in the cache root: a resized
/// image (`scaled_*`) or a camera capture file.
bool isImagePickerCacheFileName(String name) =>
    _scaledImage.hasMatch(name) || _cameraFile.hasMatch(name);

String _nameOf(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);

String _parentOf(String path) {
  final index = path.lastIndexOf(Platform.pathSeparator);
  return index <= 0 ? path : path.substring(0, index);
}

/// The cache directory, resolved through links so paths compare reliably.
Future<String?> _cacheRoot(DirectoryProvider temporaryDirectory) async {
  try {
    return await (await temporaryDirectory()).resolveSymbolicLinks();
  } on FileSystemException {
    return null;
  }
}

void _reportFailure(String what, Object error) {
  if (kDebugMode) debugPrint('$what failed (${error.runtimeType}).');
}

/// Deletes share_plus's copies of exported PDFs, or only the copy named
/// [fileName] when given. Never throws.
Future<void> deleteSharedExportCopies({
  String? fileName,
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  try {
    final root = await _cacheRoot(temporaryDirectory);
    if (root == null) return;
    final folder = Directory(
      '$root${Platform.pathSeparator}$sharePlusCacheDirectoryName',
    );
    if (await FileSystemEntity.type(folder.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    await for (final entry in folder.list(followLinks: false)) {
      final name = _nameOf(entry);
      if (entry is! File || !isExportFileName(name)) continue;
      if (fileName != null && name != fileName) continue;
      try {
        await entry.delete();
      } on FileSystemException {
        // Best effort; the next launch tries again.
      }
    }
  } catch (error) {
    _reportFailure('Share copy cleanup', error);
  }
}

/// Deletes the image_picker copies left in the cache: `scaled_*` images,
/// camera capture files, and per-pick UUID directories that hold only files.
///
/// Call only while no pick is in progress and no lost picker result is
/// waiting to be read. Never throws.
Future<void> sweepImagePickerCopies({
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  try {
    final root = await _cacheRoot(temporaryDirectory);
    if (root == null) return;
    await for (final entry in Directory(root).list(followLinks: false)) {
      final name = _nameOf(entry);
      try {
        if (entry is File && isImagePickerCacheFileName(name)) {
          await entry.delete();
        } else if (entry is Directory && isImagePickerCopyDirectoryName(name)) {
          await _deleteFlatDirectory(entry);
        }
      } on FileSystemException {
        // Best effort; the next sweep tries again.
      }
    }
  } catch (error) {
    _reportFailure('Picker copy sweep', error);
  }
}

/// Deletes [directory] if it contains only regular files; anything nested
/// means it is not an image_picker copy and it is left alone.
Future<void> _deleteFlatDirectory(Directory directory) async {
  final entries = await directory.list(followLinks: false).toList();
  if (entries.any((entry) => entry is! File)) return;
  for (final entry in entries) {
    await entry.delete();
  }
  await directory.delete();
}

/// Whether [path] is an image_picker copy inside the app cache: a picker file
/// in the cache root, or a file directly inside a picker UUID directory.
/// Anything else, such as a user's original image, is never ours to delete.
Future<bool> isImagePickerCopy(
  String path, {
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  try {
    final root = await _cacheRoot(temporaryDirectory);
    if (root == null) return false;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final resolved = await File(path).resolveSymbolicLinks();
    final name = _nameOf(File(resolved));
    final parent = _parentOf(resolved);
    if (parent == root) return isImagePickerCacheFileName(name);
    return _parentOf(parent) == root &&
        isImagePickerCopyDirectoryName(_nameOf(Directory(parent)));
  } catch (_) {
    return false;
  }
}

/// Deletes [path] if it is an image_picker copy in the app cache (see
/// [isImagePickerCopy]), and its UUID directory once empty. Never throws.
Future<void> deleteImagePickerCopy(
  String path, {
  DirectoryProvider temporaryDirectory = getTemporaryDirectory,
}) async {
  try {
    if (!await isImagePickerCopy(
      path,
      temporaryDirectory: temporaryDirectory,
    )) {
      return;
    }
    final file = File(await File(path).resolveSymbolicLinks());
    await file.delete();
    final parent = file.parent;
    if (isImagePickerCopyDirectoryName(_nameOf(parent)) &&
        await parent.list(followLinks: false).isEmpty) {
      await parent.delete();
    }
  } on PathNotFoundException {
    // Already removed, typically by a concurrent [sweepImagePickerCopies]:
    // the copy is gone, which is all this was for.
  } catch (error) {
    _reportFailure('Picker copy cleanup', error);
  }
}
