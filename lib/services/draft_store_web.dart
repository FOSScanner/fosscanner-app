import '../models/scanned_page.dart';
import 'draft_store_base.dart';

/// Web intentionally keeps drafts in memory only.
DraftStore createDraftStore() => const WebNoOpDraftStore();

class WebNoOpDraftStore implements DraftStore {
  const WebNoOpDraftStore();

  @override
  Future<List<ScannedPage>> load() async => const [];

  @override
  Future<void> save(List<ScannedPage> pages) async {}

  @override
  Future<void> clear() async {}
}
