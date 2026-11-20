import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, immutable, kDebugMode;
import 'package:path_provider/path_provider.dart';

import 'pdf_export_options.dart';

/// User choices that outlive a session.
///
/// Every field has a safe default, and [AppPreferences.fromJson] falls back to
/// it field by field, so a missing, corrupt or older file never blocks the app.
/// To add a preference: add a field with a default, then extend [copyWith],
/// [toJson], [fromJson] and equality.
@immutable
class AppPreferences {
  const AppPreferences({
    this.searchablePdf = false,
    this.pdfPageSize = PdfPageSize.original,
    this.pdfQuality = PdfQuality.high,
    this.blockScreenshots = false,
  });

  /// Whether exports run on-device OCR (where the platform supports it).
  final bool searchablePdf;

  /// Page box of exported PDFs.
  final PdfPageSize pdfPageSize;

  /// Image resolution and compression of exported PDFs.
  final PdfQuality pdfQuality;

  /// Whether the app window blocks screenshots and screen recording (Android
  /// `FLAG_SECURE`). Applied at startup through `screen_privacy.dart`.
  final bool blockScreenshots;

  AppPreferences copyWith({
    bool? searchablePdf,
    PdfPageSize? pdfPageSize,
    PdfQuality? pdfQuality,
    bool? blockScreenshots,
  }) => AppPreferences(
    searchablePdf: searchablePdf ?? this.searchablePdf,
    pdfPageSize: pdfPageSize ?? this.pdfPageSize,
    pdfQuality: pdfQuality ?? this.pdfQuality,
    blockScreenshots: blockScreenshots ?? this.blockScreenshots,
  );

  // Enums are stored by name, so reordering them cannot change a choice.
  Map<String, Object?> toJson() => {
    'searchablePdf': searchablePdf,
    'pdfPageSize': pdfPageSize.name,
    'pdfQuality': pdfQuality.name,
    'blockScreenshots': blockScreenshots,
  };

  factory AppPreferences.fromJson(Object? json) {
    if (json is! Map) return const AppPreferences();
    const defaults = AppPreferences();
    final searchable = json['searchablePdf'];
    final blockScreenshots = json['blockScreenshots'];
    return AppPreferences(
      searchablePdf: searchable is bool ? searchable : defaults.searchablePdf,
      pdfPageSize: _enumByName(
        PdfPageSize.values,
        json['pdfPageSize'],
        defaults.pdfPageSize,
      ),
      pdfQuality: _enumByName(
        PdfQuality.values,
        json['pdfQuality'],
        defaults.pdfQuality,
      ),
      blockScreenshots: blockScreenshots is bool
          ? blockScreenshots
          : defaults.blockScreenshots,
    );
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? name,
    T fallback,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.searchablePdf == searchablePdf &&
      other.pdfPageSize == pdfPageSize &&
      other.pdfQuality == pdfQuality &&
      other.blockScreenshots == blockScreenshots;

  @override
  int get hashCode =>
      Object.hash(searchablePdf, pdfPageSize, pdfQuality, blockScreenshots);
}

/// Loads and saves [AppPreferences]. Implementations never throw from [load].
abstract interface class AppPreferencesStore {
  Future<AppPreferences> load();

  Future<void> save(AppPreferences preferences);
}

/// Keeps preferences for the lifetime of the object only.
///
/// The default for widgets and tests, so nothing touches disk unless the app
/// explicitly provides a [FileAppPreferencesStore].
class MemoryAppPreferencesStore implements AppPreferencesStore {
  MemoryAppPreferencesStore([this._preferences = const AppPreferences()]);

  AppPreferences _preferences;

  @override
  Future<AppPreferences> load() async => _preferences;

  @override
  Future<void> save(AppPreferences preferences) async {
    _preferences = preferences;
  }
}

/// Stores preferences as a small JSON file in app-private support storage.
///
/// The file never contains document data. Writes go through a temporary file
/// and a rename so an interrupted save leaves either the old or the new file,
/// and saves are serialized so a slower earlier write cannot win.
class FileAppPreferencesStore implements AppPreferencesStore {
  FileAppPreferencesStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const fileName = 'preferences.json';

  // Far above any legitimate file; anything larger is not ours to parse.
  static const _maxFileBytes = 64 * 1024;

  final Future<Directory> Function() _directory;
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<AppPreferences> load() async {
    try {
      final file = File('${(await _directory()).path}/$fileName');
      if (!await file.exists() || await file.length() > _maxFileBytes) {
        return const AppPreferences();
      }
      return AppPreferences.fromJson(jsonDecode(await file.readAsString()));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Preferences unreadable (${error.runtimeType}).');
      }
      return const AppPreferences();
    }
  }

  @override
  Future<void> save(AppPreferences preferences) {
    final write = _writeTail.then((_) => _write(preferences));
    // A failed write must not poison later saves.
    _writeTail = write.catchError((_) {});
    return write;
  }

  Future<void> _write(AppPreferences preferences) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/$fileName.tmp');
    await temporary.writeAsString(
      jsonEncode(preferences.toJson()),
      flush: true,
    );
    await temporary.rename('${directory.path}/$fileName');
  }
}
