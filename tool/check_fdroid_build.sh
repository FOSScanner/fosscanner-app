#!/usr/bin/env bash
# Run from the repository root after Flutter initializes android/gradlew.
set -euo pipefail
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if (cd android && ./gradlew :app:assembleRelease --dry-run) >"$log" 2>&1; then
  echo 'Upstream release unexpectedly accepted missing signing configuration' >&2
  exit 1
fi
grep -F 'Release signing is required' "$log" || { cat "$log" >&2; exit 1; }

ORG_GRADLE_PROJECT_fdroidUnsigned=true flutter build apk --no-pub --release \
  --split-per-abi --target-platform android-arm64
apk=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
sdk=${ANDROID_HOME:-$ANDROID_SDK_ROOT}
build_tools=$(dirname "$(find "$sdk/build-tools" -name apksigner | sort -V | tail -1)")
version=$(awk '$1 == "version:" {print $2}' pubspec.yaml)
"$build_tools/aapt" dump badging "$apk" >"$log"
grep -F "package: name='com.fosscanner.app' versionCode='$((2000 + ${version##*+}))' versionName='${version%+*}'" "$log"
grep -Fx "native-code: 'arm64-v8a'" "$log"
# Check the manifest shipped in this exact split, not a Gradle intermediate.
"$sdk/cmdline-tools/latest/bin/apkanalyzer" manifest print "$apk" >"$log"
python3 tool/check_android_permissions.py "$log"
if "$build_tools/apksigner" verify "$apk" >"$log" 2>&1; then
  echo 'Expected an unsigned F-Droid input APK, found a valid signature' >&2
  exit 1
fi
# A missing tool, malformed APK or other verification error is not a pass.
grep -E 'Missing META-INF/MANIFEST.MF|No JAR signatures' "$log" || { cat "$log" >&2; exit 1; }
