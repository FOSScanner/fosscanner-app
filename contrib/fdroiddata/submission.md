# Draft MR: New app: FOSScanner

**Review draft only.** Copy the recipe files into `fdroiddata`; do not add this
note to its metadata directory. Complete the live new-app checklist at submission.

FOSScanner scans and straightens document pages on-device. Users can adjust
corners and filters, collect multiple pages and share an image-only PDF. On
Android, searchable text is opt-in and uses a bundled Latin OCR model; documents
do not need to leave the device for recognition. The large model is one reason
the recipe produces an ARM64 split rather than a universal APK.

**UI examples at the pinned candidate:** [multi-page document](https://github.com/FOSScanner/fosscanner-app/blob/d6b11d09611ed5ee94ad7932a5c588e018e67778/docs/screenshots/ui-home-pages.png),
[crop and adjustment](https://github.com/FOSScanner/fosscanner-app/blob/d6b11d09611ed5ee94ad7932a5c588e018e67778/docs/screenshots/ui-adjust-appearance.png),
[PDF options](https://github.com/FOSScanner/fosscanner-app/blob/d6b11d09611ed5ee94ad7932a5c588e018e67778/docs/screenshots/ui-export-options.png).
These are synthetic Flutter renders, not evidence of camera or OCR behavior.

**Proposed build:** `com.fosscanner.app:2011`, pinned packaging candidate
`d6b11d09611ed5ee94ad7932a5c588e018e67778`, based on upstream `v1.6.0` with
unsigned packaging, native attribution and store-metadata corrections. This is
not a new release tag. Use F-Droid signing. The upstream
GitHub certificate is not shared and direct updates between channels are not
supported. Upstream-signature reproducibility has not been established.

**Packaging choices for reviewers:** The candidate has no native-source Git
submodules. The patch and pinned source libraries replace the upstream JitPack
OCR binary and the OpenCV build-time download.
The two proposed srclib definitions are an exception to the MR template's
preference for upstream submodules, not a change to F-Droid's policy. If the
packagers require submodules, prepare a new upstream revision. Automatic update
checks use tags; build recipe updates remain manual pending native input review.

**Review gates:** The complete local F-Droid build and scans passed for this
pinned candidate. APK SHA-256:
`c4f52ebac3f3cff8969aa36648f5e12dc5ce4c70fabd99774db8e68ab59b289b`.
Native/engine notice, permission and alignment checks passed; see
`docs/releases/fdroid-attribution-fix.md`. These are not a hosted fdroiddata
pipeline result. Attach the build job URL and inspect its actual APK
before marking the pipeline item complete. Confirm asset attributions and store
copy, including the post-share draft wording in the pinned candidate. Do not claim
that a signed F-Droid APK or an install/upgrade test exists yet.

Upstream coordination: [readiness #213](https://github.com/FOSScanner/fosscanner-app/issues/213),
[packaging #210](https://github.com/FOSScanner/fosscanner-app/issues/210),
[artifact acceptance #211](https://github.com/FOSScanner/fosscanner-app/issues/211).
