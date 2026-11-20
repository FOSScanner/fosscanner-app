import 'package:flutter/material.dart';

/// Overflow-menu value of the "Block screenshots" setting.
const blockScreenshotsMenuValue = 'blockScreenshots';

/// Overflow-menu entries for screen privacy: a checkable "Block screenshots"
/// item where the platform can block them (see `isSecureScreenSupported`),
/// otherwise nothing.
///
/// Like the menu's other items it has a leading icon; the check sits in a
/// trailing slot that keeps its width when cleared, so nothing shifts.
///
/// Kept separate from the menu's other items so the setting can be added to
/// any `PopupMenuButton<String>` without restructuring it.
List<PopupMenuEntry<String>> screenPrivacyMenuItems({
  required bool supported,
  required bool blockScreenshots,
}) => [
  if (supported)
    PopupMenuItem<String>(
      value: blockScreenshotsMenuValue,
      child: Semantics(
        checked: blockScreenshots,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.screenshot_outlined),
          title: const Text('Block screenshots'),
          trailing: Icon(
            Icons.check,
            key: const Key('block_screenshots_check'),
            color: blockScreenshots ? null : Colors.transparent,
          ),
        ),
      ),
    ),
];
