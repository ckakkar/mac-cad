#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=build/MacCAD.app
plutil -lint "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == xyz.ckakkar.maccad ]]
[[ "$(lipo -archs "$app/Contents/MacOS/MacCAD")" == arm64 ]]
codesign --verify --deep --strict "$app"
otool -L "$app/Contents/MacOS/MacCAD"
test -s "$app/Contents/Resources/LICENSE"
test -s "$app/Contents/Resources/Licenses/ThirdPartyNotices.txt"
echo 'Bundle verified: Apple Silicon, plist, nested signature, linkage and notices.'
