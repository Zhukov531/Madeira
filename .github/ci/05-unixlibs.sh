#!/bin/bash
# Stage 5: native iOS unix-side static libraries that are NOT committed:
#   app/Madeira/libntdll_unix.a      (wine ntdll + crypto/net/dwrite unixlibs)
#   app/Madeira/libwin32u_unix.a     (wine win32u + merged freetype)
#   app/Madeira/libwineserver.a      (wineserver-as-thread, symbol-renamed)
#   app/Madeira/libdxmt_combined.a   (DXMT unix side + airconv + LLVM)
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

ensure_submodule wine
ensure_submodule research/dxmt

# Sub-builds write compiler diagnostics to obj/*.err and only print file
# names. On failure, dump the non-empty ones so the annotation shows them.
run_build() {
    local dir=$1; shift
    local rc=0
    bash "$dir/build.sh" "$@" || rc=$?
    for f in "$dir"/obj/*.err "$dir"/obj/err-*.txt; do
        [ -s "$f" ] || continue
        grep -q "error:" "$f" || continue
        echo "--- compile errors in $f"
        grep "error:" "$f" | head -n 8
    done
    if [ "$rc" -ne 0 ]; then echo "!! $dir failed (rc=$rc), continuing to surface other errors"; STAGE_FAIL=1; fi
}
STAGE_FAIL=0

# server_ios.c's [xp] perf line reads rusage_info_v6.ri_page_wait_time_mach,
# which the SDKs on GitHub's runners (Xcode 26) do not declare. It only feeds
# the "pgw=" log figure, so report 0 there when the SDK lacks the field.
python3 - <<'PY'
p = "build/ntdll-unix/server_ios.c"
s = open(p).read()
old = "XP_MS( ru.ri_page_wait_time_mach - pru.ri_page_wait_time_mach )"
if old in s:
    s = s.replace(old, "XP_MS( 0 ) /* CI: ri_page_wait_time_mach not in this SDK */")
    open(p, "w").write(s)
    print("==> [5-] dropped ri_page_wait_time_mach from", p)
PY

# build/dxmt-ios guards the optional madeira-d3d12 block with
#   if [[ -f deps.sh ]] && source deps.sh 2>/dev/null; then
# but deps.sh calls `exit 1` when Apple's converter package is absent, and an
# exit inside a sourced file ends the whole build script (silently: stderr is
# discarded). Only source it when the package is actually there.
python3 - <<'PY'
p = "build/dxmt-ios/build.sh"
s = open(p).read()
old = 'if [[ -f "$BUILD_DIR/../madeira-d3d12/deps.sh" ]] && \\\n'
new = ('if [[ -f "$BUILD_DIR/../madeira-d3d12/deps.sh" ]] && \\\n'
       '   [[ -f "$REPO_ROOT/research/GPTK/Metal Shader Converter 4.0 beta 2.pkg" ]] && \\\n')
if old in s and new not in s:
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
    print("==> [5-] made the madeira-d3d12 block optional for real in", p)
PY

echo "==> [5a] ntdll-unix"
run_build build/ntdll-unix
file app/Madeira/libntdll_unix.a || true

echo "==> [5b] win32u-unix"
run_build build/win32u-unix
file app/Madeira/libwin32u_unix.a || true

echo "==> [5c] wineserver (build base archive from wine/server, then patch)"
bash "$GITHUB_ACTION_PATH/build-wineserver-base.sh" || { echo "!! wineserver base failed"; STAGE_FAIL=1; }
run_build build/wineserver all
file app/Madeira/libwineserver.a || true

echo "==> [5d] dxmt-ios unix side + LLVM combine"
# DXMT's DirectX headers are a nested submodule (include/native/directx)
# that the top-level submodule init does not fetch.
if [ ! -f research/dxmt/include/native/directx/include/d3d11.h ] && [ ! -f research/dxmt/include/native/directx/d3d11.h ]; then
    git -C research/dxmt submodule update --init --depth 100 include/native/directx
fi
# airconv includes air_{msad,samplepos,tessellation}.h, which DXMT's meson
# build generates (metal -> .air -> xxd -i). build/dxmt-ios expects them in
# shader-headers/ but nothing creates them outside the author's tree.
SH="build/dxmt-ios/shader-headers"
mkdir -p "$SH"
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "==> [5d-] downloading Metal toolchain"
    xcodebuild -downloadComponent MetalToolchain
fi
for m in research/dxmt/src/airconv/shaders/*.metal; do
    n=$(basename "$m" .metal)
    [ -f "$SH/$n.h" ] && continue
    xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 -o "$SH/$n.air" -c "$m"
    python3 - "$SH/$n.air" "$n" "$SH/$n.h" <<'PY'
import sys
data = open(sys.argv[1], "rb").read(); name = sys.argv[2]
rows = [", ".join("0x%02x" % b for b in data[i:i+12]) for i in range(0, len(data), 12)]
with open(sys.argv[3], "w") as f:
    f.write("unsigned char %s[] = {\n  %s\n};\nunsigned int %s_len = %d;\n" % (name, ",\n  ".join(rows), name, len(data)))
PY
    echo "    generated $SH/$n.h ($(wc -c < "$SH/$n.air" | tr -d ' ') bytes of AIR)"
done
run_build build/dxmt-ios
# Without Apple's Metal Shader Converter package the madeira-d3d12 objects are
# skipped, but winemetal (unix call 127) and ContentView.swift still reference
# them. Link a stand-in that reports the converter as unavailable.
if [ ! -f build/dxmt-ios/obj/madeira_ir_unix.o ]; then
    echo "==> [5d-] madeira-d3d12 skipped upstream; linking CI stub"
    xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
        -I research/madeira-d3d12/src \
        -c "$GITHUB_ACTION_PATH/stubs/madeira_d3d12_stub.c" \
        -o build/dxmt-ios/obj/madeira_d3d12_stub.o
fi
[ "$STAGE_FAIL" -eq 0 ] || { echo "one or more sub-builds failed (see above)"; exit 1; }
cd build/dxmt-ios
rm -f libdxmt_combined.a
xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a \
    obj/*.o ../../toolchains/llvm-ios-build/lib/*.a
cp libdxmt_combined.a ../../app/Madeira/
cd "$REPO"
file app/Madeira/libdxmt_combined.a

echo "Stage 5 complete."
ls -la app/Madeira/libntdll_unix.a app/Madeira/libwin32u_unix.a \
       app/Madeira/libwineserver.a app/Madeira/libdxmt_combined.a