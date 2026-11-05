#!/bin/bash
# Real check of one PHP build together with nginx and Composer (CLAUDE.md:
# a version counts as supported only after this works, not after it builds).
# Starts php-fpm and nginx from the given stage dirs on a temp socket and port,
# requests a page through nginx and runs Composer with the built php.
# Usage: tests/smoke.sh NGINX_STAGE PHP_STAGE COMPOSER_STAGE MINOR
source "$(dirname "$0")/../recipes/lib.sh"

NGINX="$(cd "$1" && pwd)/bin/nginx"
PHP_DIR="$(cd "$2" && pwd)"
COMPOSER="$(cd "$3" && pwd)/bin/composer.phar"
MINOR="$4"
PORT="${SMOKE_PORT:-18080}"

T="$(mktemp -d "${TMPDIR:-/tmp}/stackmur-smoke.XXXXXX")"
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    [ "${KEEP_SMOKE_DIR:-0}" = 1 ] || rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/www" "$T/nginx/logs" "$T/nginx/temp"

cat > "$T/php.ini" <<INI
memory_limit = 256M
opcache.enable = 1
opcache.enable_cli = 0
INI
cat > "$T/php-fpm.conf" <<CONF
[global]
pid = $T/php-fpm.pid
error_log = $T/php-fpm.log
daemonize = no
[www]
listen = $T/php-fpm.sock
listen.mode = 0600
pm = static
pm.max_children = 2
catch_workers_output = yes
CONF
cat > "$T/nginx.conf" <<CONF
daemon off;
worker_processes 1;
pid $T/nginx/nginx.pid;
error_log $T/nginx/logs/error.log;
events { worker_connections 64; }
http {
    access_log $T/nginx/logs/access.log;
    client_body_temp_path $T/nginx/temp/body;
    fastcgi_temp_path $T/nginx/temp/fastcgi;
    proxy_temp_path $T/nginx/temp/proxy;
    uwsgi_temp_path $T/nginx/temp/uwsgi;
    scgi_temp_path $T/nginx/temp/scgi;
    server {
        listen 127.0.0.1:$PORT;
        listen [::1]:$PORT;
        root $T/www;
        index index.php;
        location ~ \.php\$ {
            fastcgi_pass unix:$T/php-fpm.sock;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param REQUEST_METHOD \$request_method;
            fastcgi_param QUERY_STRING \$query_string;
        }
    }
}
CONF
cat > "$T/www/index.php" <<'PHP'
<?php
$need = ['bcmath','ctype','curl','dom','exif','fileinfo','filter','gd','iconv','intl',
    'mbstring','mysqli','mysqlnd','openssl','pcntl','pdo','pdo_mysql','phar','posix','redis',
    'session','simplexml','sodium','sqlite3','tokenizer','xml','xmlreader','xmlwriter','zip','zlib'];
$missing = array_values(array_filter($need, fn ($e) => !extension_loaded($e)));
$drivers = PDO::getAvailableDrivers();
foreach (['mysql', 'sqlite'] as $d) { if (!in_array($d, $drivers, true)) $missing[] = "pdo:$d"; }
$db = new PDO('sqlite::memory:');
$db->exec('create table t (v text)');
$db->exec("insert into t values ('ok')");
echo json_encode([
    'sapi' => PHP_SAPI,
    'version' => PHP_VERSION,
    'missing' => $missing,
    'sqlite' => $db->query('select v from t')->fetchColumn(),
    'opcache' => function_exists('opcache_get_status') && (opcache_get_status(false)['opcache_enabled'] ?? false),
    'intl' => (new NumberFormatter('uk_UA', NumberFormatter::DECIMAL))->format(1234.5),
    'sodium' => strlen(sodium_crypto_secretbox_keygen()),
    'ini' => php_ini_loaded_file(),
    'scanned' => php_ini_scanned_files(),
]);
PHP

export PHP_INI_SCAN_DIR=
"$PHP_DIR/bin/php-fpm" -c "$T/php.ini" -y "$T/php-fpm.conf" -t
"$PHP_DIR/bin/php-fpm" -c "$T/php.ini" -y "$T/php-fpm.conf" -F &
PIDS+=($!)
"$NGINX" -p "$T/nginx" -c "$T/nginx.conf" -e "$T/nginx/logs/error.log" -t
"$NGINX" -p "$T/nginx" -c "$T/nginx.conf" -e "$T/nginx/logs/error.log" &
PIDS+=($!)

for _ in $(seq 100); do
    [ -S "$T/php-fpm.sock" ] && curl -fs -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
done
for url in "http://127.0.0.1:$PORT/" "http://[::1]:$PORT/"; do
    body="$(curl -fsS "$url")" || { cat "$T/php-fpm.log" "$T/nginx/logs/error.log" >&2; die "$url failed"; }
    echo "$url -> $body"
    /usr/bin/python3 - "$body" "$MINOR" "$T/php.ini" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
problems = []
if r["sapi"] != "fpm-fcgi": problems.append(f"sapi {r['sapi']}")
if not r["version"].startswith(sys.argv[2] + "."): problems.append(f"version {r['version']}")
if r["missing"]: problems.append(f"missing {r['missing']}")
if r["sqlite"] != "ok": problems.append("sqlite")
if r["opcache"] is not True: problems.append("opcache off")
if r["sodium"] != 32: problems.append("sodium")
if "1" not in r["intl"]: problems.append("intl")
if r["ini"] != sys.argv[3]: problems.append(f"ini {r['ini']}")
if r["scanned"]: problems.append(f"scanned {r['scanned']}")
if problems: sys.exit("smoke check failed: " + ", ".join(problems))
PY
done

# The CLI ignores foreign ini files without -c too.
[ "$("$PHP_DIR/bin/php" -r 'echo php_ini_loaded_file() ?: "none";')" = none ] \
    || die "php CLI loaded an ini file it should not see"

# Composer with the built CLI: resolve, download and autoload a real package.
mkdir -p "$T/project"
cd "$T/project"
php_cli=("$PHP_DIR/bin/php" -c "$T/php.ini")
"${php_cli[@]}" "$COMPOSER" --version
COMPOSER_HOME="$T/composer-home" "${php_cli[@]}" "$COMPOSER" require --no-interaction --no-progress psr/log:^3
"${php_cli[@]}" -r 'require "vendor/autoload.php"; exit(interface_exists("Psr\\Log\\LoggerInterface") ? 0 : 1);' \
    || die "composer autoload failed"
echo "smoke ok: PHP $MINOR with nginx and Composer"
