#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION}"
: "${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY}"
git diff --quiet && git diff --cached --quiet || { echo 'Commit the release sources before packaging.' >&2; exit 1; }
test -z "$(git ls-files --others --exclude-standard)" || { echo 'Untracked source files must be committed before packaging.' >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/MacCAD.app/Contents/Info.plist)" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacCADSourceRevision' build/MacCAD.app/Contents/Info.plist)" = "$(git rev-parse HEAD)"
rm -rf build/release build/update-feed build/corresponding-source
mkdir -p build/release build/update-feed build/corresponding-source/.cargo
cp build/MacCAD.dmg build/release/MacCAD.dmg
# Updates use a zip so signing/notarization does not require mounting a DMG.
ditto -c -k --sequesterRsrc --keepParent build/MacCAD.app build/update-feed/MacCAD.app.zip
previous=$(gh release list --limit 1 --json tagName --jq '.[0].tagName // empty')
if [ -n "${RELEASE_NOTES_FILE:-}" ]; then
  cp "$RELEASE_NOTES_FILE" build/release-notes.md
elif [ -n "$previous" ] && git rev-parse --verify "refs/tags/$previous" >/dev/null 2>&1; then
  git log --no-merges --pretty='- %s' "$previous..HEAD" > build/release-notes.md
else
  git log -15 --no-merges --pretty='- %s' > build/release-notes.md
fi
test -s build/release-notes.md || echo '- Initial development release' > build/release-notes.md
cp build/release-notes.md build/update-feed/MacCAD.app.md
appcast_args=(--maximum-deltas 0 --embed-release-notes --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/")
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file - "${appcast_args[@]}" build/update-feed
else
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast --account xyz.ckakkar.maccad "${appcast_args[@]}" build/update-feed
fi
cp build/update-feed/MacCAD.app.zip build/update-feed/appcast.xml build/release/
# GPL corresponding source includes the exact locked Rust dependency sources,
# rather than relying on a future crates.io download to rebuild this release.
git archive HEAD | tar -x -C build/corresponding-source
cargo vendor --locked build/corresponding-source/vendor > build/corresponding-source/.cargo/config.toml
mkdir -p build/corresponding-source/third_party
cp .build/libredwg-0.14.tar.gz build/corresponding-source/third_party/
tar -czf build/release/MacCAD-source.tar.gz -C build/corresponding-source .
(cd build/release && shasum -a 256 MacCAD.dmg MacCAD.app.zip MacCAD-source.tar.gz > SHA256SUMS)
