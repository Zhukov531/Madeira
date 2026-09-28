#!/bin/bash
# Stage 6: assemble the app, package Madeira.ipa, publish a release.
# Uses committed artifacts + cache-restored FEX libs + stage-5 unixlibs.
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

echo "==> [6a] MSVC runtime DLLs"
VCRT="$REPO/app/Madeira/x86_64-vcruntime"
if [ ! -f "$VCRT/vcruntime140.dll" ]; then
    brew install sevenzip >/dev/null 2>&1 || true
if [ ! -f "$VCRT/vcruntime140.dll" ]; then
    brew install sevenzip >/dev/null 2>&1 || true
    VC_REDIST_URL="${VC_REDIST_URL:-https://aka.ms/vs/17/release/vc_redist.x64.exe}"
    curl -fL "$VC_REDIST_URL" -o /tmp/vc_redist.x64.exe
    rm -rf /tmp/vcredist /tmp/vcpayload "$VCRT" && mkdir -p /tmp/vcredist /tmp/vcpayload "$VCRT"
    # The MSI payload rides as an attached CAB overlay that 7zz does not
    # reach (it only dumps the small UX streams). Carve embedded CABs by
    # MSCF magic + cbCabinet size, then unpack cab -> msi -> dlls.
    python3 - /tmp/vc_redist.x64.exe /tmp <<'EOF'
import struct, sys
exe, outdir = sys.argv[1], sys.argv[2]
d = open(exe, 'rb').read()
n = 0
i = d.find(b'MSCF')
while i != -1:
    if i + 36 <= len(d):
        sig, r1, cb, r2, coff, r3, vmin, vmaj, cfold, cfil, flags, setid, icab = \
            struct.unpack('<4sIIIIIBBHHHHH', d[i:i+36])
        if 1024 < cb <= len(d) - i and cfil < 100000:
            open(f'{outdir}/payload{n}.cab', 'wb').write(d[i:i+cb])
            print(f'carved payload{n}.cab at {i} size {cb} files {cfil}')
            n += 1
    i = d.find(b'MSCF', i + 1)
