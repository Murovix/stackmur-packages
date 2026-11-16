#!/bin/bash
# Build tools for the owner's Mac runner, in a private directory instead of
# Homebrew (the owner's Homebrew is never touched): CMake and Ninja (official
# macOS releases) and Bison (GNU source; macOS ships 2.3, MySQL needs 3).
# Prints the directory to put on BUILD_TOOLS_PATH. Removing DIR removes them.
# Usage: tools/build-tools.sh DIR
source "$(dirname "$0")/../recipes/lib.sh"

CMAKE=4.5.0
NINJA=1.13.2
BISON=3.8.2

DIR="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC="$DIR/src"
BIN="$DIR/bin"
mkdir -p "$SRC" "$BIN"

if [ "$("$BIN/cmake" --version 2>/dev/null | head -1)" != "cmake version $CMAKE" ]; then
    fetch "https://github.com/Kitware/CMake/releases/download/v$CMAKE/cmake-$CMAKE-macos-universal.tar.gz" "$SRC"
    rm -rf "$DIR/cmake" && mkdir -p "$DIR/cmake"
    tar -xzf "$SRC/cmake-$CMAKE-macos-universal.tar.gz" -C "$DIR/cmake" --strip-components 1
    for t in cmake ctest cpack; do ln -sf "$DIR/cmake/CMake.app/Contents/bin/$t" "$BIN/$t"; done
fi

if [ "$("$BIN/ninja" --version 2>/dev/null)" != "$NINJA" ]; then
    fetch "https://github.com/ninja-build/ninja/releases/download/v$NINJA/ninja-mac.zip" "$SRC" "ninja-$NINJA-mac.zip"
    rm -f "$BIN/ninja"
    unzip -q -o "$SRC/ninja-$NINJA-mac.zip" -d "$BIN"
    chmod 0755 "$BIN/ninja"
fi

if ! "$BIN/bison" --version 2>/dev/null | head -1 | grep -q " $BISON\$"; then
    fetch "https://ftpmirror.gnu.org/gnu/bison/bison-$BISON.tar.xz" "$SRC"
    rm -rf "$SRC/bison-$BISON"
    tar -xJf "$SRC/bison-$BISON.tar.xz" -C "$SRC"
    (cd "$SRC/bison-$BISON" \
        && ./configure --prefix="$DIR/bison" --disable-nls >/dev/null \
        && make -j"$(sysctl -n hw.ncpu)" >/dev/null \
        && make install >/dev/null)
    ln -sf "$DIR/bison/bin/bison" "$BIN/bison"
fi

"$BIN/cmake" --version | head -1 >&2
echo "ninja $("$BIN/ninja" --version)" >&2
"$BIN/bison" --version | head -1 >&2
echo "$BIN"
