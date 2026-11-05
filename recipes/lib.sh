# Shared helpers for the build recipes. Sourced, not run.
set -euo pipefail

# Keeps foreign toolchains out of the build; Homebrew build tools on the CI
# runner are added explicitly by the workflow through BUILD_TOOLS_PATH.
export PATH="${BUILD_TOOLS_PATH:+$BUILD_TOOLS_PATH:}/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET=13.0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/sources.lock"

die() { echo "error: $*" >&2; exit 1; }

# fetch URL DIR: downloads into DIR and checks the SHA-256 pinned in
# sources.lock. An unpinned file is allowed only with ALLOW_UNPINNED=1 (first
# build of a new version); the publish job refuses such builds.
fetch() {
    local url="$1" dir="$2" name="${1##*/}"
    mkdir -p "$dir"
    [ -f "$dir/$name" ] || curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors --proto '=https' -o "$dir/$name" "$url"
    local actual expected
    actual="$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)"
    expected="$(awk -v n="$name" '$1 == n { print $2 }' "$LOCK" 2>/dev/null || true)"
    if [ -z "$expected" ]; then
        [ -z "${UNPINNED_LOG:-}" ] || mkdir -p "$(dirname "$UNPINNED_LOG")"
        echo "UNPINNED $name $actual" | tee -a "${UNPINNED_LOG:-/dev/null}" >&2
        [ "${ALLOW_UNPINNED:-0}" = 1 ] || die "$name is not pinned in sources.lock"
    elif [ "$actual" != "$expected" ]; then
        die "$name: sha256 $actual, sources.lock pins $expected"
    fi
}

# check_binary FILE: arm64 only, no dylibs outside the OS.
check_binary() {
    local bin="$1"
    file "$bin"
    lipo -archs "$bin" | grep -qx arm64 || die "$bin is not arm64-only"
    local foreign
    foreign="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/Library/' || true)"
    [ -z "$foreign" ] || die "$bin links outside the OS: $foreign"
    # Ad-hoc signature until the Developer ID pipeline exists (ADR 0009).
    codesign -s - -f "$bin"
    codesign -v "$bin"
}
