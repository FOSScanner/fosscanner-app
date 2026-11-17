# Retrying APK publication for an existing release

The Release workflow supports a manual retry without moving a tag or changing
the application source. This is useful when signing/building succeeded but
publication failed.

## 1.5.0 failure

Run `43977853224` passed preflight, signed APK builds, and provenance attestation,
but failed when `softprops/action-gh-release` tried to update the release.
The pinned v3 action defaults its `token` input to `github.token`, which overrides
the `GITHUB_TOKEN` environment variable. The job's default token has read-only
Contents access. The fix passes `secrets.RELEASE_TOKEN` explicitly as an input.
That secret must grant Contents read/write access to this repository.

## Recovery procedure

1. Merge the workflow correction onto `main`. Rerunning the old failed job uses
   the old workflow and does not apply this fix.
2. Dispatch the corrected workflow from `main` for the existing tag:

   ```sh
   gh workflow run release.yml --repo FOSScanner/fosscanner-app \
     --ref main -f tag=v1.5.0
   ```

3. Review preflight results and approve the protected `release` environment as
   required. Do not bypass environment protection.
4. Confirm build, attestation, and upload all succeed. Verify both published APKs'
   signatures, package/version metadata, hashes, provenance, and production
   upgrade behavior before declaring closeout complete.

Manual runs check out the requested tag, require exact `vX.Y.Z` syntax and matching
pubspec version, verify checkout/tag equality and ancestry on `origin/main`, then
run analysis and tests. The build uses the validated commit; publication uses the
validated tag explicitly rather than the dispatch branch. Never move a published
tag to repair publishing infrastructure.

A retry rebuilds the APKs; the failed run did not save downloadable workflow
artifacts. No successful upload or device acceptance is implied by this guide.
