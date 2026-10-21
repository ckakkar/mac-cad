# Contributing

Read [AGENTS.md](AGENTS.md) for product and architecture decisions. Use Apple
Silicon and macOS 14+; install matching Xcode Command Line Tools and Rust stable.
Dependencies are pinned in Cargo.lock and Package.resolved.

Run `make check` before a change is ready. It checks Rust formatting, clippy,
geometry/command/exchange/ABI tests, a release app build, the actual Swift-to-Rust
bridge, bundle metadata/signing/linkage, and an app integration smoke check. The
latter compiles Metal shaders and exercises NSDocument, recovery payloads and PDF
output. It needs a logged-in graphical macOS session with Metal available.

Test UI changes in the actual app: toolbar and numeric input, cancellation,
selection, undo/redo, save/reopen, layer visibility/locking, dark/light appearance,
and scaled PDF output. Native and DXF fixtures must be generated or redistributable.
Record known interoperability gaps in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)
and user-facing changes in [CHANGELOG.md](CHANGELOG.md).

`make bench` reports CPU scene/index/pick timings and segment buffer size; it does
not measure frame rate or total memory. Qualify GPU performance with Instruments
on baseline M1 before claiming the 100k-entity/60-fps target.

## GitHub releases

Releases follow Trav's direct-download model, using a native Swift app and
Sparkle instead of Tauri. Every successful CI push to `main` triggers Release.
Version numbers are `<VERSION release line>.<commit count>` (for example `0.1.42`);
the build number is the commit count. Do not rewrite published main history.
Release verifies the exact tested SHA again and refuses to publish an older,
superseded commit or replace an existing version.

Assets: `MacCAD.dmg`, `MacCAD.app.zip`, `appcast.xml`, `SHA256SUMS`, and
`MacCAD-source.tar.gz` with the app sources, locked Rust dependencies, and an offline
Cargo source configuration. The appcast downloads a version-specific archive over
HTTPS, so publishing a later release cannot change an already advertised update.

### One-time update key configuration

Generate **new MacCAD keys**, not Trav keys. After `make build`, Sparkle's tools
are in `.build/artifacts/sparkle/Sparkle/bin`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /private/tmp/maccad-updater.key
```

Keep the private key securely backed up. Set repository **variable**
`SPARKLE_PUBLIC_KEY` to the printed base64 public key; set repository **secret**
`SPARKLE_PRIVATE_KEY` to the exported private key file's contents, then remove the
temporary export. Do not commit either a private key or a sample public key.
Release fails explicitly if the configuration is absent. Local builds omit the
update key and do not attempt to install unsigned updates. To build locally with
the real public key, set `SPARKLE_PUBLIC_KEY` in the build environment.

Sparkle 2.10 signs the archive, appcast and embedded notes. The app requires signed
feeds and archive verification before extraction. It prompts before installing an
update. Private keys never appear in command-line arguments or build logs.

### Optional Apple signing

GitHub secrets: `APPLE_CERTIFICATE` (base64 PKCS#12),
`APPLE_CERTIFICATE_PASSWORD`, and `APPLE_SIGNING_IDENTITY`. The workflow imports
the certificate into a temporary keychain and signs nested Sparkle components,
the framework and the app. For notarization add `APPLE_ID`, `APPLE_PASSWORD`
(app-specific) and `APPLE_TEAM_ID`. The release DMG is submitted and stapled.

Without these, the app is ad-hoc signed; documentation must not describe it as
notarized. Code signing and Sparkle update signing serve different purposes.
No Apple Developer account, App Store provisioning, or release key is needed for
`make run` / `make dmg`.

The release workflow is configured but is not exercised by a local `make check`.
Validate the first actual GitHub release, signed feed, download, install and
relaunch on a second Mac before advertising unattended update reliability.
