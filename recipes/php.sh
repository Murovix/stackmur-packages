#!/bin/bash
# Builds PHP MINOR (8.1 … 8.5) CLI + FPM with static-php-cli into STAGE/.
# Needs php and composer on PATH to run static-php-cli from source, plus the
# autotools set (CI installs them on the runner, never on a user's Mac).
# Usage: recipes/php.sh MINOR STAGE_DIR
source "$(dirname "$0")/lib.sh"

# static-php-cli is run from a pinned tag of its source, not a prebuilt binary:
# the binaries have no published checksums (docs/build.md).
SPC_TAG=2.8.5
EXTENSIONS="bcmath,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_sqlite,phar,posix,redis,session,simplexml,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib"

MINOR="$1"
[[ "$MINOR" =~ ^8\.[1-5]$ ]] || die "unsupported PHP version $MINOR (MVP: 8.1-8.5)"
STAGE="$(mkdir -p "$2" && cd "$2" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/php-$MINOR"
mkdir -p "$WORK"

if [ ! -d "$WORK/spc" ]; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SPC_TAG" \
        https://github.com/crazywhalecc/static-php-cli "$WORK/spc"
fi
echo "static-php-cli $SPC_TAG at $(git -C "$WORK/spc" rev-parse HEAD)"
cd "$WORK/spc"
composer install --no-dev --no-interaction --no-progress --quiet

# Compiled-in ini paths point at /var/empty (always empty, root-owned), so a
# php.ini of Homebrew, MAMP or anything else is never picked up; Stackmur
# passes its own with -c.
cat > craft.yml <<YML
php-version: "$MINOR"
extensions: "$EXTENSIONS"
sapi:
  - cli
  - fpm
build-options:
  with-config-file-path: /var/empty
  with-config-file-scan-dir: /var/empty
craft-options:
  doctor: false
  download: true
  build: true
# Libraries are built from source too: static-php-cli's pre-built ones
# (static-php-cli-hosted releases) carry no published checksums.
download-options:
  retry: 3
  prefer-pre-built: false
YML
# spc looks for pkg-config only in its own buildroot/bin or pkgroot; its
# `doctor` would fetch a pre-built one. Use the runner's (a build tool, not
# packaged: only php and php-fpm are copied out of buildroot/bin).
PKG_CONFIG_BIN="$(command -v pkg-config)" || die "pkg-config is not on PATH"
mkdir -p buildroot/bin
ln -sf "$PKG_CONFIG_BIN" buildroot/bin/pkg-config
php bin/spc craft craft.yml

PHP="$WORK/spc/buildroot/bin/php"
FPM="$WORK/spc/buildroot/bin/php-fpm"
[ -x "$FPM" ] || FPM="$WORK/spc/buildroot/sbin/php-fpm"
[ -x "$PHP" ] && [ -x "$FPM" ] || die "static-php-cli produced no php / php-fpm"
VERSION="$("$PHP" -n -r 'echo PHP_VERSION;')"
[[ "$VERSION" == "$MINOR".* ]] || die "built PHP $VERSION, expected $MINOR.x"

mkdir -p "$STAGE/bin" "$STAGE/share/licenses"
cp "$PHP" "$STAGE/bin/php"
cp "$FPM" "$STAGE/bin/php-fpm"
if [ -d buildroot/license ]; then cp -R buildroot/license/. "$STAGE/share/licenses/"; fi
for bin in "$STAGE/bin/php" "$STAGE/bin/php-fpm"; do check_binary "$bin"; done
"$STAGE/bin/php" -n -m
"$STAGE/bin/php" -n --ini
echo "$VERSION" > "$STAGE.version"
