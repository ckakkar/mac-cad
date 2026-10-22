# Contributing

Read [AGENTS.md](AGENTS.md). Build on Apple Silicon, macOS 14+, with matching Xcode
Command Line Tools, Rust stable, Python 3 and `pkgconf` (`brew install pkgconf`).
Cargo.lock, Package.resolved and the LibreDWG tarball checksum pin dependencies.

Run `make check`: formatting, clippy, geometry/editing/exchange/ABI tests, release
app build, Swift/C/Rust bridge, bundle architecture/signature/linkage/notices, and
an app integration check. The latter needs a graphical macOS session and Metal.
It also runs the actual command field editor and sequential drafting/editing
workflows (Space/Return, repetition, selection, numeric input, options, cancellation,
text and compound objects). It exercises NSDocument safe saves/reopen, recovery payloads, scene buffers, the
Metal pipeline, PDF and bundled DWG imports using upstream 2000/2013/2018 fixtures.

Test UI changes in the actual app: gestures/numeric input, cancellation, selection,
undo/redo, multiple windows, layer/property edits, both appearances and PDF output.
Fixtures must be generated or redistributable. Record limitations in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) and changes in [CHANGELOG.md](CHANGELOG.md).
`make bench` measures CPU work and segment-buffer size, not GPU frame rate or total
memory. Qualify performance on baseline M1 before making the 100k/60-fps claim.

## Local GitHub releases

The owner chose to keep the private update-signing key **local**. CI still runs on
pull requests and pushes. Cloud publishing is disabled unless repository variable
`MACCAD_CLOUD_RELEASES` is explicitly set to `true` and separately authorized signing
credentials are configured. Do not transfer the local key to GitHub by default.

Version is `<VERSION release line>.<commit count>`; build number is the commit
count. Publish only a clean committed, tested main SHA; do not rewrite published
history or replace released artifacts. The bundle records its source revision.

The existing MacCAD Sparkle key lives in macOS Keychain under account
`xyz.ckakkar.maccad`. Its public half is tracked in `config/SparklePublicKey` and
embedded in all builds. Release tools use the account directly without exporting
the private key. Keep a secure owner-controlled backup; losing this key prevents
signing updates trusted by installed builds. Never read or reuse Trav's keys.

After committing the release changes:

```sh
export VERSION="$(cat VERSION).$(git rev-list --count HEAD)"
export BUILD_NUMBER="$(git rev-list --count HEAD)"
export GITHUB_REPOSITORY=ckakkar/mac-cad
make check
make dmg
RELEASE_NOTES_FILE=docs/RELEASE_NOTES.md bash scripts/release-assets.sh
```

The final command needs GitHub CLI authentication and access to the local Keychain.
It generates `build/release/` with `MacCAD.dmg`, `MacCAD.app.zip`, `appcast.xml`,
`SHA256SUMS` and `MacCAD-source.tar.gz`. The source archive contains the exact Git
revision, vendored locked Rust dependencies, offline Cargo configuration and the
original LibreDWG source tarball. Sparkle stays pinned by Package.resolved.

Inspect checksums, versions, source archive and signed feed, then publish the exact
SHA using `gh release create` with `--target` and `--notes-file`. Verify the uploaded
asset hashes and mount the DMG to inspect its app and Applications shortcut.
Updates use a version-specific HTTPS zip URL; later releases cannot replace the
archive already advertised in an installed feed.

Sparkle 2.10 signs the update archive, feed and embedded notes. The app requires
signed feeds and archive verification before extraction, and prompts before
installation. In a separately authorized cloud setup the script accepts
`SPARKLE_PRIVATE_KEY` via environment/stdin; never put keys in CLI arguments/logs.
Do not regenerate/replace `config/SparklePublicKey` for routine releases.

## Apple signing and notarization

Local `make run` / `make dmg` needs no Apple Developer account or private signing
key. Default bundles are ad-hoc signed and **not notarized**. Downloads may need
Open Anyway in System Settings → Privacy & Security on first launch.

Set `APPLE_SIGNING_IDENTITY` for Developer ID signing. The optional cloud workflow
supports secrets `APPLE_CERTIFICATE` (base64 PKCS#12),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, and for notarization
`APPLE_ID`, `APPLE_PASSWORD` (app-specific), `APPLE_TEAM_ID`. It uses a temporary
keychain and submits/staples the DMG. Sparkle signatures and Apple code signing
serve different purposes.

Local tests do not establish a successful remote update installation. Test signed
updates and relaunch on a second Mac, Gatekeeper first launch, and any optional
notarization before claiming those paths are qualified.
