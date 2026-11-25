import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/main.dart' show registerBundledLicenses;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled native notices are loadable and registered in full', () async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    registerBundledLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    for (final (name, file, requiredText) in [
      (
        'ZXing and Zint native barcode libraries',
        'BARCODE_NOTICES.txt',
        'Robin Stuart',
      ),
      (
        'OpenCV and native image dependencies',
        'OPENCV_NOTICES.txt',
        'Willow Garage',
      ),
      ('KleidiCV', 'KLEIDICV_NOTICES.txt', 'Arm Limited'),
      (
        'AndroidX CameraX and libyuv',
        'CAMERAX_NOTICES.txt',
        'The LibYuv Project Authors',
      ),
    ]) {
      final text = await rootBundle.loadString('assets/licenses/$file');
      expect(text, contains(requiredText));
      final entry = entries.singleWhere(
        (entry) => entry.packages.contains(name),
      );
      final registered = entry.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      expect(registered, contains(requiredText));
      expect(
        registered.replaceAll(RegExp(r'\s+'), ''),
        text.replaceAll(RegExp(r'\s+'), ''),
      );
      expect(registered.toLowerCase(), contains('disclaim'));
    }
  });
}
