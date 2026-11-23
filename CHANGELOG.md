# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.6.0](https://github.com/FOSScanner/fosscanner-app/compare/v1.5.2...v1.6.0) (2026-11-23)


### Features

* **ux:** preserve accessible page reordering actions in the compact document layout ([dcadcb3](https://github.com/FOSScanner/fosscanner-app/commit/dcadcb3c1a99d5cd54f44cd1856bc0b0ff849078))


### Bug Fixes

* **android:** restrict merged release permissions ([9b0e247](https://github.com/FOSScanner/fosscanner-app/commit/9b0e2476b10d246e276863f275ae35df17278793))
* **build:** align release candidate lockfile with pinned Flutter SDK ([cf03f2b](https://github.com/FOSScanner/fosscanner-app/commit/cf03f2b3780b5995934ef49e5349a0c45dbf9fe5))
* preserve batch review context and control positions ([51c8273](https://github.com/FOSScanner/fosscanner-app/commit/51c8273c0014faf79eb6ecda5e282cff377b31d0))
* protect cached drafts after restoration failures ([2e2d06d](https://github.com/FOSScanner/fosscanner-app/commit/2e2d06d5afbd3a844f90d24e2820375bffd98591))
* **ui:** adapt document layouts and add visual regressions ([e6ba16e](https://github.com/FOSScanner/fosscanner-app/commit/e6ba16eafe1ebbddc2319ba1a6385ef240bd685f))
* **ui:** keep OCR options beside PDF export ([01c4b7e](https://github.com/FOSScanner/fosscanner-app/commit/01c4b7eac0a0b920f53a0cae1472740566e73716))
* **ui:** protect screen bodies from cutouts and scroll crop errors ([ea1b911](https://github.com/FOSScanner/fosscanner-app/commit/ea1b9117a0597e57c88ddb76e7ccede16e1a064c))
* **ui:** restore compact previews and remove persistent hints ([8e3e932](https://github.com/FOSScanner/fosscanner-app/commit/8e3e932504861f77f9cb9ab124c77c63b07cbb7b))
* **ux:** explain image intake availability and limits ([1cc5cda](https://github.com/FOSScanner/fosscanner-app/commit/1cc5cdaad6585d88de053c83f01bfedaff9d022d))
* **ux:** make document camera failures actionable ([10e244b](https://github.com/FOSScanner/fosscanner-app/commit/10e244be6fa7c194258a80494999347bc6afa399))
* **ux:** protect draft recovery and clarify scanner actions ([dd79468](https://github.com/FOSScanner/fosscanner-app/commit/dd794681eeb2364f00943ca08f5d5206fc843d5e))

### Known limitations

* Temporary import/share document copies can remain in the app cache after Clear all. Cleanup issue [#157](https://github.com/FOSScanner/fosscanner-app/issues/157) remains open; this release does not claim complete temporary-copy deletion.

## [1.5.2](https://github.com/FOSScanner/fosscanner-app/compare/v1.5.1...v1.5.2) (2026-11-18)


### Bug Fixes

* release simplified editor controls in 1.5.2 ([510d192](https://github.com/FOSScanner/fosscanner-app/commit/510d192fc614a311f905b04f6bafa3c2ae1cedb6))
* simplify crop tools and show filters on demand ([bd22a5c](https://github.com/FOSScanner/fosscanner-app/commit/bd22a5c1caf09c0e5a7102849421c8ed041a6a25))
* simplify the editor and show filters on demand ([7774d4a](https://github.com/FOSScanner/fosscanner-app/commit/7774d4a25fe93d39aeffa5f5ec066eadcbe075dd))

## [1.5.1](https://github.com/FOSScanner/fosscanner-app/compare/v1.5.0...v1.5.1) (2026-11-17)


### Bug Fixes

* expand the corner-editing canvas ([01a6910](https://github.com/FOSScanner/fosscanner-app/commit/01a6910ebb33626d1b6dc3d91cd3277d1ab6121f))
* give corner editing priority in responsive layouts ([ca7692b](https://github.com/FOSScanner/fosscanner-app/commit/ca7692b88f47df3f9078b61759ad310c4686919c))
* pass release token explicitly and support tagged retries ([3196795](https://github.com/FOSScanner/fosscanner-app/commit/319679533b405273692f38166f21d22d45d54630))
* release expanded corner editor in 1.5.1 ([9077fa7](https://github.com/FOSScanner/fosscanner-app/commit/9077fa799f089aa5a7c8804e7caef8bdb148f055))
* repair release uploads and allow tagged recovery ([f5a8d9c](https://github.com/FOSScanner/fosscanner-app/commit/f5a8d9cee3ea042d9e45a1ab9fc8f93c907595c6))

## [1.5.0](https://github.com/FOSScanner/fosscanner-app/compare/v1.4.0...v1.5.0) (2026-11-16)


### Features

* prepare scanner UI improvements for 1.5.0 ([6efbcd8](https://github.com/FOSScanner/fosscanner-app/commit/6efbcd8039b6ef00a1532f7b534d971f6a2c98b3))
* release scanner UI improvements for 1.5.0 ([cc8ced4](https://github.com/FOSScanner/fosscanner-app/commit/cc8ced4b6b6cb50c8c9620005316e93a6948e690))
* **ui:** improve page editing guidance and accessible adjustments ([9472d4c](https://github.com/FOSScanner/fosscanner-app/commit/9472d4c77444d33c46f18c69d4f979ca9a101ba3))
* **ui:** simplify document review and PDF export controls ([8cfba94](https://github.com/FOSScanner/fosscanner-app/commit/8cfba9434a8126baa192d0daf72dd99466cc0519))


### Bug Fixes

* account for retained images and serialize memory-heavy jobs ([0f24d08](https://github.com/FOSScanner/fosscanner-app/commit/0f24d080e70b6a3231cd3df780d5465ea7d786ac))
* account for retained images and serialize memory-heavy jobs ([4ce0fee](https://github.com/FOSScanner/fosscanner-app/commit/4ce0fee7f41a328b683ae37b76e74203f4c97fef)), closes [#73](https://github.com/FOSScanner/fosscanner-app/issues/73)
* **android:** restore production identity in release candidate ([fdd193c](https://github.com/FOSScanner/fosscanner-app/commit/fdd193c08d47edac1a005e6b6fdd6b9040da1569))
* **ui:** allow complete inspection of scanned codes ([c86975b](https://github.com/FOSScanner/fosscanner-app/commit/c86975b4d803115c57fb94e9356ea0031a757a29))
* **ui:** match page review actions to image intake context ([96bcfe3](https://github.com/FOSScanner/fosscanner-app/commit/96bcfe3fc57526b44c23476f7d76a7bf53f1d730))
* **ui:** preserve full image when page edges are not detected ([de72dd2](https://github.com/FOSScanner/fosscanner-app/commit/de72dd2394e036a6ecbac65b4bd865b6d7b2e4e2))
* **ui:** reconcile editor and export flows for release candidate ([d7883ed](https://github.com/FOSScanner/fosscanner-app/commit/d7883ed7033d1505c2f69312064e17071e2c1fa6))
* **ui:** repair crop handle drags and default OCR to off ([ee25ec1](https://github.com/FOSScanner/fosscanner-app/commit/ee25ec18c3cadb5f65e516bac9627696d9b8464f))
* **ui:** require a current adjustment preview before confirming ([d0f65e1](https://github.com/FOSScanner/fosscanner-app/commit/d0f65e12cf6e0e1e647cae52eb566cc424cf88e9))
* **ux:** retain drafts and protect actionable failure feedback ([78749b2](https://github.com/FOSScanner/fosscanner-app/commit/78749b2d29c6788589ac3563405b874136d47886))

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
