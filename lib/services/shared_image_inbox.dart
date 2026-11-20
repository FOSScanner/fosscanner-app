import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;

/// Images another app shared into FOSScanner, as app-owned cache copies.
class SharedImageBatch {
  const SharedImageBatch({
    this.paths = const [],
    this.rejected = 0,
    this.truncated = false,
  });

  /// App-owned files. The receiver deletes each one after reading it, and
  /// deletes any it does not read.
  final List<String> paths;

  /// Shared items that were not images, could not be read, or were larger
  /// than the per-image limit.
  final int rejected;

  /// More images were shared than the document could still accept.
  final bool truncated;

  bool get isEmpty => paths.isEmpty && rejected == 0 && !truncated;
}

/// Pull-based access to images shared into the app.
///
/// The platform only announces that images are waiting; the home screen
/// decides when it is safe to [take] them (after the saved draft is resolved
/// and while no other picker or editor route is active).
abstract interface class SharedImageInbox {
  /// Registers the callback for newly shared images, or clears it.
  void setListener(VoidCallback? onAvailable);

  /// Drains every waiting image, copying at most [maxCount] of them.
  Future<SharedImageBatch> take({required int maxCount});
}

/// Android implementation backed by MainActivity's share intent handling.
///
/// Keep the channel contract synchronized with
/// android/app/src/main/kotlin/com/fosscanner/app/SharedImageInbox.kt and
/// MainActivity.kt. A dedicated channel keeps share notifications from
/// competing with the OCR channel's progress handler.
class MethodChannelSharedImageInbox implements SharedImageInbox {
  MethodChannelSharedImageInbox._();

  static final instance = MethodChannelSharedImageInbox._();

  static const _channel = MethodChannel('com.fosscanner.app/shared_images');

  @override
  void setListener(VoidCallback? onAvailable) {
    _channel.setMethodCallHandler(
      onAvailable == null
          ? null
          : (MethodCall call) async {
              if (call.method == 'sharedImagesAvailable') onAvailable();
            },
    );
  }

  @override
  Future<SharedImageBatch> take({required int maxCount}) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'takeSharedImages',
      {'maxCount': maxCount},
    );
    return parseSharedImageBatch(result);
  }
}

/// Defensive decoding of the platform reply; malformed entries are ignored.
SharedImageBatch parseSharedImageBatch(Map<String, Object?>? reply) {
  if (reply == null) return const SharedImageBatch();
  final paths = reply['paths'];
  final rejected = reply['rejected'];
  return SharedImageBatch(
    paths: [
      if (paths is List)
        for (final path in paths)
          if (path is String && path.isNotEmpty) path,
    ],
    rejected: rejected is int && rejected > 0 ? rejected : 0,
    truncated: reply['truncated'] == true,
  );
}
