import 'dart:io';

import 'draft_session.dart';

/// Holds exclusive draft ownership until this app process exits.
class DraftSessionLock {
  DraftSessionLock(this.directory);

  final Directory directory;
  RandomAccessFile? _handle;
  Future<void>? _pending;

  // On POSIX, closing another descriptor for this inode releases this
  // process's lock. Keep owners alive and reject a second owner before opening
  // another handle. Worker isolates must not open the session lock.
  static final _owners = <String, DraftSessionLock>{};

  Future<void> acquire() {
    if (_handle != null) return Future<void>.value();
    return _pending ??= _acquire().whenComplete(() => _pending = null);
  }

  Future<void> _acquire() async {
    await directory.create(recursive: true);
    final root = await directory.resolveSymbolicLinks();
    final path = '$root${Platform.pathSeparator}.session.lock';
    if (_owners.containsKey(path)) throw const DraftInUseException();
    _owners[path] = this;

    RandomAccessFile? handle;
    try {
      // Keep this inode stable across save/clear and process restarts.
      handle = await File(path).open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive, 0, 1);
      } on FileSystemException catch (error) {
        // EAGAIN/EACCES (Linux), EWOULDBLOCK (macOS), LOCK_VIOLATION
        // (Windows). Other storage failures must not be called contention.
        final busyCodes = Platform.isWindows ? const {33} : const {11, 13, 35};
        if (busyCodes.contains(error.osError?.errorCode)) {
          throw const DraftInUseException();
        }
        rethrow;
      }
      _handle = handle;
    } finally {
      if (_handle == null) {
        try {
          await handle?.close();
        } finally {
          _owners.remove(path);
        }
      }
    }
  }
}
