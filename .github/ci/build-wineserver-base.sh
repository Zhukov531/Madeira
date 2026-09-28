#!/bin/bash
# Create the base libwineserver.a from scratch by compiling every
# wine/server/*.c for iOS. build/wineserver/build.sh then replaces a
# subset of objects and renames colliding symbols.
set -euo pipefail
source "$GITHUB_ACTION_PATH/common.sh"

cd "$REPO"

[ -f wine/build-macos/include/config.h ] || { echo "wine/build-macos missing"; exit 1; }

WSDIR="$REPO/build/wineserver"
BASE_OBJ="$WSDIR/obj/base"
APP_LIB="$REPO/app/Madeira/libwineserver.a"

if [ -f "$APP_LIB" ]; then
    echo "base archive already present ($(du -h "$APP_LIB" | cut -f1))"
    exit 0
fi

mkdir -p "$BASE_OBJ"
rm -f "$BASE_OBJ"/*.o "$BASE_OBJ"/*.err

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O1
    -I"$REPO/wine/include" -I"$REPO/wine/include/wine"
    -I"$REPO/wine/build-macos/include"
    -I"$WSDIR" -I"$REPO/wine/server"
    -I"$REPO/build/ntdll-unix/shims"
    -I"$REPO/build/madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$WSDIR/config_ios.h"
    -include stdarg.h
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration -Wno-unused-function
    -Wno-address-of-packed-member
)

completed=0
for src in "$REPO/wine/server/"*.c; do
    n="$(basename "$src" .c)"
    if ! xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" \
        -o "$BASE_OBJ/$n.o" 2> "$BASE_OBJ/$n.err"; then
        echo "FAILED $n"
        tail -15 "$BASE_OBJ/$n.err"
        exit 1
    fi
    completed=$((completed + 1))
done

nobj=$(ls "$BASE_OBJ"/*.o | wc -l | tr -d ' ')
ar rcs "$WSDIR/obj/libbase.a" "$BASE_OBJ"/*.o
mkdir -p "$REPO/app/Madeira"
cp "$WSDIR/obj/libbase.a" "$APP_LIB"
echo "base archive: $completed sources, $nobj objects -> $(du -h "$APP_LIB" | cut -f1)"