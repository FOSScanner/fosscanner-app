import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/platform_capabilities.dart';

void main() {
  test('barcode camera is supported only on native Android and iOS', () {
    for (final platform in TargetPlatform.values) {
      expect(
        supportsBarcodeCamera(platform: platform, isWeb: false),
        platform == TargetPlatform.android || platform == TargetPlatform.iOS,
        reason: '$platform on a native build',
      );
      expect(
        supportsBarcodeCamera(platform: platform, isWeb: true),
        isFalse,
        reason: '$platform on a web build',
      );
    }
  });
}
