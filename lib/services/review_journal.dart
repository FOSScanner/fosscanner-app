import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/scanned_page.dart' show validSourceDpi;

/// Images whose review was interrupted when the app was closed or killed.
class InterruptedReview {
  const InterruptedReview({
    required this.source,
    this.paths = const [],
    this.unresumable = 0,
    this.sourceDpis = const [],
  });

  /// The intake's source, as the name of a `PageReviewSource`.
  final String source;

  /// App-owned images that can be reviewed again, in order.
  final List<String> paths;

  /// The source density of each of [paths] (see `ScannedPage.sourceDpi`),
  /// null where unknown. Empty when the review recorded none.
  final List<double?> sourceDpis;

  /// Images that were not added and could not be kept: the user's own gallery
  /// images, which are never copied.
  final int unresumable;
}

/// Remembers the images of a running review, so a process that dies while
/// one is on screen does not lose the rest of the intake without a word.
///
/// Only app-owned files are kept: camera captures and the app's own copies
/// of shared, recovered and PDF-rendered images. They are moved (not copied)
/// into an app-private folder next to the draft and deleted as soon as each
/// one has been reviewed. Gallery images are the user's originals; for them
/// only the number still waiting is recorded.
abstract interface class ReviewJournal {
  /// Starts journaling a review of the app-owned files at [paths].
  ///
  /// Returns the paths to read instead, in order; a file that could not be
  /// moved keeps its own path. Replaces any earlier journal. Never throws.
  ///
  /// [sourceDpis], when given, holds each file's source density and is
  /// returned with it by [read].
  Future<List<String>> keep(
    String source,
    List<String> paths, {
    List<double?>? sourceDpis,
  });

  /// Records that [count] gallery images are still waiting for review.
  /// Never throws.
  Future<void> notePending(String source, int count);

  /// Whether [path] was returned by [keep] and is deleted by [release].
  bool owns(String path);

  /// Deletes a reviewed file returned by [keep]. Never throws.
  Future<void> release(String path);

  /// The interrupted review left by an earlier run, if any. Never throws.
  Future<InterruptedReview?> read();

  /// Deletes the journal and every file it kept. Never throws.
  Future<void> clear();
}

/// The journal of native builds, inside the app cache's draft folder.
///
/// [directory] is the journal folder itself when supplied, for tests.
class FileReviewJournal implements ReviewJournal {
  FileReviewJournal({this.directory});

  final Directory? directory;
  String? _rootPath;

  static const _manifestName = 'journal.json';
  static const _version = 1;
  static const _maxManifestBytes = 64 * 1024;
  static final _itemName = RegExp(r'^item_\d{1,20}_\d{1,4}\.img$');

  Future<Directory> _root() async {
    final known = _rootPath;
    if (known != null) return Directory(known);
    final supplied = directory;
    final Directory root;
    if (supplied != null) {
      root = supplied;
    } else {
      final cache = await getApplicationCacheDirectory();
      // Beside the draft generations; DraftStore.clear leaves it alone.
      root = Directory(
        [cache.path, 'draft', 'review'].join(Platform.pathSeparator),
      );
    }
    _rootPath = root.absolute.path;
    return Directory(_rootPath!);
  }

  String _join(Directory root, String name) =>
      '${root.path}${Platform.pathSeparator}$name';

  String _nameOf(String path) => path.split(Platform.pathSeparator).last;

  @override
  bool owns(String path) {
    final root = _rootPath;
    if (root == null) return false;
    final file = File(path).absolute;
    return file.parent.path == root && _itemName.hasMatch(_nameOf(file.path));
  }

  Future<void> _writeManifest(
    Directory root,
    Map<String, Object> manifest,
  ) async {
    final staging = File(_join(root, '$_manifestName.tmp'));
    await staging.writeAsString(jsonEncode(manifest), flush: true);
    await staging.rename(_join(root, _manifestName));
  }

  @override
  Future<List<String>> keep(
    String source,
    List<String> paths, {
    List<double?>? sourceDpis,
  }) async {
    try {
      final root = await _root();
      await root.create(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final names = [
        for (final (index, path) in paths.indexed)
          owns(path) ? _nameOf(path) : 'item_${stamp}_$index.img',
      ];
      // Earlier files that are not part of this review.
      await for (final entity in root.list(followLinks: false)) {
        final name = _nameOf(entity.path);
        if (name != _manifestName && !names.contains(name)) {
          await entity.delete(recursive: true);
        }
      }
      // The manifest comes first: a file moved in after a kill is listed,
      // one never moved is simply missing.
      await _writeManifest(root, {
        'version': _version,
        'source': source,
        'items': names,
        // Optional, so the manifest version stays readable by older builds.
        if (sourceDpis != null && sourceDpis.length == paths.length)
          'sourceDpis': sourceDpis,
      });
      final kept = <String>[];
      for (final (index, path) in paths.indexed) {
        final target = _join(root, names[index]);
        if (owns(path)) {
          kept.add(target);
        } else if (await _move(path, target)) {
          kept.add(target);
        } else {
          kept.add(path);
        }
      }
      return kept;
    } catch (_) {
      await clear();
      return paths;
    }
  }

  /// Renames [from] to [to], or copies and deletes it across file systems.
  Future<bool> _move(String from, String to) async {
    try {
      await File(from).rename(to);
      return true;
    } on FileSystemException {
      try {
        await File(from).copy(to);
        await File(from).delete();
        return true;
      } catch (_) {
        try {
          await File(to).delete();
        } catch (_) {}
        return false;
      }
    }
  }

  @override
  Future<void> notePending(String source, int count) async {
    if (count <= 0) return clear();
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
      await _writeManifest(root, {
        'version': _version,
        'source': source,
        'pending': count,
      });
    } catch (_) {
      await clear();
    }
  }

  @override
  Future<void> release(String path) async {
    if (!owns(path)) return;
    try {
      await File(path).delete();
    } catch (_) {
      // Already gone; clear() removes anything left.
    }
  }

  @override
  Future<InterruptedReview?> read() async {
    try {
      final root = await _root();
      final manifestFile = File(_join(root, _manifestName));
      if (!await manifestFile.exists()) {
        // Files without a manifest belong to no review.
        await clear();
        return null;
      }
      if (await manifestFile.length() > _maxManifestBytes) {
        throw const FormatException('Manifest too large');
      }
      final manifest = jsonDecode(await manifestFile.readAsString());
      if (manifest is! Map ||
          manifest['version'] != _version ||
          manifest['source'] is! String) {
        throw const FormatException('Unsupported journal');
      }
      final items = manifest['items'];
      final pending = manifest['pending'];
      final dpis = manifest['sourceDpis'];
      final paths = <String>[];
      final sourceDpis = <double?>[];
      if (items is List) {
        for (final (index, name) in items.indexed) {
          if (name is! String || !_itemName.hasMatch(name)) continue;
          final path = _join(root, name);
          if (await FileSystemEntity.type(path, followLinks: false) ==
                  FileSystemEntityType.file &&
              await File(path).length() > 0) {
            paths.add(path);
            sourceDpis.add(
              dpis is List && dpis.length == items.length
                  ? validSourceDpi(dpis[index])
                  : null,
            );
          }
        }
      }
      final unresumable = pending is int && pending > 0 && pending <= 1000
          ? pending
          : 0;
      if (paths.isEmpty && unresumable == 0) {
        await clear();
        return null;
      }
      return InterruptedReview(
        source: manifest['source'] as String,
        paths: paths,
        unresumable: unresumable,
        sourceDpis: sourceDpis,
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Best effort: the folder is in the app cache.
    }
  }
}
