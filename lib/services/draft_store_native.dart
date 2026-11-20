import 'dart:async';
import 'dart:convert' hide Codec;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';

import '../models/scanned_page.dart';
import 'draft_session_lock.dart';
import 'draft_store_base.dart';
import 'image_metadata.dart';

const _schemaVersion = 1;
const _maxManifestBytes = 1024 * 1024;
const _manifestName = 'manifest.json';

enum DraftLoadStage {
  beforeCurrentRead,
  beforeBackupRead,
  beforeBackupPromotion,
}

typedef DraftLoadHook = FutureOr<void> Function(DraftLoadStage stage);

enum DraftSaveStage { afterStaging, afterCurrentMoved }

typedef DraftSaveHook = FutureOr<void> Function(DraftSaveStage stage);

class _DraftPageFiles {
  const _DraftPageFiles({
    required this.original,
    required this.processed,
    required this.corners,
    required this.filter,
    required this.rotation,
    required this.brightness,
    required this.contrast,
    required this.sourceDpi,
  });

  final File original;
  final File processed;
  final List<Offset> corners;
  final PageFilter filter;
  final int rotation;
  final double brightness;
  final double contrast;
  final double? sourceDpi;
}

DraftStore createDraftStore() => FileDraftStore();

/// Native, app-private cache for the current in-progress document.
///
/// Acquire [acquireSession] before using the store in an app session.
///
/// [directory] is the draft root itself when supplied. It exists so tests can
/// exercise the real filesystem protocol without invoking path_provider.
class FileDraftStore implements DraftStore, DraftSessionStore {
  FileDraftStore({this.directory, this.beforeCommit, this.beforeLoad});

  final Directory? directory;
  final DraftSaveHook? beforeCommit;
  final DraftLoadHook? beforeLoad;
  bool _hasLoaded = false;
  bool _restoreFailed = false;
  DraftSessionLock? _sessionLock;

  @override
  Future<void> acquireSession() async {
    final root = await _root();
    _sessionLock ??= DraftSessionLock(root);
    await _sessionLock!.acquire();
  }

  Future<Directory> _root() async {
    final supplied = directory;
    if (supplied != null) return supplied;
    final cache = await getApplicationCacheDirectory();
    return Directory('${cache.path}${Platform.pathSeparator}draft');
  }

  @override
  Future<List<ScannedPage>> load() async {
    // Keep saves blocked after any failed read/promotion, including callers
    // that catch the exception. Only a successful retry or explicit clear
    // authorizes replacing the existing generations.
    _restoreFailed = true;
    try {
      final pages = await _loadDraft();
      _hasLoaded = true;
      _restoreFailed = false;
      return pages;
    } catch (_) {
      throw const DraftRestoreException();
    }
  }

  Future<List<ScannedPage>> _loadDraft() async {
    final root = await _root();
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) return const [];
    if (rootType != FileSystemEntityType.directory) {
      throw const DraftRestoreException();
    }
    final current = Directory('${root.path}${Platform.pathSeparator}current');
    final backup = Directory('${root.path}${Platform.pathSeparator}backup');
    final currentType = await FileSystemEntity.type(
      current.path,
      followLinks: false,
    );
    try {
      await beforeLoad?.call(DraftLoadStage.beforeCurrentRead);
      if (currentType == FileSystemEntityType.directory) {
        final pages = await _loadDirectory(current);
        if (pages != null) return pages;
      }
    } catch (_) {
      // Try the previous committed generation without treating a read failure
      // as an absent draft.
      if (currentType == FileSystemEntityType.notFound) rethrow;
    }

