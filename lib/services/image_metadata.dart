import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'corner_geometry.dart' show maxWarpPixels;

/// Bound source decoding before document processing. Image decoders expand
/// compressed inputs into multi-byte pixel buffers, so compressed file size
/// alone is not a safe allocation limit.
const maxSourceImagePixels = 20000000;
const maxSourceImageEdge = 8192;
const maxPickerEdge = 4472.0;
const maxEncodedImageBytes = 32 * 1024 * 1024;
const maxDocumentPages = 100;
const maxRetainedDocumentBytes = 256 * 1024 * 1024;
const maxImageProcessingWorkingSetBytes = 256 * 1024 * 1024;

// Peak processing allowance: the source decoder retains one four-channel
// buffer while export/auto-enhance can hold four four-channel warp-sized
// intermediates. Warp allocations are bounded by maxWarpPixels.
const _sourceDecodeBytesPerPixel = 4;
const _warpIntermediateBytesPerPixel = 16;

class EncodedImageTooLargeError extends UnsupportedError {
  EncodedImageTooLargeError(int maxBytes)
    : super('Encoded image exceeds the supported $maxBytes byte limit');
}

int availableEncodedImageBytes({
  required int currentBytes,
  int maxDocumentBytes = maxRetainedDocumentBytes,
  int maxImageBytes = maxEncodedImageBytes,
}) {
  if (currentBytes < 0 || maxDocumentBytes < 0 || maxImageBytes < 0) {
    throw ArgumentError('Image byte limits must not be negative');
  }
  return math.min(maxImageBytes, math.max(0, maxDocumentBytes - currentBytes));
}

bool canRetainDocument({
  required int currentBytes,
  required int currentPages,
  required int incomingBytes,
  int maxBytes = maxRetainedDocumentBytes,
  int maxPages = maxDocumentPages,
}) {
  if (currentBytes < 0 ||
      currentPages < 0 ||
      incomingBytes < 0 ||
      maxBytes < 0 ||
      maxPages < 0) {
    throw ArgumentError('Document memory counters must not be negative');
  }
  return currentPages < maxPages && incomingBytes <= maxBytes - currentBytes;
}

bool canReplaceDocumentPage({
  required int currentBytes,
  required int currentPages,
  required int replacedBytes,
  required int replacementBytes,
  int maxBytes = maxRetainedDocumentBytes,
  int maxPages = maxDocumentPages,
}) {
  if (currentBytes < 0 ||
      currentPages < 0 ||
      replacedBytes < 0 ||
      replacementBytes < 0 ||
      replacedBytes > currentBytes ||
      maxBytes < 0 ||
      maxPages < 0) {
    throw ArgumentError('Document replacement counters are invalid');
  }
  return currentPages <= maxPages &&
      replacementBytes <= maxBytes - (currentBytes - replacedBytes);
}

Future<Uint8List> readBoundedBytes(
  Stream<List<int>> stream, {
  int maxBytes = maxEncodedImageBytes,
}) async {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'Must not be negative');
  }

  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (chunk.length > maxBytes - bytes.length) {
      throw EncodedImageTooLargeError(maxBytes);
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<ui.Size> readEncodedImageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

void validateSourceImageSize(ui.Size size) {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    throw const FormatException('Image dimensions must be finite and positive');
  }

  if (size.width != size.width.truncateToDouble() ||
      size.height != size.height.truncateToDouble()) {
    throw const FormatException('Image dimensions must be whole pixels');
  }

  if (size.width < 3 || size.height < 3) {
    throw UnsupportedError('Image dimensions must be at least 3x3 pixels');
  }

  if (size.width > maxSourceImageEdge ||
      size.height > maxSourceImageEdge ||
      size.width * size.height > maxSourceImagePixels) {
    throw UnsupportedError(
      'Image dimensions exceed the supported ${maxSourceImageEdge}px edge '
      'or $maxSourceImagePixels pixel limit',
    );
  }
}

int estimateDecodedOpenCvBytes(ui.Size size) {
  validateSourceImageSize(size);
  final sourcePixels = size.width.toInt() * size.height.toInt();
  final warpPixels = math.min(sourcePixels, maxWarpPixels);
  return sourcePixels * _sourceDecodeBytesPerPixel +
      warpPixels * _warpIntermediateBytesPerPixel;
}

int estimateImageProcessingWorkingSet({
  required int currentRetainedBytes,
  required int encodedBytes,
  required ui.Size size,
}) {
  if (currentRetainedBytes < 0 || encodedBytes < 0) {
    throw ArgumentError('Image processing byte counters must not be negative');
  }
  return currentRetainedBytes + encodedBytes + estimateDecodedOpenCvBytes(size);
}

bool canProcessSourceImage({
  required int currentRetainedBytes,
  required int encodedBytes,
  required ui.Size size,
  int maxWorkingSetBytes = maxImageProcessingWorkingSetBytes,
}) {
  if (maxWorkingSetBytes < 0) {
    throw ArgumentError.value(
      maxWorkingSetBytes,
      'maxWorkingSetBytes',
      'Must not be negative',
    );
  }
  return estimateImageProcessingWorkingSet(
        currentRetainedBytes: currentRetainedBytes,
        encodedBytes: encodedBytes,
        size: size,
      ) <=
      maxWorkingSetBytes;
}
