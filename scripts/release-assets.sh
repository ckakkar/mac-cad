#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION}"
: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY}"
mkdir -p build/release build/update-feed build/corresponding-source/.cargo
cp build/MacCAD.dmg build/release/MacCAD.dmg
# Updates use a zip so signing/notarization does not require mounting a DMG.
ditto -c -k --sequesterRsrc --keepParent build/MacCAD.app build/update-feed/MacCAD.app.zip
previous=$(gh release list --limit 1 --json tagName --jq '.[0].tagName // empty')
if [ -n "$previous" ] && git rev-parse --verify "refs/tags/$previous" >/dev/null 2>&1; then
  git log --no-merges --pretty='- %s' "$previous..HEAD" > build/release-notes.md
else
  git log -15 --no-merges --pretty='- %s' > build/release-notes.md
fi
test -s build/release-notes.md || echo '- Initial development release' > build/release-notes.md
cp build/release-notes.md build/update-feed/MacCAD.app.md
printf '%s' "$SPARKLE_PRIVATE_KEY" | .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --ed-key-file - --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$VERSION/" \
  build/update-feed
cp build/update-feed/MacCAD.app.zip build/update-feed/appcast.xml build/release/
# GPL corresponding source includes the exact locked Rust dependency sources,
# rather than relying on a future crates.io download to rebuild this release.
git archive HEAD | tar -x -C build/corresponding-source
cargo vendor --locked build/corresponding-source/vendor > build/corresponding-source/.cargo/config.toml
tar -czf build/release/MacCAD-source.tar.gz -C build/corresponding-source .
shasum -a 256 build/release/MacCAD.dmg build/release/MacCAD.app.zip build/release/MacCAD-source.tar.gz > build/release/SHA256SUMS
