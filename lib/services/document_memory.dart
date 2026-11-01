import 'dart:typed_data';

import '../models/scanned_page.dart';

/// Encoded image storage retained by pages and outstanding snapshots.
///
/// ByteBuffer equality identifies shared backing storage, including different
/// views of one image array. Count the whole backing buffer, not just a view's
/// length. This is an admission estimate, not process RSS: decoded caches,
/// native allocations and worker/message copies are additional memory.
int retainedPageImageBytes(Iterable<ScannedPage> pages) {
  final buffers = <ByteBuffer>{};
  for (final page in pages) {
    buffers.add(page.originalBytes.buffer);
    buffers.add(page.processedBytes.buffer);
  }
  return buffers.fold(0, (total, buffer) => total + buffer.lengthInBytes);
}
