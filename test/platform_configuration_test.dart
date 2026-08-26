import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<String> _activeLines(String source) =>
    source.split('\n').where((line) => !line.trimLeft().startsWith('#'));

bool _hasActiveLine(String source, RegExp pattern) =>
    _activeLines(source).any(pattern.hasMatch);

void _expectActiveLineCount(String path, RegExp pattern, int expectedCount) {
  final source = File(path).readAsStringSync();
  expect(source, isNot(contains('com.example')), reason: path);
  expect(
    _activeLines(source).where(pattern.hasMatch),
    hasLength(expectedCount),
    reason: '$path must contain every exact FOSScanner identity',
  );
}

void main() {
  test('active-line checks ignore commented directives', () {
    expect(
      _hasActiveLine(
        '# platform: linux/amd64',
        RegExp(r'^\s*platform:\s*linux/amd64\s*$'),
      ),
      isFalse,
    );
  });

  test(
    'native platforms do not ship with placeholder application identifiers',
    () {
      const iosProject = 'ios/Runner.xcodeproj/project.pbxproj';
      _expectActiveLineCount(
        iosProject,
        RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = [^;]+;\s*$'),
        6,
      );
      _expectActiveLineCount(
        iosProject,
        RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = com\.fosscanner\.app;\s*$'),
        3,
      );
      _expectActiveLineCount(
        iosProject,
        RegExp(
          r'^\s*PRODUCT_BUNDLE_IDENTIFIER = '
          r'com\.fosscanner\.app\.RunnerTests;\s*$',
        ),
        3,
      );

      const macosProject = 'macos/Runner.xcodeproj/project.pbxproj';
      _expectActiveLineCount(
        macosProject,
        RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = [^;]+;\s*$'),
        3,
      );
      _expectActiveLineCount(
        macosProject,
        RegExp(
          r'^\s*PRODUCT_BUNDLE_IDENTIFIER = '
          r'com\.fosscanner\.app\.RunnerTests;\s*$',
        ),
        3,
      );

      const macosInfo = 'macos/Runner/Configs/AppInfo.xcconfig';
      _expectActiveLineCount(
        macosInfo,
        RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=.*$'),
        1,
      );
      _expectActiveLineCount(
        macosInfo,
        RegExp(r'^\s*PRODUCT_BUNDLE_IDENTIFIER = com\.fosscanner\.app\s*$'),
        1,
      );

      const linuxCmake = 'linux/CMakeLists.txt';
      _expectActiveLineCount(
        linuxCmake,
        RegExp(r'^\s*set\(APPLICATION_ID\s+.*\)\s*$'),
        1,
      );
      _expectActiveLineCount(
        linuxCmake,
        RegExp(r'^\s*set\(APPLICATION_ID "com\.fosscanner\.app"\)\s*$'),
        1,
      );

      const windowsResources = 'windows/runner/Runner.rc';
      _expectActiveLineCount(
        windowsResources,
        RegExp(r'^\s*VALUE "CompanyName",.*$'),
        1,
      );
      _expectActiveLineCount(
        windowsResources,
        RegExp(r'^\s*VALUE "CompanyName", "FOSScanner" "\\0"\s*$'),
        1,
      );
    },
  );

  test('Docker services preserve checked-in platform projects', () {
    final compose = File('docker-compose.yml').readAsStringSync();

    expect(compose, isNot(contains('flutter create .')));
    expect(compose, isNot(contains("version: '3.8'")));
    expect(
      _hasActiveLine(compose, RegExp(r'^\s*platform:\s*linux/amd64\s*$')),
      isTrue,
    );
  });

  test('Docker native builds install Ninja and cache pub dependencies', () {
    final dockerfile = File('Dockerfile').readAsStringSync();
    expect(
      _hasActiveLine(dockerfile, RegExp(r'^\s*ninja-build\s*\\\s*$')),
      isTrue,
    );
    expect(
      _hasActiveLine(dockerfile, RegExp(r'^\s*RUN flutter pub get\s*$')),
      isTrue,
    );
  });

  test('CI compiles a shipping Android ABI', () {
    expect(
      _hasActiveLine(
        File('.github/workflows/ci.yml').readAsStringSync(),
        RegExp(
          r'^\s*-\s+run:\s+flutter build apk --debug '
          r'--target-platform android-arm64\s*$',
        ),
      ),
      isTrue,
    );
  });
}
