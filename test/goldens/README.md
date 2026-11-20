# Responsive document UI regressions

Run with the repository-pinned **Flutter 3.44.0 / Dart 3.12 on Linux**, matching
CI. The exact SDK matters for font rasterization and Material defaults.

```sh
flutter pub get
flutter test test/goldens/document_screens_test.dart
# After reviewing an intentional visual change:
flutter test --update-goldens test/goldens/document_screens_test.dart
```

Review the changed PNGs rather than accepting all generated baselines blindly.
Do not run baseline updates in CI. Normal `flutter test` asserts the baselines;
CI uploads `test/**/failures/**` (actual, expected, isolated/masked diffs) when
checks fail. To reproduce in Docker, use the Flutter image pinned by the
repository Dockerfile and run the same commands inside `/app`.

## Bounded matrix

`test/support/layout_stability.dart` owns logical viewport, device pixel ratio,
text scale, theme setup, font loading, and `expectStableRects`. Tests set physical
pixels to logical size × DPR. Golden images are captured at logical resolution;
DPR still exercises framework density-dependent behavior, but these images are
not a sharpness or native-memory benchmark.

| Configuration | Logical viewport | DPR | Text | Theme |
| --- | --- | --- | --- | --- |
| Small phone | 320×568 | 1 | 200% | Light |
| Phone | 390×844 | 3 | 100% | Light |
| Landscape | 640×300 | 2 | 100% | Dark |
| Tablet | 800×1280 | 1.5 | 130% | Light |
| Narrow window | 240×640 | 1 | Nonlinear fixture | Dark |

Every configuration covers empty/populated home, crop, and ready filter preview.
Additional baselines cover pending/updating/failed previews with useful-size and
stable-geometry assertions, large-text export options and saved-page preview,
landscape page preview with simulated cutouts, draft-session startup/failure,
a short-screen large-text barcode result, camera permission failure, and narrow
export generating/cancelling/opening-share statuses. Geometry tests also cover last-row
camera clearance, About/empty-state scrolling, breakpoint preview sizes,
resize state preservation, and narrow app-bar action reachability.

Fonts come from the pinned Flutter SDK (Roboto and Material Icons), not the host.
The test platform is explicitly Android; these are not iOS baselines. Animation
frames are advanced by fixed durations, ready states settle before capture, and
image decoding is completed before matching. The nonlinear scaler deliberately
exercises `TextScaler.scale(fontSize)` but does **not** model an actual Android
or iOS scaling curve; device validation is still required.

All document content is generated synthetic text and shapes. No real scans,
personal information, screenshots of personal documents, or network data belong
in these fixtures.

## Boundaries and remaining issue coverage

This is the initial asserted screenshot suite for #198, building the shared
harness proposed by #147. The matrix is representative, not a Cartesian product
of every viewport, platform, theme, and state. Export busy states freeze a
mocked OCR initialization or share boundary; the native OS share sheet is not
rendered. The permission-error fixture shares the existing camera mock with
behavior tests; it is not evidence of actual permission recovery on hardware.
Native camera textures, pickers, share sheets, hardware cutouts, gestures,
nonlinear OS text scaling, foldable hinges, and memory behavior require device
validation (#199). PR #200 separately supplies home/editor/startup cutout-safe
handling; this branch does not duplicate it.
