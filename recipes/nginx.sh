#!/bin/bash
# Builds stable nginx with PCRE2 and OpenSSL 3 linked statically into STAGE/.
# Usage: recipes/nginx.sh STAGE_DIR
source "$(dirname "$0")/lib.sh"

NGINX=1.30.6
PCRE2=10.49
OPENSSL=3.5.9

STAGE="$(mkdir -p "$1" && cd "$1" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/nginx"
mkdir -p "$WORK/src"

fetch "https://nginx.org/download/nginx-$NGINX.tar.gz" "$WORK/src"
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2/pcre2-$PCRE2.tar.gz" "$WORK/src"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" "$WORK/src"
for t in "$WORK"/src/*.tar.gz; do tar -xzf "$t" -C "$WORK/src"; done

cd "$WORK/src/nginx-$NGINX"
# The compiled-in prefix is never used: Stackmur always passes -p, -c and -e.
./configure \
    --prefix=/var/empty/stackmur-nginx \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_gzip_static_module \
    --with-pcre="$WORK/src/pcre2-$PCRE2" \
    --with-pcre-jit \
    --with-openssl="$WORK/src/openssl-$OPENSSL" \
    --with-openssl-opt="no-tests" \
    --with-cc-opt="-mmacosx-version-min=13.0 -O2" \
    --with-ld-opt="-mmacosx-version-min=13.0"
make -j"$(sysctl -n hw.ncpu)"

mkdir -p "$STAGE/bin" "$STAGE/share/licenses"
cp objs/nginx "$STAGE/bin/nginx"
cp LICENSE "$STAGE/share/licenses/nginx.txt"
cp "$WORK/src/openssl-$OPENSSL/LICENSE.txt" "$STAGE/share/licenses/openssl.txt"
cp "$WORK/src/pcre2-$PCRE2/LICENCE.md" "$STAGE/share/licenses/pcre2.md" 2>/dev/null \
    || cp "$WORK/src/pcre2-$PCRE2/LICENCE" "$STAGE/share/licenses/pcre2.txt"
check_binary "$STAGE/bin/nginx"
"$STAGE/bin/nginx" -V
echo "$NGINX" > "$STAGE.version"
