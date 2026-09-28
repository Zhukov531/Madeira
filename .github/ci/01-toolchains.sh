#!/bin/bash
# Stage 1: base cross toolchains.
#   - llvm-mingw (macOS universal, aarch64+x86_64 windows PE targets)
#   - GnuTLS stack (gmp/nettle/gnutls -> toolchains/gnutls-ios)  [build/gnutls-ios/build.sh]
#   - freetype source + iOS static build                          [build/freetype-ios/build.sh]
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

echo "==> [1] llvm-mingw"
if [ ! -d "$TOOLCHAINS/llvm-mingw-20260421-ucrt-macos-universal/bin" ]; then
    mkdir -p "$TOOLCHAINS"
    curl -fL https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz \
        | tar -xJ -C "$TOOLCHAINS"
fi
echo "    OK: $(ls "$TOOLCHAINS"/llvm-mingw-*/bin/aarch64-w64-mingw32-clang | head -1)"

echo "==> [2] gnutls-ios"
bash build/gnutls-ios/build.sh

echo "==> [3] freetype"
if [ ! -d research/freetype/.git ]; then
    git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
fi
bash build/freetype-ios/build.sh

echo "Stage 1 complete."
ls -la "$TOOLCHAINS/gnutls-ios/lib/"*.a build/freetype-ios/build/libfreetype.a