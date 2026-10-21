#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -m)" == arm64 ]] || { echo "Initial builds require Apple Silicon." >&2; exit 1; }
binary=".build/arm64-apple-macosx/release/MacCAD"
[[ -f "$binary" ]] || binary=".build/release/MacCAD"
framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
app="build/MacCAD.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
cp "$binary" "$app/Contents/MacOS/MacCAD"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp .build/libredwg-0.14/programs/dwg2dxf "$app/Contents/Helpers/dwg2dxf"
cp .build/libredwg-0.14/COPYING "$app/Contents/Resources/Licenses/LibreDWG-0.14-COPYING"
cp .build/libredwg-0.14/AUTHORS "$app/Contents/Resources/Licenses/LibreDWG-0.14-AUTHORS"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Licenses/Sparkle.txt"
python3 scripts/bundle-metadata.py
python3 scripts/dependency-notices.py "$app/Contents/Resources/Licenses"
xcrun swift scripts/icon.swift "$app/Contents/Resources/AppIcon.icns"
# Ad-hoc signing works without a Developer ID. Do not use hardened runtime for
# ad-hoc builds: its library validation prevents loading the signed Sparkle binary.
identity="${APPLE_SIGNING_IDENTITY:--}"
if [[ "$identity" != - ]]; then
  codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Helpers/dwg2dxf"
  while IFS= read -r executable; do codesign --force --timestamp --options runtime --sign "$identity" "$executable"; done < <(find "$app/Contents/Frameworks" -type f -perm +111)
  while IFS= read -r bundle; do codesign --force --timestamp --options runtime --sign "$identity" "$bundle"; done < <(find "$app/Contents/Frameworks" -depth -type d \( -name '*.xpc' -o -name '*.app' \))
  codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Frameworks/Sparkle.framework"
  codesign --force --timestamp --options runtime --sign "$identity" "$app"
else
  codesign --force --sign - "$app"
fi
echo "Built $app"
