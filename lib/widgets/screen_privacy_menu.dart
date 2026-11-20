import 'package:flutter/material.dart';

/// Overflow-menu value of the "Block screenshots" setting.
const blockScreenshotsMenuValue = 'blockScreenshots';

/// Overflow-menu entries for screen privacy: a checkable "Block screenshots"
/// item where the platform can block them (see `isSecureScreenSupported`),
/// otherwise nothing.
///
/// Kept separate from the menu's other items so the setting can be added to
/// any `PopupMenuButton<String>` without restructuring it.
List<PopupMenuEntry<String>> screenPrivacyMenuItems({
  required bool supported,
  required bool blockScreenshots,
}) => [
  if (supported)
    CheckedPopupMenuItem<String>(
      value: blockScreenshotsMenuValue,
      checked: blockScreenshots,
      child: const Text('Block screenshots'),
    ),
];
