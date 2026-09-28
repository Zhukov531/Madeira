#!/bin/bash
# Stage 2: Wine host build tree (wine/build-macos).
# Produces include/config.h, generated headers, host tools, and the
# widl-generated dwrite headers; wires wine/build-arm64ec/include ->
# build-macos/include (the ntdll-unix build references that path).
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

ensure_submodule wine

# Upstream loader.c (wine pin 723d1bf5) #includes arm64ec_x64_export_iat.c,
# which the Madeira author left untracked ("unbuilt review candidate").
# makedep scans every #include, so configure dies creating the Makefile
# without it. CI never compiles the ARM64EC ntdll (the shipped ntdll.dll in
# app/Madeira/arm64ec-windows is prebuilt), so a stub that keeps the
# pre-patch behaviour (never classify a slot as an x64 export) is enough.
IAT_STUB=wine/dlls/ntdll/arm64ec_x64_export_iat.c
if [ ! -f "$IAT_STUB" ]; then
    echo "==> [2-] stubbing missing $IAT_STUB (untracked upstream)"
    cat > "$IAT_STUB" <<'STUB'
/* CI stub: upstream file is untracked. Returns FALSE, i.e. the loader keeps
 * its behaviour from before the x64-export IAT classifier was added. */
static BOOL arm64ec_iat_slot_is_x64_export( HMODULE module, ULONG_PTR image_size,
                                            ULONG_PTR slot_rva, ULONG_PTR exports_rva,
                                            ULONG_PTR exports_size, ULONG_PTR code_map,
                                            ULONG_PTR code_map_count )
{
    return FALSE;
}
STUB
fi

# Upstream sync.c includes build/madeira_cfg.h ahead of config.h; makedep
# rejects that ("config.h must be included before other headers"). The iOS
# compile force-includes config.h (-include) so it is first there anyway;
# swapping the two lines in the file changes nothing that gets built.
python3 - <<'PY'
p = "wine/dlls/ntdll/unix/sync.c"
lines = open(p).read().split("\n")
cfg = next((i for i, l in enumerate(lines) if "madeira_cfg.h" in l), None)
conf = next((i for i, l in enumerate(lines) if l.strip() == '#include "config.h"'), None)
if cfg is not None and conf is not None and cfg < conf:
    lines.insert(cfg, lines.pop(conf))
    open(p, "w").write("\n".join(lines))
    print("==> [2-] moved config.h ahead of madeira_cfg.h in", p)
PY

if [ ! -f wine/build-macos/include/config.h ]; then
    echo "==> [2a] configure wine/build-macos"
    mkdir -p wine/build-macos
    cd wine/build-macos
    export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig"
    ../configure \
        --without-x --without-freetype --without-opengl --without-vulkan \
        --without-alsa --without-cups --without-osmesa --without-dbus \
        --without-sdl --without-gstreamer --without-pulse \
        --disable-tests --disable-win16 > configure.log 2>&1 \
        || { echo "configure FAILED"; tail -40 configure.log; exit 1; }
    echo "==> [2b] build wine host tools (widl/winebuild/wrc)"
    make -j"$NCPUS" tools/widl/widl tools/winebuild/winebuild tools/wrc/wrc \
        > tools-make.log 2>&1 \
        || { echo "host tools build FAILED"; tail -60 tools-make.log; exit 1; }
else
    echo "==> wine/build-macos already configured"
fi

cd "$REPO"

echo "==> [2c] generate widl headers via wine make"
# DirectWrite/Direct3D/DXGI headers the widl outputs and win32u sources
# pull in. Generate them with wine's own build system so the full widl
# dependency closure (oaidl/ocidl/objidl/urlmon/msxml/...) resolves in
# the right order. Manual widl invocations cannot do this: e.g.
# d3dcommon.idl -> ocidl.idl -> urlmon.idl -> msxml.idl needs static
# -I paths and pre-generated siblings. ole2.h/unknwn.h stay shimmed
# (static headers; make leaves them alone).
cd wine/build-macos/include
# NOTE: list the FULL transitive widl closure explicitly. Wine's make
# builds each requested header but does not chain generated-header
# deps (dxgi.h was emitted while oaidl.h was still missing), so every
# header in the import graph must be named. Closure computed from
# ^import "...idl" plus cpp_quote("#include ...") edges over
# dxgi/d3d10(_1/shader/effect/sdklayers)/d3d11/d3d12/d3dcommon/dwrite.
make -j"$NCPUS" \
    dxgiformat.h dcommon.h dxgitype.h dxgicommon.h d3dcommon.h \
    wtypesbase.h wtypes.h unknwn.h objidl.h oleidl.h oaidl.h ocidl.h \
    servprov.h urlmon.h msxml.h \
    dxgi.h d3d10.h d3d10_1.h d3d10shader.h d3d10effect.h d3d10sdklayers.h \
    d3d11.h d3d11sdklayers.h d3d12.h d3d12sdklayers.h \
    dwrite.h dwrite_1.h dwrite_2.h dwrite_3.h \
    objidlbase.h propidl.h d2d1.h \
    exdisp.h docobj.h shldisp.h shtypes.h shobjidl.h shobjidl_core.h comcat.h \
    propsys.h structuredquerycondition.h objectarray.h \
    > include-headers.log 2>&1 \
    || { echo "widl header generation FAILED"; tail -40 include-headers.log; exit 1; }
echo "    headers: $(ls dxgi.h d3d11.h dwrite.h oaidl.h 2>/dev/null | tr '\n' ' ')"
cd "$REPO"

echo "==> [2d] build-arm64ec/include -> build-macos/include"
mkdir -p wine/build-arm64ec
ln -sfn ../build-macos/include wine/build-arm64ec/include

echo "Stage 2 complete: $(ls wine/build-macos/include/config.h wine/build-macos/include/dwrite.h wine/build-macos/include/dwrite_3.h)"