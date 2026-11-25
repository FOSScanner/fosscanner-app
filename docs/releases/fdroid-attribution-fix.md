# Native attribution fix and verification

## Implemented

The missing native barcode notices identified in #209 are now bundled alongside
native OpenCV, KleidiCV and CameraX/libyuv notices. `registerBundledLicenses`
exposes all four entries in **About → View licenses**, using the existing OCR
license registration mechanism. No dependency implementation or license is
changed. The [notice README](../../assets/licenses/README.md) documents the
source revisions, scope and regeneration procedure.

- ZXing native Apache notices, Zint BSD notices and additional credited
  contributors are retained from source comments, including quoted backend
  includes. All vendored barcode translation units in the prior ARM64
  compilation database were covered by the notice inventory.
- OpenCV's installed Android license set and companion files are included,
  together with historical BSD notices from the observed core/imgproc/imgcodecs
  source/header sets. The generator verifies clean pinned OpenCV/KleidiCV clones.
- KleidiCV's Apache license and Arm source copyright notices are included.
- CameraX's published source-license text and libyuv's BSD license, patent grant
  and author list are included. The notice source does not purport to identify
  the exact libyuv code commit inside the Maven AAR.
- Existing OCR notices remain registered. Flutter engine notices are not
  duplicated: the checker verifies each engine license body in `NOTICES.Z`.

## Rebuilt verification artifact

SHA-256: `883bb4803dd82f86375cc183f9e0fde9984c8272c12d349b620437a00847e9bc`.

This is an **unsigned development verification input**, package
`com.fosscanner.app`, version `1.5.2`, version code `2010`, ARM64 only. Its
version reflects `dev`; no release version was manually bumped.

Build context: reused the successful local F-Droid CI-image source-build tree
and its provisioned caches. Overlaid the proposed `lib/main.dart`, `pubspec.yaml`
and notice assets, retaining the source OCR/OpenCV recipe substitutions. Ran
Flutter's release ARM64 build directly, **not a new invocation of the complete
`fdroid build` recipe**. The old v1.6.0 recipe and old APK remain unchanged.

Checks actually performed on this rebuilt APK:

| Check | Result |
| --- | --- |
| Four native notice assets | Byte-identical to the reviewed tracked texts; their provenance hashes matched |
| Flutter engine notices | All 1,594 license bodies from the pinned `sky_engine/LICENSE` were present |
| Permissions | Packaged manifest passed the release allowlist |
| Signing | `apksigner verify` rejected it for the expected missing JAR manifest: unsigned input |
| ZIP alignment | `zipalign -c -P 16 4` passed |
| ELF alignment | All eleven ARM64 shared objects had >=16 KiB load-segment alignment |
| Native origins | Nine non-app libraries were byte-identical to the previously scanned source-build APK, including OCR, CameraX, Flutter, JNI and barcode libraries |
| Regenerated DartCV output | Packaged build ID `647a59359dcddf48f92b252b30a3528e51376487` matched the current CMake install; its installed OpenCV notice set was unchanged |

Dart AOT and DartCV outputs changed; no byte-for-byte reproducibility is claimed.

Fresh local checks: analysis, **435 Flutter tests**, and **24 Python tests**
passed. These include full native license registration/body retention, the
licenses UI at 200% text, source-hash checks, and negative APK tests for missing,
modified or unreviewed notices. UI tests let real decoding isolates complete;
they do not bypass the production license registry. Repeating generation from
the pinned inputs produced identical notice and provenance hashes.

CI's unsigned-build check now runs the packaged-native-notice verifier, including
engine bodies. A passing historical CI run is not proof for these new changes;
verify the latest PR head separately.

## Complete F-Droid candidate validation

The source-selection gap is now also addressed: the recipe pins public commit
`d6b11d09611ed5ee94ad7932a5c588e018e67778` on
`build/fdroid-v1.6.0-candidate`. This branch is based on immutable v1.6.0 plus
the preparation/attribution fixes; it preserves version `1.6.0` (`2011`).
`dev` is not manually version-bumped. The recipe patch now only substitutes
source-built native dependencies, since unsigned mode is already in the source.

A subsequent **complete** local CI-image run succeeded:

```text
fdroid build --verbose --test --on-server --refresh-scanner --scan-binary --no-tarball com.fosscanner.app:2011
```

- Exit 0, `1 build succeeded`, source scan and APK scans passed.
- APK SHA-256: `c4f52ebac3f3cff8969aa36648f5e12dc5ce4c70fabd99774db8e68ab59b289b`.
- Package/version/ABI: `com.fosscanner.app`, `1.6.0`, `2011`, ARM64 only.
- All four native notice assets matched reviewed source bytes. All 1,594
  Flutter engine license bodies were present. OCR model/notices also matched.
- Permissions, expected unsigned status, ZIP 16 KiB alignment, and all eleven
  native ELF load-segment alignment checks passed.
- Four OCR JNI build IDs matched the freshly built source-module AAR. DartCV's
  packaged build ID `48333604698814913e16f9e061442d25efb0ddcd` matched its CMake
  installation output.
- SUSS database SHA-256:
  `88da8b3c55b3bb84e0099ac1ea617c90aac64678f5c2237f7f1abf262c80b63a`.
- Exact candidate source passed analysis, 435 Flutter tests and 24 Python tests
  in a separate local container. The upstream test also exercises opening the
  barcode notice detail page at 200% text.

This used the same pinned CI image/server as the earlier milestone, two CPUs,
6 GiB memory and retained provisioning/download caches. It is neither a cold
one-shot/reproducible-build result nor a hosted GitLab pipeline. No F-Droid key
or upstream release key was used. The packaging-candidate branch is a pinned
review input, not a published release or an authorization to submit it.

## Gates that remain outside this fix

1. **Upstream and inclusion review:** review/merge the preparation PR and approve
   the pinned packaging source (or choose a later reviewed release and rebuild).
   No source tag or release has been created or changed. The source-selection
   and notice defects themselves no longer require an unreleased local file.
2. **Device acceptance:** no Android device was exposed to the build
   environment (`adb devices -l` was empty); no configured AVD/system image was
   found there. Host USB descriptors exposed only its camera, fingerprint
   reader, Intel device and controllers, not an Android phone. No APK was
   installed on a personal device. Widget/native Linux tests and static 16 KiB
   checks do not establish camera, TalkBack, sharing or Android runtime behavior.
   Use a synthetic-document test session on an authorized ARM64 Android device.
3. **Distribution signing/updates:** no F-Droid-signed release exists yet for
   final same-channel upgrade acceptance. A local test certificate can support
   development testing but cannot stand in for F-Droid's signing identity.
4. **Inclusion review:** source/binary scanning and attribution checks do not
   replace the F-Droid maintainers' policy review of the selected dependency
   graph and recipe.

The concrete missing-notice defect is remediated in source and the rebuilt
verification artifact. These remaining gates must not be represented as
completed, and no F-Droid submission, publication, tag or release is authorized
by this fix.
