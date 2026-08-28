import 'package:flutter/material.dart';

/// Shows a short-lived SnackBar, deferred to a post-frame callback so it
/// works even when called from code that runs before this frame's Scaffold
/// has registered with the surrounding ScaffoldMessenger (e.g. startup
/// recovery, or a callback fired mid-build).
void showTransientMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  });
}
