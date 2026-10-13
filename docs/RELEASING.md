# Releasing TextPicker

## CI

`.github/workflows/build.yml` runs on main-branch pushes, pull requests and manual
dispatch. It uses the Apple Silicon `macos-15` runner and Xcode 16.4. Actions and uv
are version-pinned. The job fetches checksum-pinned models/dependencies, runs the
full automated suite, and archives the qualified app without rebuilding or
re-signing it. A ZIP round-trip checks every file and executable permission.

Only download archives are cached, not extracted dependency source, native
binaries or an old app. Cache contents are revalidated before use. Reports and
release candidates are short-lived Actions artifacts, not repository files.
A hosted runner passing automated checks is not a live capture/display test.

## Model pack bootstrap

The one-time `models-v1` release supplies the native model archive. Prepare it from
the already-qualified assets, outside Git:

```sh
.venv/bin/python -B scripts/model_pack.py \
  --output .build/model-release/TextPicker-native-models-v1.tar.gz
```

Archive metadata is deterministic; verify the resulting byte count and SHA-256
against `native/models/distribution.json` before uploading. It includes the model
manifest and PaddleOCR license. Never overwrite a published model asset; use a
new version and explicit checksum update if assets intentionally change.

For a new empty repository, push the reviewed source commit as the `models-v1`
tag first (it does not trigger application CI), then publish its approved model
release and archive. Push the same commit to `main` only after that asset is
available. This avoids an initial build racing a missing download.

## Application releases

1. Update `app/Info.plist`, `.github/release.json` and `.github/RELEASE.md`.
   Get explicit approval of the title, notes and preview/signing policy.
2. Commit and push the reviewed changes to `main`; require the complete CI job
   to pass. Perform relevant manual capture/display checks separately.
3. Push a version tag matching the plist and release configuration, e.g.
   `v0.11.0`. The tag workflow builds/tests that exact source commit.
4. The publish job verifies the downloaded artifact, checksums, tag and commit,
   then creates a **draft prerelease** with the committed notes. It never
   publishes automatically and refuses to replace an existing release.
5. Inspect the draft and attached ZIP/checksums/metadata. After explicit owner
   confirmation, publish the draft. Never move a published tag or silently
   replace a released binary.

The built app includes its models. No model pack is needed by end users.
`SHA256SUMS.txt` and `release-metadata.json` identify the distributed archive,
source commit, helper, model pack, architecture and signing status.

## Signing

The current pipeline produces **ad-hoc-signed, non-notarized previews**. It uses
no Apple credentials and makes no Developer ID or Gatekeeper-acceptance claim.
Do not use an Apple Development certificate as a distribution substitute.

Developer ID signing/notarization requires a separate implementation and owner-
provided credentials. Sign the helper before recording its build identity and
qualifying it; do not deep-re-sign it after validation. Notarize/staple the final
distribution and verify the result before replacing the current preview policy.
