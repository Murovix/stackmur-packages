#!/bin/bash
# Phase 3 probe, not a recipe: answers whether Oracle's official macOS arm64
# tarballs of MySQL 8.0 and 8.4 fit Stackmur (CLAUDE.md rule 2: verify first).
# Finds the newest tarball per series on cdn.mysql.com, reports what Oracle
# publishes next to it (md5, signature), the minimum macOS of the binaries,
# their dylib dependencies and size, then really initialises a datadir, starts
# mysqld on 127.0.0.1 only, connects, and shuts it down.
# Usage: probes/mysql.sh SERIES   (8.0 or 8.4)
set -euo pipefail
SERIES="$1"
case "$SERIES" in 8.0|8.4) ;; *) echo "series must be 8.0 or 8.4" >&2; exit 2 ;; esac
W="${WORK_DIR:-$PWD/work}/mysql-$SERIES"
mkdir -p "$W"
CDN="https://cdn.mysql.com/Downloads/MySQL-$SERIES"

head_ok() { curl -fsSIL --proto '=https' -o /dev/null -m 30 "$1"; }

found=""
for patch in $(seq 60 -1 0); do
    v="$SERIES.$patch"
    for os in 15 14 13 12; do
        url="$CDN/mysql-$v-macos$os-arm64.tar.gz"
        if head_ok "$url"; then found="$url"; break 2; fi
    done
done
[ -n "$found" ] || { echo "no macOS arm64 tarball found for $SERIES on the CDN" >&2; exit 1; }
name="${found##*/}"
echo "== newest tarball: $found"
for os in 15 14 13 12; do
    u="$CDN/${name/macos[0-9][0-9]/macos$os}"
    head_ok "$u" && echo "   also published for macos$os: ${u##*/}" || true
done
for ext in .md5 .asc .sig .sha256; do
    head_ok "$found$ext" && echo "   companion file exists: $name$ext" || echo "   no $name$ext"
done

curl -fsSL --retry 3 --proto '=https' -o "$W/$name" "$found"
echo "== sha256 $(shasum -a 256 "$W/$name" | cut -d' ' -f1)  md5 $(md5 -q "$W/$name")  size $(stat -f %z "$W/$name")"
tar -xzf "$W/$name" -C "$W"
D="$W/${name%.tar.gz}"
echo "== top level"; ls -la "$D"
echo "== du"; du -sh "$D"/* | sort -h
echo "== bin"; ls -la "$D/bin"
echo "== lib"; ls -la "$D/lib" | head -60
echo "== mysqld build version"; vtool -show-build "$D/bin/mysqld" || otool -l "$D/bin/mysqld" | grep -A4 LC_BUILD_VERSION
echo "== mysqld dylibs"; otool -L "$D/bin/mysqld"
echo "== mysqld rpaths"; otool -l "$D/bin/mysqld" | grep -A2 LC_RPATH || true
echo "== mysql client dylibs"; otool -L "$D/bin/mysql"
echo "== codesign"; codesign -dv --verbose=2 "$D/bin/mysqld" 2>&1 | head -12 || true
echo "== plugins with foreign dylibs"
for f in "$D"/lib/plugin/*.so "$D"/lib/*.dylib; do
    [ -f "$f" ] || continue
    otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/|^@' | sed "s|^|${f##*/}: |" || true
done

echo "== live run on 127.0.0.1"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/mysql-probe.XXXXXX")" && pwd -P)"
PORT=13306
cat > "$T/my.cnf" <<CNF
[mysqld]
basedir=$D
datadir=$T/data
socket=$T/mysql.sock
pid-file=$T/mysqld.pid
port=$PORT
bind-address=127.0.0.1
mysqlx=OFF
log-error=$T/error.log
CNF
time "$D/bin/mysqld" --defaults-file="$T/my.cnf" --initialize-insecure --user="$(id -un)"
"$D/bin/mysqld" --defaults-file="$T/my.cnf" --user="$(id -un)" &
pid=$!
for i in $(seq 1 60); do
    "$D/bin/mysqladmin" --no-defaults -uroot --socket="$T/mysql.sock" ping >/dev/null 2>&1 && break
    sleep 1
done
"$D/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P$PORT -e \
  "SELECT VERSION(), @@bind_address, @@default_authentication_plugin AS auth_default_80_only;" 2>&1 \
  || "$D/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P$PORT -e "SELECT VERSION(), @@bind_address;"
"$D/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P$PORT -e \
  "SHOW PLUGINS" | grep -iE 'native|caching_sha2' || true
"$D/bin/mysql" --no-defaults -uroot -h127.0.0.1 -P$PORT -e \
  "CREATE USER legacy@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY 'x'; SELECT user, plugin FROM mysql.user WHERE user='legacy';" 2>&1 || echo "mysql_native_password user: refused"
echo "listening sockets:"; lsof -nP -p "$pid" -a -iTCP -sTCP:LISTEN || true
"$D/bin/mysqladmin" --no-defaults -uroot --socket="$T/mysql.sock" shutdown
wait "$pid" || true
tail -n 20 "$T/error.log"
echo "== probe $SERIES done"
