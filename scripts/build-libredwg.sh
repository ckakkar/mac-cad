#!/bin/bash
# Build only the import helper, statically linked, targeting the app's minimum OS.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
command -v pkg-config >/dev/null || { echo 'Install pkgconf (brew install pkgconf) before building the DWG helper.' >&2; exit 1; }
version=0.14
archive=".build/libredwg-$version.tar.gz"
source_dir=".build/libredwg-$version"
checksum=cb6ee0b078c6d9e0f09d66f1feac33ba6342df88ae544e9f9335fab475218351
if [ -x "$source_dir/programs/dwg2dxf" ] && [ -f "$source_dir/.maccad-static-build" ]; then exit 0; fi
mkdir -p .build
if [ ! -f "$archive" ]; then
  if [ -f "third_party/libredwg-$version.tar.gz" ]; then cp "third_party/libredwg-$version.tar.gz" "$archive"
  else curl --fail --location --retry 2 --max-time 300 "https://ftp.gnu.org/gnu/libredwg/libredwg-$version.tar.gz" --output "$archive"; fi
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
test "$actual" = "$checksum" || { echo 'LibreDWG source checksum mismatch; refusing to build.' >&2; exit 1; }
if [ ! -d "$source_dir" ]; then tar -xzf "$archive" -C .build; fi
(
  cd "$source_dir"
  export MACOSX_DEPLOYMENT_TARGET=14.0
  export CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0'
  export LDFLAGS='-arch arm64 -mmacosx-version-min=14.0'
  ./configure --disable-shared --enable-static --disable-bindings --disable-python --disable-docs --disable-json > configure-maccad.log 2>&1
  make -j 4 -C src libredwg.la > build-maccad.log 2>&1 || { tail -60 build-maccad.log; exit 1; }
  make -j 4 -C programs dwg2dxf >> build-maccad.log 2>&1 || { tail -60 build-maccad.log; exit 1; }
  touch .maccad-static-build
)
otool -L "$source_dir/programs/dwg2dxf"
