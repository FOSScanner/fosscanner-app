/// Optional ownership boundary acquired before the scanner is mounted.
abstract interface class DraftSessionStore {
  Future<void> acquireSession();
}

class DraftInUseException implements Exception {
  const DraftInUseException();
}
