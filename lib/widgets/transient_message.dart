import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

var _messageGeneration = 0;

/// Shows one short-lived message, replacing any stale queued message.
void showTransientMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  final generation = ++_messageGeneration;

  void show() {
    if (!context.mounted || generation != _messageGeneration) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
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