    final backupType = await FileSystemEntity.type(
      backup.path,
      followLinks: false,
    );
    if (currentType == FileSystemEntityType.notFound &&
        backupType == FileSystemEntityType.notFound) {
      return const [];
    }
    if (backupType != FileSystemEntityType.directory) {
      throw const DraftRestoreException();
    }
    await beforeLoad?.call(DraftLoadStage.beforeBackupRead);
    final pages = await _loadDirectory(backup);
    if (pages == null) throw const DraftRestoreException();
    // Refuse to follow or replace an unexpected filesystem entry. A valid
    // backup stays untouched if promotion cannot complete.
    if (currentType != FileSystemEntityType.notFound &&
        currentType != FileSystemEntityType.directory) {
      throw const DraftRestoreException();
    }
    if (await current.exists()) await current.delete(recursive: true);
    await beforeLoad?.call(DraftLoadStage.beforeBackupPromotion);
    await backup.rename(current.path);
    return pages;
  }

  Future<List<ScannedPage>?> _loadDirectory(Directory directory) async {
    if (!await directory.exists()) return null;
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}$_manifestName',
    );
    if (!await manifestFile.exists() ||
        await manifestFile.length() > _maxManifestBytes) {
      return null;
    }

    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded['schemaVersion'] != _schemaVersion ||
        decoded['pages'] is! List<Object?>) {
      return null;
    }

    final entries = decoded['pages']! as List<Object?>;
    if (entries.length > maxDocumentPages) return null;
    final pageFiles = <_DraftPageFiles>[];
    var retainedBytes = 0;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry is! Map<String, Object?>) return null;
      final corners = _decodeCorners(entry['corners']);
      final filter = _decodeFilter(entry['filter']);
      final rotation = entry['rotationQuarterTurns'];
      final brightness = _finiteDouble(entry['brightness']);
      final contrast = _finiteDouble(entry['contrast']);
      if (corners == null ||
          filter == null ||
          rotation is! int ||
          brightness == null ||
          contrast == null ||
          !_validPageMetadata(
            corners,
            rotation: rotation,
            brightness: brightness,
            contrast: contrast,
          )) {
        return null;
      }

      final original = File(
        '${directory.path}${Platform.pathSeparator}page_${index}_original.bin',
      );
      final processed = File(
        '${directory.path}${Platform.pathSeparator}page_${index}_processed.bin',
      );
      if (!await original.exists() || !await processed.exists()) return null;
      final originalLength = await original.length();
      final processedLength = await processed.length();
      final pageBytes = originalLength + processedLength;
      if (!canRetainDocument(
        currentBytes: retainedBytes,
        currentPages: index,
        incomingBytes: pageBytes,
      )) {
        return null;
      }
      retainedBytes += pageBytes;
      if (originalLength == 0 || processedLength == 0) return null;
      pageFiles.add(
        _DraftPageFiles(
          original: original,
          processed: processed,
          corners: corners,
          filter: filter,
          rotation: rotation,
          brightness: brightness,
          contrast: contrast,
          // Optional: drafts written before it existed, or with a value out
          // of range, export at the default "Original" density.
          sourceDpi: validSourceDpi(entry['sourceDpi']),
        ),
      );
    }

    final pages = <ScannedPage>[];
    for (final files in pageFiles) {
      final originalBytes = await files.original.readAsBytes();
      final processedBytes = await files.processed.readAsBytes();
      validateSourceImageSize(await readEncodedImageSize(originalBytes));
      validateProcessedImageSize(await readEncodedImageSize(processedBytes));
      await _decodeFirstFrame(originalBytes);
      await _decodeFirstFrame(processedBytes);
      pages.add(
        ScannedPage(
          originalBytes: originalBytes,
          processedBytes: processedBytes,
          corners: files.corners,
          filter: files.filter,
          rotationQuarterTurns: files.rotation,
          brightness: files.brightness,
          contrast: files.contrast,
          sourceDpi: files.sourceDpi,
        ),
      );
    }
    return pages;
  }

  Future<void> _decodeFirstFrame(Uint8List bytes) async {
    Codec? codec;
    FrameInfo? frame;
    try {
      codec = await instantiateImageCodec(
        bytes,
        targetWidth: 1,
        targetHeight: 1,
      );
      final decodedFrame = await codec.getNextFrame();
      frame = decodedFrame;
      if (decodedFrame.image.width <= 0 || decodedFrame.image.height <= 0) {
        throw const FormatException('Decoded image frame is empty');
      }
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  List<Offset>? _decodeCorners(Object? value) {
    if (value is! List<Object?>) return null;
    final corners = <Offset>[];
    for (final encoded in value) {
      if (encoded is! List<Object?> || encoded.length != 2) return null;
      final x = _finiteDouble(encoded[0]);
      final y = _finiteDouble(encoded[1]);
      if (x == null || y == null) return null;
      corners.add(Offset(x, y));
    }
    return corners;
  }

  bool _validPageMetadata(
    List<Offset> corners, {
    required int rotation,
    required double brightness,
    required double contrast,
  }) =>
      corners.length == 4 &&
      corners.toSet().length == 4 &&
      corners.every((corner) => corner.dx.isFinite && corner.dy.isFinite) &&
      rotation >= 0 &&
      rotation <= 3 &&
      brightness >= -100 &&
      brightness <= 100 &&
      contrast >= 0.5 &&
      contrast <= 2;

  PageFilter? _decodeFilter(Object? value) {
    if (value is! String) return null;
    for (final filter in PageFilter.values) {
      if (filter.name == value) return filter;
    }
    return null;
  }

  double? _finiteDouble(Object? value) {
    if (value is! num) return null;
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  @override
  Future<void> save(List<ScannedPage> pages) async {
    if (_restoreFailed) throw const DraftRestoreException();
    // Also protect callers that create a fresh store and save without loading.
    if (!_hasLoaded) await load();
    if (pages.length > maxDocumentPages) {
      throw const FormatException('Draft has too many pages');
    }
    var retainedBytes = 0;
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final pageBytes = page.originalBytes.length + page.processedBytes.length;
      if (page.originalBytes.isEmpty ||
          page.processedBytes.isEmpty ||
          !_validPageMetadata(
            page.corners,
            rotation: page.rotationQuarterTurns,
            brightness: page.brightness,
            contrast: page.contrast,
          ) ||
          !canRetainDocument(
            currentBytes: retainedBytes,
            currentPages: index,
            incomingBytes: pageBytes,
          )) {
        throw const FormatException('Draft page is invalid');
      }
      retainedBytes += pageBytes;
    }

    final root = await _root();
    await root.create(recursive: true);
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');
    final current = Directory('${root.path}${Platform.pathSeparator}current');
    final backup = Directory('${root.path}${Platform.pathSeparator}backup');

    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create();
    var currentMoved = false;
    try {
      final manifestPages = <Map<String, Object?>>[];
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        await File(
          '${staging.path}${Platform.pathSeparator}page_${index}_original.bin',
        ).writeAsBytes(page.originalBytes, flush: true);
        await File(
          '${staging.path}${Platform.pathSeparator}page_${index}_processed.bin',
        ).writeAsBytes(page.processedBytes, flush: true);
        manifestPages.add({
          'corners': [
            for (final corner in page.corners) [corner.dx, corner.dy],
          ],
          'filter': page.filter.name,
          'rotationQuarterTurns': page.rotationQuarterTurns,
          'brightness': page.brightness,
          'contrast': page.contrast,
          // Optional, so older app versions still read this schema version.
          'sourceDpi': ?page.sourceDpi,
        });
      }
      await File(
        '${staging.path}${Platform.pathSeparator}$_manifestName',
      ).writeAsString(
        jsonEncode({'schemaVersion': _schemaVersion, 'pages': manifestPages}),
        flush: true,
      );
      await beforeCommit?.call(DraftSaveStage.afterStaging);

      if (await backup.exists()) await backup.delete(recursive: true);
      if (await current.exists()) {
        await current.rename(backup.path);
        currentMoved = true;
      }
      await beforeCommit?.call(DraftSaveStage.afterCurrentMoved);
      await staging.rename(current.path);
    } catch (_) {
      if (currentMoved && !await current.exists() && await backup.exists()) {
        await backup.rename(current.path);
      }
      rethrow;
    } finally {
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {
          // A stale staging directory is ignored and replaced on the next save.
        }
      }
    }
  }

  @override
  Future<void> clear() async {
    final root = await _root();
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw const DraftRestoreException();
    }
    for (final name in const ['staging', 'current', 'backup']) {
      final path = '${root.path}${Platform.pathSeparator}$name';
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type == FileSystemEntityType.link) {
        await Link(path).delete();
      } else if (type != FileSystemEntityType.notFound) {
        throw const DraftRestoreException();
      }
    }
    _hasLoaded = true;
    _restoreFailed = false;
  }
}
