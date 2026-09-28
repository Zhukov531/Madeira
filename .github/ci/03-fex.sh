#!/bin/bash
# Stage 3: FEX-Emu iOS static libraries (FEX/build-ios).
# Produces the 7 archives the Xcode project links:
#   libFEXCore.a libFEXCore_Base.a libJemallocLibs.a
#   libfmt.a libcephes_128bit.a libxxhash.a libsoftfloat_3e.a
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

ensure_submodule FEX
if [ ! -d FEX/External/range-v3/.git ]; then
    git -C FEX submodule update --init --recursive --depth 100 \
        > FEX/submodules.log 2>&1 || { tail -30 FEX/submodules.log; exit 1; }
fi

# Upstream FEX 89db11f added IOS_RPM_GUARD() to malloc_usable_size in the
# system-allocator branch of AllocatorHooks.cpp, but only defines the macro
# in the ENABLE_FEX_ALLOCATOR branch. iOS builds with the FEX allocator OFF
# (see build/fex-ios/build.sh), and upstream only rebuilds FEXCore targets,
# so its stale libJemallocLibs.a hides this. No rpmalloc there -> no-op.
python3 - <<'PY'
p = "FEX/FEXCore/Source/Utils/AllocatorHooks.cpp"
s = open(p).read()
marker = "size_t malloc_usable_size(void* ptr) {"
fallback = "#ifndef IOS_RPM_GUARD\n#define IOS_RPM_GUARD() ((void)0)\n#endif\n"
if "IOS_RPM_GUARD" in s and fallback not in s and marker in s:
    i = s.rfind(marker)  # the system-allocator branch is the last definition
    s = s[:i] + fallback + s[i:]
    open(p, "w").write(s)
    print("==> [3-] added IOS_RPM_GUARD fallback in", p)
PY

# Upstream Core.cpp reports ARM64EC-only probe buffers (IosFfsBypassLog lives
# in Source/Windows/ARM64EC/Module.cpp, IosCbEntryLog's extern is under
# FEX_IOS_HOST) without the FEX_IOS_HOST guard their declarations have. The
# iOS-native libs are built without FEX_IOS_HOST, so guard the two blocks.
python3 - <<'PY'
p = "FEX/FEXCore/Source/Interface/Core/Core.cpp"
s = open(p).read()
start = "  {\n    static uint64_t FfsLastCount = 0;"
end = "\n\n  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs."
if start in s and end in s and "#ifdef FEX_IOS_HOST\n" + start not in s:
    i = s.index(start); j = s.index(end, i)
    s = s[:i] + "#ifdef FEX_IOS_HOST\n" + s[i:j] + "\n#endif" + s[j:]
    open(p, "w").write(s)
    print("==> [3-] guarded ARM64EC probe reporters in", p)
PY

# Upstream Arm64.cpp's [caspal128] probe calls VirtualQuery (a Win32 API)
# unguarded; the iOS-native build has no windows.h. Keep the region lookup on
# Windows, log the address fields elsewhere.
python3 - <<'PY'
p = "FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
s = open(p).read()
start = "  MEMORY_BASIC_INFORMATION mbi {};\n"
tail = "                    mbi.Protect, type, mbi.State);\n"
alt = ('#else\n'
       '  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={}",\n'
       '                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15);\n'
       '#endif\n')
if start in s and tail in s and "#ifdef _WIN32\n" + start not in s:
    i = s.index(start); j = s.index(tail, i) + len(tail)
    s = s[:i] + "#ifdef _WIN32\n" + s[i:j] + alt + s[j:]
    open(p, "w").write(s)
    print("==> [3-] guarded Win32 VirtualQuery probe in", p)
PY

echo "==> verifying FEX archives"
REQUIRED=(
    FEXCore/Source/libFEXCore.a
    FEXCore/Source/libFEXCore_Base.a
    FEXCore/Source/libJemallocLibs.a
    External/fmt/libfmt.a
    External/cephes/libcephes_128bit.a
    External/xxhash/cmake_unofficial/libxxhash.a
    External/SoftFloat-3e/libsoftfloat_3e.a
)

if [ ! -f FEX/build-ios/"${REQUIRED[0]}" ]; then
    echo "==> [3a] configure FEX for iOS"
    rm -rf FEX/build-ios
    cmake -S FEX -B FEX/build-ios -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DBUILD_TESTING=OFF \
        -DTUNE_CPU=generic -DTUNE_ARCH=generic \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF -DBUILD_BENCHMARKS=OFF \
        -DENABLE_LTO=OFF \
        -DCMAKE_CROSSCOMPILING=ON \
        > FEX/cmake-ios.log 2>&1 \
        || { echo "FEX cmake FAILED"; tail -60 FEX/cmake-ios.log; exit 1; }
    echo "==> [3b] build FEX (static archives only, skipping FEXCore_shared dylib)"
    ninja -C FEX/build-ios -k 0 -j "$NCPUS" "${REQUIRED[@]}" \
        > FEX/build-ios.log 2>&1 \
        || { echo "FEX build FAILED"; tail -80 FEX/build-ios.log; exit 1; }
fi

ok=1
for f in "${REQUIRED[@]}"; do
    p="FEX/build-ios/$f"
    if [ -f "$p" ]; then
        echo "    OK $p ($(du -h "$p" | cut -f1))"
    else
        echo "    MISSING $p"
        ok=0
    fi
done
[ "$ok" = 1 ] || { echo "FEX build incomplete"; exit 1; }
echo "Stage 3 complete."