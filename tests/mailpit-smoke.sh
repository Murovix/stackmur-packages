#!/bin/bash
# Real check of the Mailpit package: SMTP and web UI on loopback only, a
# message sent over SMTP shows up in the API and survives a restart (its
# database lives outside the package).
# Usage: tests/mailpit-smoke.sh MAILPIT_STAGE
source "$(dirname "$0")/../recipes/lib.sh"

M="$(cd "$1" && pwd)"
SMTP="${SMOKE_MAILPIT_SMTP:-11025}"
HTTP="${SMOKE_MAILPIT_HTTP:-18025}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/stackmur-mailpit.XXXXXX")" && pwd -P)"
PID=""
cleanup() {
    [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
    [ "${KEEP_SMOKE_DIR:-0}" = 1 ] || rm -rf "$T"
}
trap cleanup EXIT

api() { curl -fsS "http://127.0.0.1:$HTTP/api/v1/$1"; }
start() {
    "$M/bin/mailpit" --listen "127.0.0.1:$HTTP" --smtp "127.0.0.1:$SMTP" \
        --database "$T/mailpit.db" --disable-version-check >"$T/mailpit.log" 2>&1 &
    PID=$!
    for _ in $(seq 60); do
        api info >/dev/null 2>&1 && return
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.25
    done
    cat "$T/mailpit.log" >&2; die "mailpit did not start"
}
stop() { kill "$PID"; wait "$PID" || true; PID=""; }

start
listen="$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN -F n | sed -n 's/^n//p' | sort -u | tr '\n' ' ')"
echo "listening: $listen"
[ "$listen" = "127.0.0.1:$SMTP 127.0.0.1:$HTTP " ] || die "unexpected listeners: $listen"

printf 'From: shop@shop.test\r\nTo: user@example.test\r\nSubject: Stackmur smoke\r\n\r\nHello from Stackmur.\r\n' > "$T/msg.eml"
curl -fsS "smtp://127.0.0.1:$SMTP" --mail-from shop@shop.test --mail-rcpt user@example.test \
    --upload-file "$T/msg.eml"
api messages | /usr/bin/python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["total"] == 1, m
assert m["messages"][0]["Subject"] == "Stackmur smoke", m["messages"][0]
print("message received:", m["messages"][0]["Subject"])'
curl -fsS "http://127.0.0.1:$HTTP/" | grep -qi mailpit || die "web UI did not answer"

stop
start
api messages | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["total"] == 1' \
    || die "message did not survive a restart"
stop
echo "mailpit smoke test passed"
