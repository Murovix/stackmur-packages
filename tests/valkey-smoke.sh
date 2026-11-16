#!/bin/bash
# Real check of the Valkey build: start valkey-server on loopback only with a
# private config (never a foreign valkey.conf or redis.conf), write keys,
# restart with a snapshot and AOF, and see the data survive.
# Usage: tests/valkey-smoke.sh VALKEY_STAGE
source "$(dirname "$0")/../recipes/lib.sh"

V="$(cd "$1" && pwd)"
PORT="${SMOKE_VALKEY_PORT:-16379}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stackmur-valkey.XXXXXX")" && pwd -P)"
PID=""
cleanup() {
    [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
    [ "${KEEP_SMOKE_DIR:-0}" = 1 ] || rm -rf "$T"
}
trap cleanup EXIT

cat > "$T/valkey.conf" <<CONF
bind 127.0.0.1 -::1
port $PORT
protected-mode yes
daemonize no
dir $T
pidfile $T/valkey.pid
logfile $T/valkey.log
unixsocket $T/valkey.sock
unixsocketperm 700
save 3600 1
appendonly yes
CONF

cli() { "$V/bin/valkey-cli" -h 127.0.0.1 -p "$PORT" "$@"; }
start() {
    "$V/bin/valkey-server" "$T/valkey.conf" &
    PID=$!
    for _ in $(seq 60); do
        [ "$(cli PING 2>/dev/null)" = PONG ] && return
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.25
    done
    cat "$T/valkey.log" >&2; die "valkey-server did not start"
}
stop() {
    cli SHUTDOWN SAVE >/dev/null 2>&1 || true
    wait "$PID" || true; PID=""
}

start
cli INFO server | grep -E '^(valkey_version|redis_version|os|arch_bits|multiplexing_api):'
listen="$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN -F n | sed -n 's/^n//p' | sort -u | tr '\n' ' ')"
echo "listening: $listen"
for addr in $listen; do
    case "$addr" in
        "127.0.0.1:$PORT" | "[::1]:$PORT") ;;
        *) die "unexpected listener $addr" ;;
    esac
done
case "$listen" in *"127.0.0.1:$PORT"*) ;; *) die "not listening on 127.0.0.1:$PORT" ;; esac

# The commands Laravel's cache, queue and session drivers use.
[ "$(cli SET laravel:k kept)" = OK ] || die "SET failed"
cli EXPIRE laravel:k 3600 >/dev/null
cli RPUSH queues:default job1 job2 >/dev/null
cli EVAL "return redis.call('LLEN', KEYS[1])" 1 queues:default | grep -qx 2 || die "Lua EVAL failed"
[ "$("$V/bin/valkey-cli" -s "$T/valkey.sock" GET laravel:k)" = kept ] || die "unix socket GET failed"
"$V/bin/valkey-benchmark" -h 127.0.0.1 -p "$PORT" -q -n 2000 -t set,get

stop
start
[ "$(cli GET laravel:k)" = kept ] || die "data did not survive a restart"
[ "$(cli LLEN queues:default)" = 2 ] || die "list did not survive a restart"
stop
echo "valkey smoke test passed"
