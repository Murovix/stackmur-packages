#!/bin/bash
# Builds PHP 7.4 (EOL, legacy projects) CLI + FPM for macOS 13+ arm64 into
# STAGE/. static-php-cli does not build 7.4, so this is our own pipeline:
# PHP 7.4 needs OpenSSL 1.1.1 (it does not build against OpenSSL 3), linked
# statically from a private prefix with the other libraries the MVP
# extension set needs. libxml2, sqlite3, curl, zlib and iconv come from macOS.
# Needs autoconf, cmake, pkg-config on PATH (CI runner only).
# Usage: recipes/php74.sh STAGE_DIR
source "$(dirname "$0")/lib.sh"

PHP=7.4.33
OPENSSL=1.1.1w
ICU=72.1
ONIG=6.9.9
LIBZIP=1.10.1
LIBPNG=1.6.44
JPEG=3.0.4
FREETYPE=2.13.3
SODIUM=1.0.20
REDIS=5.3.7

STAGE="$(mkdir -p "$1" && cd "$1" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/php-7.4"
SRC="$WORK/src"
P="$WORK/prefix"
mkdir -p "$SRC" "$P"
JOBS="$(sysctl -n hw.ncpu)"
SDK="$(xcrun --show-sdk-path)"
export CFLAGS="-O2 -mmacosx-version-min=13.0 -arch arm64"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=13.0 -arch arm64"
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$SDK/usr/lib/pkgconfig"

fetch "https://www.php.net/distributions/php-$PHP.tar.xz" "$SRC"
fetch "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL//./_}/openssl-$OPENSSL.tar.gz" "$SRC"
fetch "https://github.com/unicode-org/icu/releases/download/release-${ICU//./-}/icu4c-${ICU//./_}-src.tgz" "$SRC"
fetch "https://github.com/kkos/oniguruma/releases/download/v$ONIG/onig-$ONIG.tar.gz" "$SRC"
fetch "https://github.com/nih-at/libzip/releases/download/v$LIBZIP/libzip-$LIBZIP.tar.gz" "$SRC"
fetch "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG.tar.gz" "$SRC"
fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG/libjpeg-turbo-$JPEG.tar.gz" "$SRC"
fetch "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE.tar.xz" "$SRC"
fetch "https://github.com/jedisct1/libsodium/releases/download/$SODIUM-RELEASE/libsodium-$SODIUM.tar.gz" "$SRC"
fetch "https://pecl.php.net/get/redis-$REDIS.tgz" "$SRC"
cd "$SRC"
for t in *.tar.gz *.tgz *.tar.xz; do
    d="$SRC/x-$t"; [ -d "$d" ] || { mkdir -p "$d"; tar -xf "$t" -C "$d"; }
done
dir() { find "$SRC/x-$1" -mindepth 1 -maxdepth 1 -type d | head -1; }

step() { echo "::group::$1"; }
endstep() { echo "::endgroup::"; }

if [ ! -f "$P/lib/libssl.a" ]; then
    step "OpenSSL $OPENSSL"
    (cd "$(dir "openssl-$OPENSSL.tar.gz")" \
        && ./Configure darwin64-arm64-cc no-shared no-tests --prefix="$P" --openssldir=/var/empty/stackmur-openssl -mmacosx-version-min=13.0 \
        && make -j"$JOBS" >/dev/null && make install_sw >/dev/null)
    endstep
