# FOSScanner

A privacy-first, free and open-source document scanner built with Flutter.

FOSScanner captures document pages with your camera and compiles them into a
shareable PDF, entirely on-device. It has no analytics, no backend, and no
network calls of its own — nothing you scan is uploaded anywhere, and the
app doesn't keep a persistent copy of your photos or generated PDFs after
you're done with them.

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
| `flutter build apk` | Build a release Android APK |
| `flutter build web` | Build a release web bundle |

### Running with Docker

`docker-compose.yml` provides two services that build against
`ghcr.io/cirruslabs/flutter:stable`, so you don't need the Flutter/Android
SDKs installed locally:

```bash
# Web preview, served on http://localhost:8080
docker compose up flutter-web

# Release Android APK, output to build/app/outputs/flutter-apk/
docker compose run --rm build-apk
```

## Privacy

- All image processing and PDF generation happens on-device.
- Captured photos and the generated PDF are only ever held in memory or
  short-lived temp storage, and are cleaned up as soon as they're no longer
  needed (page removed, "clear all", app closed, or right after sharing).
- The app makes no network requests of its own. (The web build's rendering
  engine, CanvasKit, is fetched from Google's CDN by the Flutter web
  framework itself — this doesn't apply to the native Android/iOS builds.)

## License

FOSScanner is licensed under the [GNU General Public License v3.0](LICENSE).
