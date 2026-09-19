import 'package:flutter/foundation.dart' show TargetPlatform;

/// Whether the bundled barcode scanner has a camera backend on [platform].
///
/// Keep this pure so platform presentation can be verified without loading a
/// camera plugin.
bool supportsBarcodeCamera({
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.iOS);
