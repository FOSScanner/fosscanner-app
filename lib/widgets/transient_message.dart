import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

var _messageGeneration = 0;

/// The controller of a shown snack bar, as returned by
/// [ScaffoldMessengerState.showSnackBar].
typedef SnackBarController =
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>;

/// Shows one short-lived message, replacing any stale queued message.
///
/// Messages float: a fixed SnackBar would lift the floating action button
/// while it is shown, while a floating one sits above it (or above the bottom
/// bar), so nothing the user may be about to tap moves.
///
/// [onShown] receives the controller once it is shown.
void showTransientMessage(
  BuildContext context,
  String message, {
  ValueSetter<SnackBarController>? onShown,
}) {
  if (!context.mounted) return;
  final generation = ++_messageGeneration;

  void show() {
    if (!context.mounted || generation != _messageGeneration) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    final controller = messenger.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
    onShown?.call(controller);
  }

  // Showing a SnackBar while widgets are being built would mutate the
  // messenger during its frame. Defer only that case; async callbacks and
  // user actions can update it immediately.
  if (SchedulerBinding.instance.schedulerPhase ==
      SchedulerPhase.persistentCallbacks) {
    WidgetsBinding.instance.addPostFrameCallback((_) => show());
  } else {
    show();
  }
}
