# Tychedit 1.0.1

## Fixed

- Rendering: content an AI placeholder writes straight after its opening
  tag's `-->`, with no newline before it, now renders instead of being
  silently dropped.
- Release tooling (`build.sh`):
  - `dmg` no longer fails to sign the app when the Developer ID
    certificate's name contains an accented character -- `codesign`
    mis-decoded it and reported "no identity found" even though the
    certificate was valid; the app is now signed by the certificate's
    SHA-1 hash instead of its display name.
  - `notarize` now resolves the disk image from the project's current
    marketing version instead of the newest file in `build/`, so it can
    no longer submit a stale image left over from an earlier version or a
    failed `dmg` run.
  - `notarize` no longer triggers the `hdiutil attach` deprecation warning
    when verifying the image's signature.
