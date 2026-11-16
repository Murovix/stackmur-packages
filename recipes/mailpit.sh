#!/bin/bash
# Repacks the official Mailpit release (MIT, a single Go binary; ADR 0009)
# for macOS arm64 into STAGE/. The archive is pinned in sources.lock; the
# binary must be arm64-only, link only OS libraries, target macOS 13 or older,
# and is re-signed ad hoc like every other binary here.
# Usage: recipes/mailpit.sh STAGE_DIR
source "$(dirname "$0")/lib.sh"

VERSION=1.33.1

STAGE="$(mkdir -p "$1" && cd "$1" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/mailpit"
mkdir -p "$WORK/src"

fetch "https://github.com/axllent/mailpit/releases/download/v$VERSION/mailpit-darwin-arm64.tar.gz" \
    "$WORK/src" "mailpit-$VERSION-darwin-arm64.tar.gz"
rm -rf "$WORK/x" && mkdir -p "$WORK/x"
tar -xzf "$WORK/src/mailpit-$VERSION-darwin-arm64.tar.gz" -C "$WORK/x"
ls -la "$WORK/x"

mkdir -p "$STAGE/bin" "$STAGE/share/licenses"
cp "$WORK/x/mailpit" "$STAGE/bin/mailpit"
chmod 0755 "$STAGE/bin/mailpit"
if [ -f "$WORK/x/LICENSE" ]; then
    cp "$WORK/x/LICENSE" "$STAGE/share/licenses/mailpit.txt"
else
    curl -fsSL --retry 3 --proto '=https' -o "$STAGE/share/licenses/mailpit.txt" \
        "https://raw.githubusercontent.com/axllent/mailpit/v$VERSION/LICENSE"
fi
grep -q 'MIT License' "$STAGE/share/licenses/mailpit.txt" || die "Mailpit licence is not MIT"

# Go records the minimum macOS in LC_BUILD_VERSION; Stackmur supports 13+.
minos="$(otool -l "$STAGE/bin/mailpit" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "minos" {print $2; exit}')"
echo "mailpit minos $minos"
[ -n "$minos" ] || die "mailpit has no LC_BUILD_VERSION"
[ "$(printf '%s\n13.0\n' "$minos" | sort -V | tail -n1)" = 13.0 ] || die "mailpit needs macOS $minos"
check_binary "$STAGE/bin/mailpit"
"$STAGE/bin/mailpit" version --no-release-check
"$STAGE/bin/mailpit" version --no-release-check | grep -q "v$VERSION" || die "mailpit is not $VERSION"
echo "$VERSION" > "$STAGE.version"
