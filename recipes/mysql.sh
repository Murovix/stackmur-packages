#!/bin/bash
# Builds MySQL Community Server SERIES (8.0 or 8.4) from Oracle's source for
# macOS 13+ arm64 into STAGE/. Oracle's own macOS tarballs target macOS 14+
# (probe-mysql, 2026-11-13: 8.4.13 has minos 14.0), so they are not repacked.
# OpenSSL 3 is linked statically; X Protocol, Router, NDB, LDAP/Kerberos/FIDO
# authentication and unit tests are left out (not needed for local sites).
# Needs cmake, ninja and bison on PATH (CI runner only, never on a user's Mac).
# Usage: recipes/mysql.sh SERIES STAGE_DIR
source "$(dirname "$0")/lib.sh"

SERIES="$1"
case "$SERIES" in
    8.4) VERSION=8.4.13; TARBALL="mysql-$VERSION.tar.gz" ;;
    # 8.0 needs Boost 1.77; the -boost tarball carries it.
    8.0) VERSION=8.0.46; TARBALL="mysql-boost-$VERSION.tar.gz" ;;
    *) die "unsupported MySQL series $SERIES (8.0 or 8.4)" ;;
esac
OPENSSL=3.5.9

STAGE="$(mkdir -p "$2" && cd "$2" && pwd)"
WORK="${WORK_DIR:-$REPO_ROOT/work}/mysql-$SERIES"
mkdir -p "$WORK/src"

fetch "https://cdn.mysql.com/Downloads/MySQL-$SERIES/$TARBALL" "$WORK/src"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL/openssl-$OPENSSL.tar.gz" "$WORK/src"
for t in "$WORK"/src/*.tar.gz; do tar -xzf "$t" -C "$WORK/src"; done

# OpenSSL in a private prefix. 8.0 links it statically. 8.4's cmake on macOS
# only accepts shared OpenSSL (static: "OpenSSL::SSL-NOTFOUND", CI
# 2026-11-13) and installs the dylibs into lib/ with @loader_path names, as
# Oracle's own tarball does; they ship inside the package.
OSSL="$WORK/openssl"
shared=no-shared
[ "$SERIES" = 8.4 ] && shared=shared
if [ ! -f "$OSSL/lib/libssl.a" ]; then
    (cd "$WORK/src/openssl-$OPENSSL" \
        && ./Configure darwin64-arm64-cc "$shared" no-tests no-docs \
            --prefix="$OSSL" --libdir=lib -mmacosx-version-min=13.0 \
        && make -j"$(sysctl -n hw.ncpu)" >/dev/null \
        && make install_sw >/dev/null)
fi

BUILD="$WORK/build"
mkdir -p "$BUILD"
boost=()
[ "$SERIES" = 8.0 ] && boost=(-DWITH_BOOST="$WORK/src/mysql-$VERSION/boost")
# The compiled-in prefix is never used: Stackmur always passes --basedir,
# --datadir, --plugin-dir and --lc-messages-dir.
cmake -G Ninja -S "$WORK/src/mysql-$VERSION" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/var/empty/stackmur-mysql \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DWITH_SSL="$OSSL" \
    -DWITH_ZLIB=bundled -DWITH_ZSTD=bundled -DWITH_LZ4=bundled \
    -DWITH_EDITLINE=bundled -DWITH_ICU=bundled \
    -DWITH_MYSQLX=OFF -DWITH_ROUTER=OFF -DWITH_NDB=OFF -DWITH_NDBCLUSTER=OFF \
    -DWITH_UNIT_TESTS=OFF -DWITH_FIDO=none -DWITH_KERBEROS=none \
    -DWITH_AUTHENTICATION_LDAP=OFF -DWITH_AUTHENTICATION_KERBEROS=OFF \
    -DWITH_AUTHENTICATION_FIDO=OFF -DWITH_AUTHENTICATION_CLIENT_PLUGINS=OFF \
    -DINSTALL_MYSQLTESTDIR= \
    ${boost[@]+"${boost[@]}"}
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu)"
rm -rf "$WORK/install"
DESTDIR="$WORK/install" cmake --install "$BUILD" --strip
I="$WORK/install/var/empty/stackmur-mysql"
ls -la "$I" "$I/bin" "$I/lib" || true

# Only what a local server and its everyday tools need.
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/licenses"
for b in mysqld mysql mysqladmin mysqldump mysqlcheck mysqlimport mysqlshow \
         mysql_tzinfo_to_sql my_print_defaults mysqlbinlog; do
    cp "$I/bin/$b" "$STAGE/bin/$b"
done
cp -R "$I/lib/plugin" "$STAGE/lib/plugin"
# Real files only (no symlinks): the bundled OpenSSL of 8.4.
for l in "$I"/lib/*.dylib; do
    case "${l##*/}" in libmysqlclient*) continue ;; esac
    [ -f "$l" ] && [ ! -L "$l" ] && cp "$l" "$STAGE/lib/"
done
rm -rf "$STAGE/lib/plugin/debug"
cp -R "$I/share/." "$STAGE/share/"
cp "$WORK/src/mysql-$VERSION/LICENSE" "$STAGE/share/licenses/mysql.txt"
cp "$WORK/src/openssl-$OPENSSL/LICENSE.txt" "$STAGE/share/licenses/openssl.txt"

# 8.0's mysqld links the bundled libprotobuf-lite through @loader_path (even
# without X Protocol); it ships next to the binaries.
for l in "$I"/lib/libprotobuf-lite.*.dylib; do
    [ -f "$l" ] && [ ! -L "$l" ] && cp "$l" "$STAGE/bin/"
done
for b in "$STAGE"/bin/* "$STAGE"/lib/*.dylib; do
    [ -f "$b" ] && check_binary "$b" "$STAGE"
done
otool -L "$STAGE/bin/mysqld"
for p in "$STAGE"/lib/plugin/*.so; do check_binary "$p" "$STAGE" >/dev/null; done
vtool -show-build "$STAGE/bin/mysqld" | grep -E 'minos|sdk'
vtool -show-build "$STAGE/bin/mysqld" | grep -q 'minos 13.0' || die "mysqld does not target macOS 13.0"
"$STAGE/bin/mysqld" --version
du -sh "$STAGE"
echo "$VERSION" > "$STAGE.version"
