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
   Get explicit approval of the title and notes.
2. Commit and push the reviewed changes to `main`; require the complete CI job
   to pass. Perform relevant manual capture/display checks separately.
   Check the job's **OCR benchmark** summary against the latest release. Release
   tags fail if OCR is more than 15% slower overall; a deliberate trade-off needs
   explicit approval and a note in the release text.
3. Push a version tag matching the plist and release configuration, e.g.
   `v0.11.0`. The tag workflow builds/tests that exact source commit.
4. The publish job verifies the downloaded artifact, checksums, tag and commit,
   then creates a **draft release** with the committed notes. It never
   publishes automatically and refuses to replace an existing release.
5. Inspect the draft and attached ZIP/checksums/metadata. After explicit owner
   confirmation, publish the draft. Never move a published tag or silently
   replace a released binary.

The built app includes its models. No model pack is needed by end users.
The download is always named `TextPicker-arm64.zip`, so
`releases/latest/download/TextPicker-arm64.zip` links to the newest version.
`SHA256SUMS.txt` and `release-metadata.json` identify the distributed archive,
source commit, helper, model pack, architecture and signing certificate.

## Signing

Releases are signed with one long-lived **self-signed certificate**
("TextPicker Self-Signed (georgiansarghi)"). It is not trusted by Gatekeeper, so
users still approve the first launch, but its stable identity lets macOS keep
Screen Recording and Accessibility grants across updates. Ad-hoc signatures change
with every build and lose those grants.

- `.github/release.json` pins the certificate's SHA-256 (`certificate_sha256`).
  CI refuses to stage a release signed with anything else.
- CI imports it from the `TEXTPICKER_SIGNING_P12` (base64 PKCS#12) and
  `TEXTPICKER_SIGNING_PASSWORD` repository secrets into a temporary keychain.
  Builds without the secrets (fork pull requests) fall back to ad-hoc; release
  tags fail instead.
- Only the outer app is certificate-signed. The OCR helper keeps the ad-hoc
  signature it was qualified with; never deep-re-sign it.
- **Never replace or lose the certificate.** A new certificate is a new identity
  and every user must grant permissions again. Keep the `.p12` and its password
  in a password manager.

Moving to Developer ID signing and notarization later is also an identity change
(one final permission reset). Sign the helper before recording its build identity
and qualifying it, then notarize and staple the final distribution.