fi
if [ ! -f "$P/lib/libicuuc.a" ]; then
    step "ICU $ICU"
    (cd "$(dir "icu4c-${ICU//./_}-src.tgz")/source" \
        && ./configure --prefix="$P" --enable-static --disable-shared --disable-tests --disable-samples --disable-extras --with-data-packaging=static \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)
    endstep
fi
autotools_lib() { # tarball, check file, extra configure args...
    local t="$1" check="$2"; shift 2
    [ -f "$P/lib/$check" ] && return
    step "$t"
    (cd "$(dir "$t")" && ./configure --prefix="$P" --enable-static --disable-shared "$@" \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)
    endstep
}
cmake_lib() { # tarball, check file, extra cmake args...
    local t="$1" check="$2"; shift 2
    [ -f "$P/lib/$check" ] && return
    step "$t"
    cmake -S "$(dir "$t")" -B "$WORK/build-$t" -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DBUILD_SHARED_LIBS=OFF "$@" >/dev/null
    cmake --build "$WORK/build-$t" -j"$JOBS" >/dev/null && cmake --install "$WORK/build-$t" >/dev/null
    endstep
}
autotools_lib "onig-$ONIG.tar.gz" libonig.a
autotools_lib "libsodium-$SODIUM.tar.gz" libsodium.a
cmake_lib "v$LIBPNG.tar.gz" libpng16.a -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
cmake_lib "libjpeg-turbo-$JPEG.tar.gz" libjpeg.a -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF
autotools_lib "freetype-$FREETYPE.tar.xz" libfreetype.a --without-harfbuzz --without-brotli --without-bzip2 --with-png=no --with-zlib=yes
cmake_lib "libzip-$LIBZIP.tar.gz" libzip.a -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF -DBUILD_TOOLS=OFF \
    -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DBUILD_OSSFUZZ=OFF
# Only static archives in the prefix: the PHP link must not pick a dylib.
find "$P/lib" -name '*.dylib' -delete
# libpng's and libzip's .pc files require zlib; macOS's has no .pc file.
cat > "$P/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: zlib from macOS
Version: 1.2.12
Cflags:
Libs: -lz
PC

PHPSRC="$(dir "php-$PHP.tar.xz")"
if [ ! -d "$PHPSRC/ext/redis" ]; then
    cp -R "$(dir "redis-$REDIS.tgz")" "$PHPSRC/ext/redis"
    (cd "$PHPSRC" && ./buildconf --force)
fi

step "PHP $PHP"
cd "$PHPSRC"
# PHP 7.4 predates clang 16, which made these warnings errors by default.
# -fno-strict-return: configure tests such as GD's have non-void functions
# without return, which Apple clang turns into a trap at -O2 (CI 2026-11-13).
OLD="-fno-strict-return -Wno-error=incompatible-function-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=implicit-int"
# Compiled-in ini paths point at /var/empty (root-owned, always empty), as for
# 8.x: a foreign php.ini is never read; Stackmur passes -c.
# macOS ships libxml2, sqlite3, curl and zlib without .pc files.
CFLAGS="$CFLAGS $OLD -I$P/include" CXXFLAGS="$CXXFLAGS -std=c++11 -I$P/include" \
LDFLAGS="$LDFLAGS -L$P/lib" \
LIBS="-lc++" \
LIBXML_CFLAGS="-I$SDK/usr/include/libxml2" LIBXML_LIBS="-lxml2" \
SQLITE_CFLAGS=" " SQLITE_LIBS="-lsqlite3" \
CURL_CFLAGS=" " CURL_LIBS="-lcurl" \
ZLIB_CFLAGS=" " ZLIB_LIBS="-lz" \
ac_cv_prog_cc_c23=no \
./configure \
    --prefix=/var/empty/stackmur-php74 \
    --with-config-file-path=/var/empty \
    --with-config-file-scan-dir=/var/empty \
    --disable-all --disable-cgi --disable-phpdbg \
    --enable-cli --enable-fpm \
    --with-openssl \
    --with-zlib --with-curl --with-iconv="$SDK/usr" --with-libxml \
    --with-sqlite3 --with-pdo-sqlite --enable-pdo --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd --enable-mysqlnd \
    --enable-mbstring --enable-mbregex --enable-intl --with-sodium --with-zip \
    --enable-gd --with-jpeg --with-freetype \
    --enable-bcmath --enable-ctype --enable-dom --enable-exif --enable-fileinfo --enable-filter \
    --enable-json --enable-pcntl --enable-phar --enable-posix --enable-session --enable-simplexml \
    --enable-tokenizer --enable-xml --enable-xmlreader --enable-xmlwriter \
    --enable-opcache --without-pcre-jit \
    --enable-redis --disable-redis-igbinary --disable-redis-lzf --disable-redis-zstd \
    --without-pear \
    || { grep -n -B2 -A40 'GD build test\|checking for working gdImage\|conftest' config.log | tail -n 150; exit 1; }
make -j"$JOBS" >/dev/null
endstep

VERSION="$(sapi/cli/php -n -r 'echo PHP_VERSION;')"
[ "$VERSION" = "$PHP" ] || die "built PHP $VERSION, expected $PHP"
mkdir -p "$STAGE/bin" "$STAGE/lib/extensions" "$STAGE/share/licenses"
cp sapi/cli/php "$STAGE/bin/php"
cp sapi/fpm/php-fpm "$STAGE/bin/php-fpm"
# OPcache is always a shared zend_extension in PHP 7.4.
cp modules/opcache.so "$STAGE/lib/extensions/opcache.so"
cp LICENSE "$STAGE/share/licenses/php.txt"
cp "$(dir "openssl-$OPENSSL.tar.gz")/LICENSE" "$STAGE/share/licenses/openssl.txt"
cp "$(dir "icu4c-${ICU//./_}-src.tgz")/LICENSE" "$STAGE/share/licenses/icu.txt"
for b in "$STAGE/bin/php" "$STAGE/bin/php-fpm" "$STAGE/lib/extensions/opcache.so"; do check_binary "$b"; done
for b in "$STAGE/bin/php" "$STAGE/bin/php-fpm"; do
    vtool -show-build "$b" | grep -q 'minos 13.0' || die "$b does not target macOS 13.0"
done
"$STAGE/bin/php" -n -m
"$STAGE/bin/php" -n -r 'echo OPENSSL_VERSION_TEXT, PHP_EOL;'
echo "$VERSION" > "$STAGE.version"
