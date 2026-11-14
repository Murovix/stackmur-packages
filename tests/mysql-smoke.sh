#!/bin/bash
# Real check of one MySQL build: initialise a datadir, start mysqld on
# 127.0.0.1 only (never a foreign my.cnf: --defaults-file), create a database
# and a password user, use it over TCP, restart and see the data survive.
# Usage: tests/mysql-smoke.sh MYSQL_STAGE SERIES
source "$(dirname "$0")/../recipes/lib.sh"

M="$(cd "$1" && pwd)"
SERIES="$2"
PORT="${SMOKE_MYSQL_PORT:-13306}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stackmur-mysql.XXXXXX")" && pwd -P)"
PID=""
cleanup() {
    [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
    [ "${KEEP_SMOKE_DIR:-0}" = 1 ] || rm -rf "$T"
}
trap cleanup EXIT

cat > "$T/my.cnf" <<CNF
[mysqld]
basedir=$M
datadir=$T/data
plugin-dir=$M/lib/plugin
lc-messages-dir=$M/share
socket=$T/mysql.sock
pid-file=$T/mysqld.pid
port=$PORT
bind-address=127.0.0.1
log-error=$T/error.log
CNF
# 8.4 ships mysql_native_password disabled; legacy PHP projects may need it.
[ "$SERIES" = 8.4 ] && echo "mysql-native-password=ON" >> "$T/my.cnf"

q() { "$M/bin/mysql" --no-defaults --socket="$T/mysql.sock" -uroot -N -B -e "$1"; }
start() {
    "$M/bin/mysqld" --defaults-file="$T/my.cnf" &
    PID=$!
    for _ in $(seq 120); do
        "$M/bin/mysqladmin" --no-defaults --socket="$T/mysql.sock" -uroot ping >/dev/null 2>&1 && return
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.5
    done
    cat "$T/error.log" >&2; die "mysqld did not start"
}
stop() {
    "$M/bin/mysqladmin" --no-defaults --socket="$T/mysql.sock" -uroot shutdown
    wait "$PID" || true; PID=""
}

"$M/bin/mysqld" --defaults-file="$T/my.cnf" --initialize-insecure
start
v="$(q 'SELECT VERSION()')"; echo "version $v"
[[ "$v" == "$SERIES".* ]] || die "version $v is not $SERIES"
[ "$(q 'SELECT @@bind_address')" = 127.0.0.1 ] || die "not bound to 127.0.0.1 only"
listen="$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN -F n | sed -n 's/^n//p' | sort -u)"
echo "listening: $listen"
[ "$listen" = "127.0.0.1:$PORT" ] || die "unexpected listeners: $listen"

q "CREATE DATABASE shop; CREATE USER 'shop'@'127.0.0.1' IDENTIFIED BY 'S3cret-pass'; GRANT ALL ON shop.* TO 'shop'@'127.0.0.1';"
q "CREATE USER 'legacy'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY 'Legacy-pass';"
q "SELECT user, plugin FROM mysql.user WHERE user IN ('shop','legacy') ORDER BY user"
for u in "shop S3cret-pass" "legacy Legacy-pass"; do
    set -- $u
    "$M/bin/mysql" --no-defaults -h127.0.0.1 -P"$PORT" -u"$1" -p"$2" -N -B \
        -e "SELECT CURRENT_USER(), @@ssl_cipher IS NOT NULL" || die "TCP login as $1 failed"
done
"$M/bin/mysql" --no-defaults -h127.0.0.1 -P"$PORT" -ushop -pS3cret-pass shop \
    -e "CREATE TABLE t (v VARCHAR(10)); INSERT INTO t VALUES ('kept');"
"$M/bin/mysqldump" --no-defaults --socket="$T/mysql.sock" -uroot shop > "$T/shop.sql"
grep -q "'kept'" "$T/shop.sql" || die "mysqldump lost the row"

stop
start
[ "$(q 'SELECT v FROM shop.t')" = kept ] || die "data did not survive a restart"
stop
grep -E '\[(ERROR)\]' "$T/error.log" && die "errors in error.log" || true
echo "mysql $SERIES smoke test passed"
