# F-Droid milestone: local CI-image build and artifact verification

**Reached:** successful build through F-Droid tooling in a local instance of
its CI buildserver image, with source and binary scanning enabled. This is not
a hosted GitLab pipeline, inclusion approval, or a signed release.

## Exact inputs

- App: public `v1.6.0`, `8530fa1c58844cb292219922d6881b4b64aa1163`, plus
  [the recipe patch](../../contrib/fdroiddata/metadata/com.fosscanner.app/native-source.patch).
- [Recipe](../../contrib/fdroiddata/metadata/com.fosscanner.app.yml):
  `com.fosscanner.app:2011`, ARM64 split, F-Droid signing selected.
- F-Droid server: `fc2c86473e66a44fc641f403c338a8b2cccfad88`.
- CI image: `registry.gitlab.com/fdroid/fdroidserver@sha256:1ea8bef1820bff06c2974e31b4fc4c79c364cd24231b86e71fa4b926797e0dac`.
- SUSS database used by the successful build: SHA-256
  `497d4f75cb6965a7d096139b53583789637a7b3abed9f7335b45973c85c9d796`.
- Toolchain: Flutter 3.44.0, Java 21, NDK r28c. Source library revisions and
  the source-only OCR module are specified in the recipe.

## Executed build

```text
fdroid build --verbose --test --on-server --refresh-scanner --scan-binary --no-tarball com.fosscanner.app:2011
```

It reported `1 build succeeded`, exited 0, and produced the unsigned
`tmp/com.fosscanner.app_2011.apk`. That APK was independently copied and checked:

| Check | Result |
| --- | --- |
| SHA-256 | `5072b0e922325f22b9a059b4b84ef8470ad4e2f3962a1bbd5a4ec1ece8440db2` |
| Identity | `com.fosscanner.app`, `1.6.0`, version code `2011` |
| ABI | `arm64-v8a` only |
| F-Droid source scan | Passed in the actual build, with the specific recipe cleanup applied |
| F-Droid APK scan | `dexdump` and extra-signing-block checks passed |
| Permissions | The manifest decoded from this APK passed the release allowlist |
| Signing | Unsigned as intended: `apksigner verify` rejected it with `Missing META-INF/MANIFEST.MF` |
| Native origins | The build IDs of all four OCR JNI libraries matched the source-built `standardRelease` AAR |
| Alignment | `zipalign -c -P 16 4` passed; all eleven packaged shared objects were ARM64 and their ELF load segments had >=16 KiB alignment |
| Bundled OCR data | The model, license and native notices matched the tracked files byte-for-byte |

The same container subsequently checked the upstream working-tree signing
configuration using Gradle dry runs: default release without keys **refused**;
explicit unsigned mode without keys **accepted**; unsigned mode plus a dummy
`key.properties` **refused**. No production signing material was used.

## Failures encountered and resolved

- NDK provisioning stalled. The resumed upstream archive matched both hashes
  in sdkmanager's signed checksum list; the package manager installed it.
- A cold Flutter tool bootstrap populated analyzer/archive examples not present
  in the earlier warm-SDK rehearsal. The recipe now removes those specific
  executable/archive test fixtures, not runtime source or whole dependencies.
- The first compilation attempt exceeded the container's 4 GiB limit
  (`OOMKilled=true`). The retry used 6 GiB, two CPUs, and
  `CMAKE_BUILD_PARALLEL_LEVEL=2`; it completed with `OOMKilled=false`.

No earlier application SDK/Gradle caches were mounted into this CI-image run.
Provisioned toolchain and dependency downloads were retained between retries.
Networking was available for normal provisioning and dependency resolution.
This is **not** proof of an empty-cache one-shot build or reproducibility.

## Remaining gates

1. Review and merge the upstream unsigned-build/CI and store-metadata changes.
   The corrected Fastlane copy and screenshots are still local and are not
   part of immutable v1.6.0. Choose the final public source revision accordingly.
2. Submit the prepared recipe only with maintainer approval and obtain a hosted
   fdroiddata pipeline result. The new-app template prefers upstream source
   submodules; the draft explicitly asks review of its pinned-srclib approach.
3. Review licensing/attribution for the full resolved dependency graph. Scanner
   success is not an independent license audit.
4. Test native camera, OCR/PDF, import, sharing, draft recovery and accessibility
   on the selected signed candidate. Test updates within F-Droid's signing
   identity. Do not install an unsigned packaging input as a release or infer
   device acceptance from Linux widget tests.

The earlier [preflight history](fdroid-preflight.md) records individual probes
and failed attempts; the artifact identified here is the successful CI-image
result. Publication and a F-Droid availability badge remain out of scope.
