#!/bin/bash
# Builds Valkey (BSD-3-Clause; a Redis-compatible cache, ADR 0009) from the
# source of a release tag into STAGE/. Only vendored dependencies (Lua,
# hiredis, linenoise); no TLS (loopback only) and no redis-* symlinks, so a
# Homebrew or other Redis on PATH is never shadowed.
# Usage: recipes/valkey.sh STAGE_DIR
source "$(dirname "$0")/lib.sh"

VERSION=9.1.3

STAGE="$(mkdir -p "$1" && cd "$1" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/valkey"
mkdir -p "$WORK/src"

# The hash in sources.lock is the one valkey-io/valkey-hashes publishes.
fetch "https://github.com/valkey-io/valkey/archive/refs/tags/$VERSION.tar.gz" "$WORK/src" "valkey-$VERSION.tar.gz"
rm -rf "$WORK/src/valkey-$VERSION"
tar -xzf "$WORK/src/valkey-$VERSION.tar.gz" -C "$WORK/src"

cd "$WORK/src/valkey-$VERSION"
MAKEFLAGS_VALKEY=(BUILD_TLS=no USE_REDIS_SYMLINKS=no MALLOC=libc)
make -j"$(sysctl -n hw.ncpu)" "${MAKEFLAGS_VALKEY[@]}"
make install "${MAKEFLAGS_VALKEY[@]}" PREFIX="$STAGE"

mkdir -p "$STAGE/share/licenses"
cp COPYING "$STAGE/share/licenses/valkey.txt"
for b in valkey-server valkey-cli valkey-benchmark; do
    check_binary "$STAGE/bin/$b"
done
# valkey-check-aof, -check-rdb and -sentinel are valkey-server under another
# name; make install creates them as symlinks.
ls -la "$STAGE/bin"
"$STAGE/bin/valkey-server" --version
"$STAGE/bin/valkey-server" --version | grep -q "v=$VERSION " || die "valkey-server is not $VERSION"
echo "$VERSION" > "$STAGE.version"
