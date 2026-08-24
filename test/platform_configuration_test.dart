import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native platforms do not ship with placeholder application identifiers',
    () {
      for (final path in [
        'ios/Runner.xcodeproj/project.pbxproj',
        'macos/Runner.xcodeproj/project.pbxproj',
        'macos/Runner/Configs/AppInfo.xcconfig',
        'linux/CMakeLists.txt',
        'windows/runner/Runner.rc',
      ]) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains('com.example')),
          reason: path,
        );
      }
    },
  );

  test('Docker services preserve checked-in platform projects', () {
    final compose = File('docker-compose.yml').readAsStringSync();

    expect(compose, isNot(contains('flutter create .')));
    expect(compose, isNot(contains("version: '3.8'")));
    expect(compose, contains('platform: linux/amd64'));
  });

  test('Docker native builds install Ninja', () {
    expect(File('Dockerfile').readAsStringSync(), contains('ninja-build'));
  });

  test('CI compiles a shipping Android ABI', () {
    expect(
      File('.github/workflows/ci.yml').readAsStringSync(),
      contains('flutter build apk --debug --target-platform android-arm64'),
    );
  });
}
