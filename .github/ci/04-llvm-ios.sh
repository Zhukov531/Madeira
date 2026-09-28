#!/bin/bash
# Stage 4: LLVM 15.0.7 cross-built for iOS-aarch64 (toolchains/llvm-ios-build).
# Two-stage: host llvm-tblgen, then iOS static libs reusing it.
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

if [ -d "$TOOLCHAINS/llvm-ios-build/lib" ] && ls "$TOOLCHAINS/llvm-ios-build/lib/"*.a >/dev/null 2>&1; then
    echo "Stage 4 already built: $(ls "$TOOLCHAINS/llvm-ios-build/lib/"*.a | wc -l | tr -d ' ') libs"
    exit 0
fi

if [ ! -d "$TOOLCHAINS/llvm-project/llvm" ]; then
    mkdir -p "$TOOLCHAINS"
    echo "==> [4a] clone llvm-project@llvmorg-15.0.7"
    git clone --depth 1 --branch llvmorg-15.0.7 \
        https://github.com/llvm/llvm-project.git "$TOOLCHAINS/llvm-project"
fi

LLVM_SRC="$TOOLCHAINS/llvm-project/llvm"
HOST_BUILD="$TOOLCHAINS/llvm-host-build"
IOS_BUILD="$TOOLCHAINS/llvm-ios-build"

# One-line patch so Apple ld gets -dead_strip instead of --gc-sections.
if grep -q 'MATCHES "Darwin"' "$LLVM_SRC/cmake/modules/AddLLVM.cmake" \
    && ! grep -q 'MATCHES "Darwin|iOS"' "$LLVM_SRC/cmake/modules/AddLLVM.cmake"; then
    sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' "$LLVM_SRC/cmake/modules/AddLLVM.cmake"
    echo "    patched AddLLVM.cmake for iOS"
fi

if [ ! -x "$HOST_BUILD/bin/llvm-tblgen" ]; then
    echo "==> [4b] host llvm-tblgen"
    rm -rf "$HOST_BUILD"
    mkdir -p "$HOST_BUILD" "$IOS_BUILD"
    cmake -S "$LLVM_SRC" -B "$HOST_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=AArch64 \
        -DLLVM_BUILD_TOOLS=ON -DLLVM_BUILD_UTILS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_PLUGINS=OFF \
        > "$HOST_BUILD/configure.log" 2>&1 \
        || { echo "host cmake FAILED"; tail -60 "$HOST_BUILD/configure.log"; exit 1; }
    cmake --build "$HOST_BUILD" --target llvm-tblgen -j "$NCPUS" \
        > "$HOST_BUILD/build.log" 2>&1 \
        || { echo "host tblgen build FAILED"; tail -60 "$HOST_BUILD/build.log"; exit 1; }
fi
echo "    host llvm-tblgen OK: $HOST_BUILD/bin/llvm-tblgen"

echo "==> [4c] iOS static libs"
rm -rf "$IOS_BUILD"
mkdir -p "$IOS_BUILD"
cmake -S "$LLVM_SRC" -B "$IOS_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DLLVM_TABLEGEN="$HOST_BUILD/bin/llvm-tblgen" \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DCMAKE_CROSSCOMPILING=ON \
    -DLLVM_BUILD_UTILS=Off -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_TESTS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
    -DLLVM_INCLUDE_DOCS=Off -DLLVM_INCLUDE_BENCHMARKS=Off \
    -DLLVM_INCLUDE_UTILS=Off -DLLVM_INCLUDE_GO_TESTS=Off \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_PLUGINS=OFF \
    > "$IOS_BUILD/configure.log" 2>&1 \
    || { echo "iOS cmake FAILED"; tail -80 "$IOS_BUILD/configure.log"; exit 1; }
static_libs=$(ninja -C "$IOS_BUILD" -t targets all 2>/dev/null \
    | awk -F: '/^lib\/[^:]*\.a:/ {print $1}' | sort -u)
[ -n "$static_libs" ] || { echo "no LLVM static lib targets"; exit 1; }
ninja -C "$IOS_BUILD" $static_libs -j "$NCPUS" > "$IOS_BUILD/build.log" 2>&1 \
    || { echo "iOS LLVM build FAILED"; tail -80 "$IOS_BUILD/build.log"; exit 1; }

nlibs=$(ls "$IOS_BUILD/lib/"*.a | wc -l | tr -d ' ')
[ "$nlibs" -gt 0 ] || { echo "No LLVM libs produced"; exit 1; }
echo "Stage 4 complete: $nlibs static libs in $IOS_BUILD/lib"
du -sh "$IOS_BUILD/lib"

# Stage the source headers into the build tree so $IOS_BUILD/include is
# a complete LLVM include tree (cmake-generated + source). Only the
# build tree is cached across jobs; the llvm-project clone is not, so
# down-stream C++ (DXMT airconv) cannot use $LLVM_SRC/include.
echo "==> [4d] stage LLVM source headers"
cp -a "$LLVM_SRC/include/llvm" "$LLVM_SRC/include/llvm-c" "$IOS_BUILD/include/"
echo "    staged: $(du -sh "$IOS_BUILD/include" | cut -f1)"