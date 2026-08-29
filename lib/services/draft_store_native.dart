import 'dart:async';
import 'dart:convert' hide Codec;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';

import '../models/scanned_page.dart';
import 'draft_store_base.dart';
import 'image_metadata.dart';

const _schemaVersion = 1;
const _maxManifestBytes = 1024 * 1024;
const _manifestName = 'manifest.json';

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
  });

  final File original;
  final File processed;
  final List<Offset> corners;
  final PageFilter filter;
  final int rotation;
  final double brightness;
  final double contrast;
}

DraftStore createDraftStore() => FileDraftStore();

/// Native, app-private cache for the current in-progress document.
///
/// [directory] is the draft root itself when supplied. It exists so tests can
/// exercise the real filesystem protocol without invoking path_provider.
class FileDraftStore implements DraftStore {
  FileDraftStore({this.directory, this.beforeCommit});

  final Directory? directory;
  final DraftSaveHook? beforeCommit;

  Future<Directory> _root() async {
    final supplied = directory;
    if (supplied != null) return supplied;
    final cache = await getApplicationCacheDirectory();
    return Directory('${cache.path}${Platform.pathSeparator}draft');
  }

  @override
  Future<List<ScannedPage>> load() async {
    final root = await _root();
    final current = Directory('${root.path}${Platform.pathSeparator}current');
    final backup = Directory('${root.path}${Platform.pathSeparator}backup');
    try {
      final pages = await _loadDirectory(current);
      if (pages != null) return pages;
    } catch (_) {
      // A partial write, unsupported schema, or corrupt image is not fatal.
    }

    try {
      final pages = await _loadDirectory(backup);
      if (pages == null) return const [];
      // Keep the recovered generation in the current slot. A subsequent save
      // can then move it to backup before committing its replacement.
      if (await current.exists()) await current.delete(recursive: true);
      await backup.rename(current.path);
      return pages;
    } catch (_) {
      // Leave any valid backup in place if promotion fails so a later restart
      // can retry recovery rather than accepting a partial generation.
      return const [];
    }
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
        ),
      );
    }

    final pages = <ScannedPage>[];
    for (final files in pageFiles) {
      final originalBytes = await files.original.readAsBytes();
      final processedBytes = await files.processed.readAsBytes();
      validateSourceImageSize(await readEncodedImageSize(originalBytes));
      validateSourceImageSize(await readEncodedImageSize(processedBytes));
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
    if (!await root.exists()) return;
    for (final name in const ['staging', 'current', 'backup']) {
      final directory = Directory('${root.path}${Platform.pathSeparator}$name');
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}
