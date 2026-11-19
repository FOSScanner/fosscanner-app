#!/usr/bin/env bash
# Fails when the app requests a permission outside the allowlist below.
#
# usage: tool/check_android_permissions.sh <merged release AndroidManifest.xml> [debug APK]
#
# Plugins merge their own permissions into the app (CameraX alone adds the
# microphone and legacy storage); android/app/src/main/AndroidManifest.xml
# removes the unused ones. This check catches a plugin update that brings in
# a new one. The release manifest must not request INTERNET: the app works
# offline. Debug builds alone may use it, for the Flutter tool.
set -euo pipefail

manifest=${1:?usage: $0 <merged release AndroidManifest.xml> [debug APK]}
apk=${2:-}

# CAMERA scans pages and codes. The androidx.core receiver permission is
# signature-protected and declared by the app for itself, so no other app
# can hold it.
allowed='^(android\.permission\.CAMERA|com\.fosscanner\.app\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION)$'
debug_allowed='^android\.permission\.INTERNET$'

status=0

requested=$(tr '\n' ' ' <"$manifest" |
  grep -oE '<uses-permission(-sdk-23)?[^>]*android:name="[^"]+"' |
  sed -E 's/.*android:name="([^"]+)"/\1/' | sort -u)
test -n "$requested" || { echo "No permissions found in $manifest" >&2; exit 1; }
while read -r permission; do
  if [[ ! $permission =~ $allowed ]]; then
    echo "Release manifest requests an unexpected permission: $permission" >&2
    status=1
  fi
done <<<"$requested"

if [[ -n $apk ]]; then
  sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:?ANDROID_HOME is not set}}
  aapt2=$(find "$sdk/build-tools" -name aapt2 | sort -V | tail -1)
  test -n "$aapt2" || { echo "aapt2 not found under $sdk" >&2; exit 1; }
  apk_requested=$("$aapt2" dump permissions "$apk" |
    sed -nE "s/^uses-permission(-sdk-23)?: name='([^']+)'.*/\2/p" | sort -u)
  test -n "$apk_requested" || { echo "No permissions found in $apk" >&2; exit 1; }
  while read -r permission; do
    if [[ ! $permission =~ $allowed && ! $permission =~ $debug_allowed ]]; then
      echo "APK requests an unexpected permission: $permission" >&2
      status=1
    fi
  done <<<"$apk_requested"
fi

if [[ $status -eq 0 ]]; then
  echo "Requested permissions:"
  echo "$requested"
fi
exit $status
