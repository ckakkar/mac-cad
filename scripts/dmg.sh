#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build/dmg-root
mkdir -p build/dmg-root
ditto build/MacCAD.app build/dmg-root/MacCAD.app
ln -s /Applications build/dmg-root/Applications
rm -f build/MacCAD.dmg
hdiutil create -volname MacCAD -srcfolder build/dmg-root -ov -format UDZO build/MacCAD.dmg
rm -rf build/dmg-root
