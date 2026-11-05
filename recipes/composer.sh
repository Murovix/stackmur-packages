#!/bin/bash
# Fetches the latest stable Composer 2 phar into STAGE/ and verifies it
# against the checksum getcomposer.org publishes next to it.
# Usage: recipes/composer.sh STAGE_DIR
source "$(dirname "$0")/lib.sh"

STAGE="$(mkdir -p "$1" && cd "$1" && pwd)"
VERSION="${COMPOSER_VERSION:-$(curl -fsSL --proto '=https' https://getcomposer.org/versions \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["stable"][0]["version"])')}"
[[ "$VERSION" =~ ^2\.[0-9]+\.[0-9]+$ ]] || die "unexpected Composer version $VERSION"

mkdir -p "$STAGE/bin" "$STAGE/share/licenses"
base="https://getcomposer.org/download/$VERSION"
curl -fsSL --retry 3 --proto '=https' -o "$STAGE/bin/composer.phar" "$base/composer.phar"
published="$(curl -fsSL --retry 3 --proto '=https' "$base/composer.phar.sha256sum" | cut -d' ' -f1)"
actual="$(shasum -a 256 "$STAGE/bin/composer.phar" | cut -d' ' -f1)"
[ "$actual" = "$published" ] || die "composer.phar sha256 $actual, published $published"
chmod 0644 "$STAGE/bin/composer.phar"
curl -fsSL --retry 3 --proto '=https' -o "$STAGE/share/licenses/composer.txt" \
    "https://raw.githubusercontent.com/composer/composer/$VERSION/LICENSE"
echo "$VERSION" > "$STAGE.version"
echo "composer $VERSION sha256 $actual"
