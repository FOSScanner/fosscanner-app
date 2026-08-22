<div align="center">

# FOSScanner

**A privacy-first, free and open-source document scanner.**

Scan documents with your camera, auto-crop and dewarp them, and export a
PDF — all on-device. No accounts, no cloud, no tracking.

[![License: GPL v3](https://img.shields.io/github/license/FOSScanner/fosscanner-app?color=blue)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/FOSScanner/fosscanner-app/ci.yml?branch=main&label=CI)](https://github.com/FOSScanner/fosscanner-app/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/FOSScanner/fosscanner-app?label=release)](https://github.com/FOSScanner/fosscanner-app/releases/latest)

<a href="https://github.com/FOSScanner/fosscanner-app/releases/latest">
  <img alt="Download APK" src="https://img.shields.io/badge/Download-APK-3DDC84?style=for-the-badge&logo=android&logoColor=white">
</a>

Grab `app-arm64-v8a-release.apk` from the release's assets — that's the
right build for virtually every phone from the last ~7 years. Prefer a
32-bit or x86 device? Use `armeabi-v7a` or `x86_64` instead.

<br>

<img src="docs/screenshots/home-empty.png" width="45%" alt="Empty home screen, ready to scan"> <img src="docs/screenshots/home-pages.png" width="45%" alt="Home screen with three captured pages, ready to export as PDF">

*Captured from the web build, which skips straight to the raw photo (web
has no OpenCV support, see below) — native builds additionally show the
edge-detection/corner-adjustment and filter screens in between capture
and this page list.*

</div>

## Features

- Real document scanning, not just a photo: automatic edge detection with
  a draggable corner overlay to fine-tune it, then perspective correction
  (dewarping) into a flat, upright page
- Scan filters — Original, Auto-Enhance, Grayscale, and Black & White —
  with live thumbnail previews before you confirm
- Re-edit any page after the fact (corners, filter) without re-scanning
- Capture multiple pages in sequence, reorder-free scanning workflow
- Combine captured pages into a single PDF
- Share the PDF via the OS share sheet (or download it directly on web)
- Material 3 UI that follows the system's light/dark theme
- No accounts, no cloud storage, no tracking

Edge detection, perspective correction, and filters run on real OpenCV
(`opencv_dart`) on Android/iOS/desktop. The web build doesn't support this
(OpenCV bindings are native/FFI-only) — web is a quick preview/testing
target, not the primary one; the raw captured photo is used as-is there.

## Privacy

- All image processing and PDF generation happens on-device.
- Captured photos and the generated PDF are only ever held in memory or
  short-lived temp storage, and are cleaned up as soon as they're no longer
  needed (page removed, "clear all", app closed, or right after sharing).
- The app makes no network requests of its own. (The web build's rendering
  engine, CanvasKit, is fetched from Google's CDN by the Flutter web
  framework itself — this doesn't apply to the native Android/iOS builds.)

## Getting started

Requires the Flutter SDK (Dart `>=3.0.0 <4.0.0`).

```bash
flutter pub get
flutter run
```

### Useful commands

| Command | Purpose |
|---|---|
| `flutter analyze` | Static analysis / lint |
| `flutter test` | Run the test suite |
| `flutter build apk --split-per-abi` | Build signed, per-ABI release APKs |
| `flutter build web` | Build a release web bundle |

### Running with Docker

`docker-compose.yml` provides two services that build against
`ghcr.io/cirruslabs/flutter:stable`, so you don't need the Flutter/Android
SDKs installed locally:

```bash
# Web preview, served on http://localhost:8080
docker compose up flutter-web

# Release Android APKs (one per ABI), output to build/app/outputs/flutter-apk/
docker compose run --rm build-apk
```

## Contributing

Issues and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the dev workflow and commit message
conventions.

## License

FOSScanner is licensed under the [GNU General Public License v3.0](LICENSE).
