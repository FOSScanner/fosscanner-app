# F-Droid packaging draft

These are inputs for the separate `fdroiddata` repository. They do not publish
an app or change the upstream GitHub release workflow. Copy `metadata/` and
`srclibs/` into a disposable, current `fdroiddata` checkout; reuse its existing
`flutter` and `opencv` srclibs. From that checkout:

```sh
fdroid rewritemeta --list com.fosscanner.app
fdroid lint com.fosscanner.app
fdroid build --test --server com.fosscanner.app:2011
```

The first two commands check metadata, not builder compatibility. The last
requires a configured F-Droid build server; retain its source scan and build
logs. Run `fdroid scanner --exit-code /path/to/output.apk` on its output. No
upstream keystore or debug signing should be used.

**Source selection:** the recipe pins public packaging-candidate commit
`d6b11d09611ed5ee94ad7932a5c588e018e67778` on
`build/fdroid-v1.6.0-candidate`. It is based on immutable v1.6.0 and includes the
unsigned-build option, corrected store metadata and native attribution fix.
It is not a new release tag or an assertion of device acceptance. The normal
upstream preparation PR still targets `dev` without importing release-only
version commits.

**Why the patch:** the recipe patch removes the JitPack repository/dependency
and selects the `standard` (non-OpenMP) OCR library from source. OpenCV and KleidiCV are supplied as extracted sources,
not as prebuilt libraries or a network download by the Flutter native hook.
The ARM64 split adds 2000 to the pubspec build number. Automatic recipe updates
are disabled because new Flutter and native versions need their own input audit.

**Source scanning:** exclusions apply to identified OpenCV samples/tests and
Leptonica fuzzer corpora, not production libraries. Nine locked pub packages
also ship unused example Gradle scripts containing dynamically constructed Maven
URLs. A cold Flutter tool bootstrap additionally resolves `analyzer` 10.1.0
(example executable) and `archive` 3.6.1 (sample ZIP and test resources). The
recipe removes those example scripts and fixtures, not either package’s `lib/`
code. Recheck the paths when changing versions. There are no `scanignore` or
`scandelete` rules.

See the [candidate validation](../../docs/releases/fdroid-attribution-fix.md)
and [preflight history](../../docs/releases/fdroid-preflight.md) for what was
actually exercised locally. The complete local CI-image F-Droid build and
artifact checks passed for the pinned candidate. A hosted fdroiddata pipeline,
inclusion review, F-Droid signing and signed-device acceptance remain separate
gates.

For a first inclusion, use the upstream [contribution guide](https://gitlab.com/fdroid/fdroiddata/-/blob/master/CONTRIBUTING.md)
and [new-app MR checklist](https://gitlab.com/fdroid/fdroiddata/-/blob/master/.gitlab/merge_request_templates/Default.md).
A [draft MR description](submission.md) explains the pinned libraries, signing
choice, and local evidence without marking untested gates complete. The
`fdroiddata` CI build job uses its `buildserver-trixie` Docker image. A branch
pipeline in an authorized public fork can test the recipe before opening the
inclusion MR. Neither step is necessary to run local metadata checks.
