# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

FOSScanner is a privacy-first, FOSS (free and open source) document scanner built with Flutter. It captures photos via the device camera, lets the user manage the captured pages, and compiles them into a shareable PDF — all processed on-device (no cloud/network calls).

## Commands

This is a standard Flutter app (Dart SDK `>=3.0.0 <4.0.0`). Run these from the repo root.

- Install dependencies: `flutter pub get`
- Run the app (device/emulator/web): `flutter run`
- Static analysis / lint: `flutter analyze` (uses `analysis_options.yaml`, which includes `package:flutter_lints/flutter.yaml`)
- Run all tests: `flutter test`
- Run a single test file: `flutter test test/widget_test.dart`
- Build Android APK: `flutter build apk`
- Build web release: `flutter build web`

### Docker

`docker-compose.yml` defines two services (both build from the root `Dockerfile`, based on `ghcr.io/cirruslabs/flutter:stable`):

- `flutter-web`: runs `flutter create . && flutter pub get && flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080`, exposed on port 8080.
- `build-apk`: runs `flutter create . && flutter pub get && flutter build apk`.

Both mount the repo into `/app` and re-run `flutter create .` on startup to regenerate platform scaffolding before building.

## Architecture

The entire application currently lives in a single file, `lib/main.dart`:

- `FOSScannerApp` — root `MaterialApp` (Material 3, theme follows the system light/dark setting via `ThemeMode.system`).
- `ScannerHomePage` / `_ScannerHomePageState` — the sole screen, holding all state:
  - `_images: List<XFile>` — captured pages, in order.
  - `_captureImage()` — invokes `image_picker`'s camera source and appends to `_images`.
  - `_removeImage(index)` / `_clearImages()` — remove page(s) and best-effort delete their backing temp files (`_deleteFileQuietly`).
  - `_generateAndSharePdf()` — builds a `pdf` `Document` (one A4 page per image via `pw.MemoryImage`), then shares the resulting bytes directly via `SharePlus.instance.share(ShareParams(files: [XFile.fromData(...)], downloadFallbackEnabled: true))`. No temp file is written for the PDF itself — sharing straight from bytes avoids `path_provider`/`dart:io`, neither of which work reliably on web, and keeps nothing on disk that the app has to clean up.

Key dependencies (see `pubspec.yaml`): `image_picker`, `pdf`, `share_plus` (uses the modern `SharePlus.instance.share()` API, not the deprecated `Share.shareXFiles`).

### Privacy behavior

Captured photos and the generated PDF are never persisted by the app: temp files backing captured images are deleted as soon as a page is removed, "clear all" is tapped, or the widget is disposed; the PDF itself only ever exists as in-memory bytes.
