# stackmur-packages

Build recipes and the signed package manifest for [Stackmur](https://github.com/Murovix/Stackmur),
a native macOS local web environment. Stackmur installs only packages listed in a
`manifest.json` whose minisign signature verifies against the public key built into
Stackmur, and only archives whose SHA-256 and size match that manifest.

| Package | Source | Recipe |
| --- | --- | --- |
| `php-8.1` … `php-8.5` | [static-php-cli](https://github.com/crazywhalecc/static-php-cli) from a pinned tag, CLI + FPM | `recipes/php.sh` |
| `nginx` | nginx stable, PCRE2 and OpenSSL 3 linked statically | `recipes/nginx.sh` |
| `composer` | official `composer.phar`, checked against getcomposer.org's SHA-256 | `recipes/composer.sh` |

Targets: macOS 13+, Apple Silicon (arm64) only.

## How a release is made

1. `build` workflow (pull requests, or by hand): builds every package on `macos-15`,
   then `tests/smoke.sh` starts each PHP-FPM build behind the built nginx (IPv4 and
   IPv6), checks the required extensions, opcache, intl, sodium, PDO SQLite and that
   no foreign `php.ini` is read, and runs Composer with the built PHP.
2. `tools/pkgtool pack` writes a reproducible `tar.zst` (sorted entries, owner and
   times zeroed, modes 0755/0644, only files, directories and relative symlinks).
3. Run by hand on `main` with **publish**: the job refuses sources not pinned in
   `sources.lock`, merges the previous manifest (older builds stay installable),
   signs a new manifest with a higher serial and creates release `r<serial>`.

Stackmur reads `https://github.com/Murovix/stackmur-packages/releases/latest/download/manifest.json`.

## Signing key

- Secret key: repository secret `STACKMUR_SIGNING_KEY`. It never appears in the repository,
  logs or chat. An offline backup is kept by the owner.
- Public key: repository variable `STACKMUR_PUBLIC_KEY`, and compiled into Stackmur.
- Create one (once, on the owner's Mac):
  `cargo run --release --manifest-path tools/pkgtool/Cargo.toml -- keygen --secret-key ~/stackmur-signing.key`

## Not yet

Developer ID signing and notarization of the binaries (ad-hoc signatures for now),
MySQL, Valkey, Mailpit, shared extensions such as xdebug.
