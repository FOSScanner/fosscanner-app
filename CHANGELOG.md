# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.4.0](https://github.com/FOSScanner/fosscanner-app/compare/v1.3.0...v1.4.0) (2026-09-19)


### Features

* add searchable PDF OCR export ([a54b4c0](https://github.com/FOSScanner/fosscanner-app/commit/a54b4c071e4e6ff19a3c42d06464e83f02b5725a))
* restore unfinished document drafts ([#28](https://github.com/FOSScanner/fosscanner-app/issues/28)) ([9fce1b9](https://github.com/FOSScanner/fosscanner-app/commit/9fce1b98c8345b5a409a4287c9e3bc50641e0d3b))


### Bug Fixes

* bound and serialize image processing ([#29](https://github.com/FOSScanner/fosscanner-app/issues/29)) ([3af07c6](https://github.com/FOSScanner/fosscanner-app/commit/3af07c6c7c79786e2ecdd9d4a1dc040dd8f91aa9))
* bound image-only PDF export memory ([f2be67e](https://github.com/FOSScanner/fosscanner-app/commit/f2be67e766e0655ce67dc0bdec5f830cf0d95b50))
* bound image-only PDF export memory ([6a6f6e3](https://github.com/FOSScanner/fosscanner-app/commit/6a6f6e312b6a0b5e611ad7df11e80c00a25830a4))
* bound the decoded crop preview size ([1f98555](https://github.com/FOSScanner/fosscanner-app/commit/1f985557cbfc24e7aadc9e2f3bcb6ee628431bc3))
* bound the decoded crop preview size ([eb4ae7a](https://github.com/FOSScanner/fosscanner-app/commit/eb4ae7a54ff9612f8a4b17483ad19a2e3eb0f979))
* coalesce pending draft snapshot saves ([d843bbc](https://github.com/FOSScanner/fosscanner-app/commit/d843bbcdbb8a9f1b6463e7a0435098dd5385af83))
* coalesce pending draft snapshot saves ([6a623c4](https://github.com/FOSScanner/fosscanner-app/commit/6a623c49007c80bbfcd8db9956fca8744e0f3c45))
* exclude nested signing material from Docker images ([c1b5e64](https://github.com/FOSScanner/fosscanner-app/commit/c1b5e64fd1753dc6273c3a5e189f9da4e9c5e8d7))
* exclude nested signing secrets from Docker contexts ([b12ca0a](https://github.com/FOSScanner/fosscanner-app/commit/b12ca0a7aa8187a8b3377ebf22ace5de1befd4b9))
* gate barcode camera by platform support ([8464e78](https://github.com/FOSScanner/fosscanner-app/commit/8464e78c125210f89534b0ffdcbec65772005228))
* handle barcode camera permission failures ([f5a486b](https://github.com/FOSScanner/fosscanner-app/commit/f5a486b7e6a4b3c33b0a6cab663e7224200aa2e2))
* honor OCR cancellation throughout export ([ffad3a1](https://github.com/FOSScanner/fosscanner-app/commit/ffad3a1eb6cad13d17393c9caae603fc24d36d57))
* honor OCR cancellation throughout export ([ea26db1](https://github.com/FOSScanner/fosscanner-app/commit/ea26db14a37d18890eddad96a20f095687df2912))
* improve scanner accessibility and platform support ([6fae23a](https://github.com/FOSScanner/fosscanner-app/commit/6fae23a65860346bdf52eda941d79471b001188f))
* improve scanner accessibility and platform support ([d1b62dc](https://github.com/FOSScanner/fosscanner-app/commit/d1b62dcbdaaf621675b6f9cd6d8abb44122761a7))
* keep CI aligned with mobile targets ([9a1b397](https://github.com/FOSScanner/fosscanner-app/commit/9a1b397c7faa798ade5d3f0b33df3ae736fbb3ca))
* preserve debug logging import ([1cde17d](https://github.com/FOSScanner/fosscanner-app/commit/1cde17d19ca32e0ba70afa78ac742c4472c9e322))
* preserve draft edits made during PDF sharing ([c3f7929](https://github.com/FOSScanner/fosscanner-app/commit/c3f79292a80f0f4d094469967d4af1ac9beac734))
* preserve draft edits made during PDF sharing ([e53c5d8](https://github.com/FOSScanner/fosscanner-app/commit/e53c5d8ba7262f4821dd27e0e3ee6ea314ae21d7))
* preserve PDF share anchor during export ([4cd7fb8](https://github.com/FOSScanner/fosscanner-app/commit/4cd7fb80d43d2648235e933091f84ab753150977))
* preserve PDF share anchor during export ([b03b470](https://github.com/FOSScanner/fosscanner-app/commit/b03b470b6410823e28c4af33f9a9c67d6f91b4a1))
* preserve release signing passwords verbatim ([f134ec2](https://github.com/FOSScanner/fosscanner-app/commit/f134ec21cc229db849459d49df55174c7792f221))
* preserve release signing passwords verbatim ([b061eb4](https://github.com/FOSScanner/fosscanner-app/commit/b061eb44bfb1bf316339b4c89007b3f4ebef38d7))
* prevent concurrent processes from overwriting drafts ([553e565](https://github.com/FOSScanner/fosscanner-app/commit/553e565bb1ed2ff68ce0e04bab92309ee55b5d35))
* remove obsolete platform capability import ([6e80e40](https://github.com/FOSScanner/fosscanner-app/commit/6e80e40f69ca41ccb2a5ff32d2af4541a5ed454d))
* remove orphaned OCR cache jobs on startup ([80672d5](https://github.com/FOSScanner/fosscanner-app/commit/80672d5a39679e5a110cfee5aa71a0e50b681637))
* remove orphaned OCR cache jobs on startup ([b58dc00](https://github.com/FOSScanner/fosscanner-app/commit/b58dc0063ee1093bc0e44e108cd3d6c7bd20a57b))
* report barcode camera errors and allow retry ([572b7ca](https://github.com/FOSScanner/fosscanner-app/commit/572b7cafea40d1f3e6abde0f24f20eeed3ce38dc))
* reserve native drafts across app processes ([a547347](https://github.com/FOSScanner/fosscanner-app/commit/a547347ac54caa77293f52d3f1ca4e8a2474512b))
* restore drafts containing narrow processed crops ([061f9d9](https://github.com/FOSScanner/fosscanner-app/commit/061f9d909ffa06cbc1a2082e7f7e242ea63ba264))
* restore drafts containing narrow processed crops ([992ece8](https://github.com/FOSScanner/fosscanner-app/commit/992ece8bdbfda05c0a241b817ddd3055cc868184))
* restore saved draft before accepting images ([c59204e](https://github.com/FOSScanner/fosscanner-app/commit/c59204eeaf2bd11d5c4e19708ae73f5188f13fcc))
* restore saved drafts before accepting images ([b6a65df](https://github.com/FOSScanner/fosscanner-app/commit/b6a65df9b30e8ba6c86df282bfe4931060e29e9a))
* set searchable PDF resolution ([f26fdd6](https://github.com/FOSScanner/fosscanner-app/commit/f26fdd6dcfd2487d1f921f7adc18fa46ca3bbc56))
* set searchable PDF resolution ([50fa642](https://github.com/FOSScanner/fosscanner-app/commit/50fa6424e58cd3418f5b63eb8e15daf8a9aa1064))
* stop image-only exports cancelled during assembly ([0c89f79](https://github.com/FOSScanner/fosscanner-app/commit/0c89f793d99ea176a019aadc93aac2251c44df36))


### Performance Improvements

* export image-only PDFs on a worker isolate ([a094e24](https://github.com/FOSScanner/fosscanner-app/commit/a094e24737498d68d9c3283338ea16e67b6c5d27))

## [1.3.0](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.2...v1.3.0) (2026-08-28)


### Features

* add in-app about screen with version and source link
* add QR/barcode scanning as a standalone camera mode


### Bug Fixes

* clarify version display and expand the about dialog
* corner role validation could reject valid, correctly-ordered crops
* dedupe snackbar helper, guard a post-dispose setState, surface launchUrl failures
* enable tryHarder so 1D barcodes (EAN/UPC/Code128) actually decode
* QR scan result never clears, and the found-code overlay looked clickable
* QR/barcode scanning never detecting a code
* reject corner quads with mismatched tl/tr/br/bl roles, closes [#20](https://github.com/FOSScanner/fosscanner-app/issues/20)
* show corner-adjust errors in a snackbar instead of shrinking the preview, closes [#21](https://github.com/FOSScanner/fosscanner-app/issues/21)
* use FOSScanner consistently in user-facing display strings
* use_build_context_synchronously lint in _openResult

## [1.2.2](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.1...v1.2.2) (2026-08-26)


### Bug Fixes

* align platform configuration and CI
* harden image intake and sharing
* harden native document processing
* improve corner control accessibility

## [1.2.1](https://github.com/FOSScanner/fosscanner-app/compare/v1.2.0...v1.2.1) (2026-08-23)


### Bug Fixes

* keep release-please tags as plain vX.Y.Z, not component-prefixed ([9095fa9](https://github.com/FOSScanner/fosscanner-app/commit/9095fa95258b2dd363677c8b05c0b15167c4ba9e))

## [1.2.0](https://github.com/FOSScanner/fosscanner-app/compare/fosscanner-v1.1.0...fosscanner-v1.2.0) (2026-08-23)


### Features

* add page rotate, brightness/contrast, drag-reorder, and gallery import ([61c00ee](https://github.com/FOSScanner/fosscanner-app/commit/61c00eed0e0bb9094fdbaf28f8ce7f36da1a62ba))


### Bug Fixes

* pin release-please to main, not the repo default branch ([8d13f1f](https://github.com/FOSScanner/fosscanner-app/commit/8d13f1fc28c42f5d00bfb0a9ad26318e9c6d490d))

## [Unreleased]

## [1.1.0] - 2026-08-16

### Added

- Real document scanning: automatic edge detection (OpenCV via
  `opencv_dart`) with a draggable corner overlay to correct it, then
  perspective correction into a flat, upright page.
- Scan filters — Original, Auto-Enhance, Grayscale, Black & White — with
  live thumbnail previews before confirming.
- Re-edit a page's corners/filter after the fact without re-scanning it.

### Changed

- Release APKs are now split per-ABI (`arm64-v8a`, `armeabi-v7a`,
  `x86_64`) instead of shipping one universal APK, cutting the download
  most phones need from ~83MB to ~28MB.

### Fixed

- A native double-free in the edge-detection pipeline (disposing
  individual `findContours` result elements instead of the container they
  came from) that could crash the app on capture, most reliably on
  realistic (multi-megapixel) photos.

### Known limitations

- Edge detection, perspective correction, and filters are native-only
  (`opencv_dart` has no web support); the web build falls back to using
  the raw captured photo as-is.

## [1.0.0] - 2026-08-04

### Added

- Capture document pages with the device camera.
- Combine captured pages into a single PDF.
- Share the generated PDF via the OS share sheet, or download it directly
  on web when the Web Share API isn't available.
- Material 3 UI that follows the system's light/dark theme.

### Privacy

- Captured photos and generated PDFs are never persisted by the app:
  temp files are deleted as soon as a page is removed, the list is cleared,
  the app closes, or right after handing the PDF off to the share sheet.
