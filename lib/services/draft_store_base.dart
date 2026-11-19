import '../models/scanned_page.dart';

export 'draft_session.dart';

/// Persistence boundary for an in-progress scan.
abstract interface class DraftStore {
  /// Returns no pages only when no draft exists or a valid empty draft is read.
  /// Failed restoration must throw rather than masquerade as an empty draft.
  Future<List<ScannedPage>> load();

  Future<void> save(List<ScannedPage> pages);

  Future<void> clear();
}

/// A privacy-safe restoration failure without paths or underlying scan data.
class DraftRestoreException implements Exception {
  const DraftRestoreException();
}

class NoOpDraftStore implements DraftStore {
  const NoOpDraftStore();

  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {}

  @override
  Future<void> clear() async {}
}
