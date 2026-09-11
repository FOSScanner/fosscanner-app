import '../models/scanned_page.dart';

/// Persistence boundary for an in-progress scan.
abstract interface class DraftStore {
  Future<List<ScannedPage>> load();

  Future<void> save(List<ScannedPage> pages);

  Future<void> clear();
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