print(f'{n} cabs carved')
EOF
    for cab in /tmp/payload*.cab; do
        [ -f "$cab" ] || continue
        7zz x -y "$cab" -o/tmp/vcpayload > /dev/null 2>&1 || true
    done
    # Unpack CAB payloads (and any nested cabs) one more level. Note:
    # 7zz dumps MSI *database streams* instead of files, so MSIs need
    # msiextract (msitools) below.
    find /tmp/vcpayload -type f | while read -r a; do
        7zz x -y "$a" -o"$VCRT" > /dev/null 2>&1 || true
    done
    brew install msitools >/dev/null 2>&1 || true
    # The 12 CRT DLLs ride as *_amd64 entries in an embedded CAB (e.g.
    # concrt140.dll_amd64), not inside the MSIs. Extract every CAB
    # payload and rename into place.
    find /tmp/vcpayload -type f | while read -r a; do
        if file -b "$a" 2>/dev/null | grep -q "Microsoft Cabinet archive"; then
            7zz x -y "$a" -o"$VCRT" > /dev/null 2>&1 || true
        fi
    done
    find /tmp/vcpayload /tmp/vcredist -type f | while read -r a; do
        msiextract -C "$VCRT" "$a" > /dev/null 2>&1 || true
    done
    # Classic-layout fallback (.rsrc CABINET) for older exes.
    7zz x -y /tmp/vc_redist.x64.exe -o/tmp/vcredist > /dev/null 2>&1 || true
    for cab in /tmp/vcredist/.rsrc/1033/CABINET/*.cab; do
        [ -f "$cab" ] && 7zz x -y "$cab" -o"$VCRT" > /dev/null
    done
    # Flatten in case DLLs land in subdirs, and drop the _amd64 suffix
    # used for CAB entries.
    find "$VCRT" -mindepth 2 -name "*.dll" -exec mv {} "$VCRT/" \; 2>/dev/null || true
    for f in "$VCRT"/*_amd64; do
        [ -f "$f" ] || continue
        mv "$f" "${f%_amd64}"
    done
    [ -f "$VCRT/vcruntime140.dll" ] || { echo "vcruntime extraction yielded no DLLs"; ls "$VCRT" | head; exit 1; }
fi
fi
echo "    vcruntime DLLs: $(ls "$VCRT"/*.dll 2>/dev/null | wc -l | tr -d ' ') of 12"
REQUIRED_DLLS="concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll
               msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll
               vcamp140.dll vccorlib140.dll vcomp140.dll vcruntime140.dll
               vcruntime140_1.dll vcruntime140_threads.dll"
missing=""
for d in $REQUIRED_DLLS; do
    [ -f "$VCRT/$d" ] || missing="$missing $d"
done
[ -z "$missing" ] || { echo "missing vcruntime DLLs:$missing"; exit 1; }
echo "    all 12 MSVC runtime DLLs present (unsigned .ipa -> resigning needed on device)"
# The extraction also leaves MSI database tables and MFC DLLs behind (~35 MB).
# Ship exactly the twelve files tools/fetch-vcruntime.md lists.
for f in "$VCRT"/* "$VCRT"/.[!.]*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case " $(echo $REQUIRED_DLLS) " in *" $b "*) ;; *) rm -rf "$f";; esac
done
echo "    pruned vcruntime dir to $(ls "$VCRT" | wc -l | tr -d ' ') files"

echo "==> [6b] verify linked libraries are in place"
REQUIRED_LIBS=(
    FEX/build-ios/FEXCore/Source/libFEXCore.a
    FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
    FEX/build-ios/FEXCore/Source/libJemallocLibs.a
    FEX/build-ios/External/fmt/libfmt.a
    FEX/build-ios/External/cephes/libcephes_128bit.a
    FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a
    FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a
    app/Madeira/libntdll_unix.a
    app/Madeira/libwin32u_unix.a
    app/Madeira/libwineserver.a
    app/Madeira/libdxmt_combined.a
    app/Madeira/libgnutls.a
    app/Madeira/libhogweed.a
    app/Madeira/libnettle.a
    app/Madeira/libgmp.a
)
for lib in "${REQUIRED_LIBS[@]}"; do
    if [ -f "$lib" ]; then echo "    OK $lib"; else echo "    MISSING $lib"; exit 1; fi
done
# Xcode links FEX libs by path under FEX/build-ios; the FEXCore_Source libs
# live there after cache restore.
echo "==> [6b2] stage licence copies (Xcode build phase checks these)"
bash build/stage-licenses.sh

echo "==> [6c] xcodebuild Madeira.app"
# FEXBridge.mm includes FEXCore/fmt/ranges headers from the FEX source
# tree, but the ipa job checks out with submodules:false and only caches
# FEX/build-ios. Init sources like the fex job does (same command).
ensure_submodule FEX
if [ ! -d FEX/External/range-v3/.git ]; then
    git -C FEX submodule update --init --recursive --depth 100 \
        > FEX/submodules.log 2>&1 || { tail -30 FEX/submodules.log; exit 1; }
fi
# ContentView uses glassEffect (iOS 26 SDK). The default Xcode 16 only
# has the iOS 18 SDK, where the symbol doesn't exist at all (even the
# #available guards can't help). Select the newest installed Xcode 26+.
ls -d /Applications/Xcode*.app 2>/dev/null || true
XC26=$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | sort -V | tail -1)
if [ -n "$XC26" ]; then
    sudo xcode-select -s "$XC26/Contents/Developer"
    echo "    selected $XC26"
fi
SDKVER=$(xcodebuild -showsdks 2>/dev/null | awk '/iphoneos/{print $NF}' | head -1)
echo "    iphoneos SDK: $SDKVER"
xcodebuild -project app/Madeira.xcodeproj -scheme Madeira \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath build/derived \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build > build/xcodebuild.log 2>&1 \
    || { echo "xcodebuild FAILED"; grep -E "error:|fatal error|Assertion|PLEASE submit|Stack dump" build/xcodebuild.log | sort -u | head -30; exit 1; }

APP_DIR="build/derived/Build/Products/Debug-iphoneos"
APP="$APP_DIR/Madeira.app"
[ -d "$APP" ] || { echo "Madeira.app not produced"; exit 1; }
echo "    Madeira.app: $(du -sh "$APP" | cut -f1)"

echo "==> [6d] package Madeira.ipa"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/Madeira.app
cd build/ipa
zip -qry -9 ../../Madeira.ipa Payload
cd "$REPO"
echo "    Madeira.ipa: $(du -h Madeira.ipa | cut -f1)"

# Build is uploaded as a private workflow artifact (see build-ipa.yml), no public release.
echo "Stage 6 complete."