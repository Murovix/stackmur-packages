//! pkgtool: packs, signs and checks Stackmur packages.
//!
//! ```text
//! pkgtool keygen   --secret-key FILE
//! pkgtool pack     --name N --version V --license L --dir DIR --out OUTDIR [--min-macos 13.0]
//! pkgtool manifest --fragments DIR --base-url URL --serial N --out OUTDIR
//!                  [--previous manifest.json --previous-signature manifest.json.minisig]
//!                  [--expect-public-key KEY]
//!                  (secret key from $STACKMUR_SIGNING_KEY or --secret-key FILE)
//! pkgtool verify   --manifest FILE --signature FILE --public-key KEY
//! ```
//!
//! The manifest format is the one `stackmur-packages` reads (ADR 0004 in the
//! Stackmur repository); `deny_unknown_fields` on both sides keeps them equal.

mod archive;
mod manifest;

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Cursor, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use manifest::{Entry, Fragment, Manifest};

type Result<T> = std::result::Result<T, String>;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("keygen") => Flags::parse(&args[1..]).and_then(keygen),
        Some("pack") => Flags::parse(&args[1..]).and_then(pack),
        Some("manifest") => Flags::parse(&args[1..]).and_then(build_manifest),
        Some("verify") => Flags::parse(&args[1..]).and_then(verify),
        _ => Err("usage: pkgtool keygen|pack|manifest|verify [--flag value ...]".into()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("pkgtool: {err}");
            ExitCode::FAILURE
        }
    }
}

/// `--key value` pairs; every flag takes exactly one value.
struct Flags(BTreeMap<String, String>);

impl Flags {
    fn parse(args: &[String]) -> Result<Self> {
        let mut map = BTreeMap::new();
        let mut it = args.iter();
        while let Some(flag) = it.next() {
            let key = flag
                .strip_prefix("--")
                .ok_or_else(|| format!("unexpected argument {flag:?}"))?;
            let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
            if map.insert(key.to_owned(), value.clone()).is_some() {
                return Err(format!("{flag} given twice"));
            }
        }
        Ok(Self(map))
    }
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).map(String::as_str)
    }
    fn need(&self, key: &str) -> Result<&str> {
        self.get(key).ok_or_else(|| format!("--{key} is required"))
    }
}

fn keygen(flags: Flags) -> Result<()> {
    let path = PathBuf::from(flags.need("secret-key")?);
    let pair = minisign::KeyPair::generate_unencrypted_keypair().map_err(|e| e.to_string())?;
    let secret = pair
        .sk
        .to_box(Some("Stackmur package signing key"))
        .map_err(|e| e.to_string())?
        .into_string();
    // Never overwrite an existing key; owner-only from the first byte.
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(secret.as_bytes())
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    println!(
        "secret key: {} (keep it private, back it up offline)",
        path.display()
    );
    println!("public key: {}", pair.pk.to_base64());
    Ok(())
}

fn pack(flags: Flags) -> Result<()> {
    let name = flags.need("name")?;
    let version = flags.need("version")?;
    manifest::validate_name(name)?;
    manifest::validate_version(version)?;
    let min_macos = flags.get("min-macos").unwrap_or("13.0");
    let dir = Path::new(flags.need("dir")?);
    let out = Path::new(flags.need("out")?);
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    // `+` is not kept in GitHub release asset names.
    let stem = format!("{name}-{}-arm64", version.replace('+', "_"));
    let file = format!("{stem}.tar.zst");
    let (sha256, size) = archive::pack(dir, &out.join(&file))?;
    let fragment = Fragment {
        name: name.into(),
        version: version.into(),
        min_macos: min_macos.into(),
        license: flags.need("license")?.into(),
        file: file.clone(),
        sha256,
        size,
    };
    let json = serde_json::to_string_pretty(&fragment).map_err(|e| e.to_string())?;
    fs::write(out.join(format!("{stem}.json")), json + "\n").map_err(|e| e.to_string())?;
    println!("{file}: {size} bytes, sha256 {}", fragment.sha256);
    Ok(())
}

fn signing_key(flags: &Flags) -> Result<minisign::SecretKey> {
    let text = match flags.get("secret-key") {
        Some(path) => fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?,
        None => std::env::var("STACKMUR_SIGNING_KEY")
            .map_err(|_| "no signing key: set STACKMUR_SIGNING_KEY or --secret-key".to_owned())?,
    };
    let sk_box = minisign::SecretKeyBox::from_string(text.trim()).map_err(|e| e.to_string())?;
    minisign::SecretKey::from_unencrypted_box(sk_box).map_err(|e| e.to_string())
}

fn build_manifest(flags: Flags) -> Result<()> {
    let sk = signing_key(&flags)?;
    let pk = minisign::PublicKey::from_secret_key(&sk).map_err(|e| e.to_string())?;
    if let Some(expected) = flags.get("expect-public-key")
        && pk.to_base64() != expected
    {
        return Err("the signing key does not match --expect-public-key".into());
    }
    let serial: u64 = flags
        .need("serial")?
        .parse()
        .map_err(|_| "--serial must be a number")?;
    let base_url = flags.need("base-url")?.trim_end_matches('/');
    if !base_url.starts_with("https://") {
        return Err("--base-url must be https://".into());
    }

    // Builds of earlier releases stay listed (and installable) unless rebuilt.
    let mut packages: Vec<Entry> = Vec::new();
    if let Some(previous) = flags.get("previous") {
        let bytes = fs::read(previous).map_err(|e| format!("{previous}: {e}"))?;
        let sig =
            fs::read_to_string(flags.need("previous-signature")?).map_err(|e| e.to_string())?;
        verify_bytes(&bytes, &sig, &pk)?;
        let old: Manifest = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if old.serial >= serial {
            return Err(format!(
                "serial {serial} is not above the previous {}",
                old.serial
            ));
        }
        packages = old.packages;
    }

    let dir = Path::new(flags.need("fragments")?);
    let mut fragments: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    fragments.sort();
    if fragments.is_empty() {
        return Err(format!("no fragments in {}", dir.display()));
    }
    for path in fragments {
        let text = fs::read(&path).map_err(|e| e.to_string())?;
        let f: Fragment =
            serde_json::from_slice(&text).map_err(|e| format!("{}: {e}", path.display()))?;
        let entry = f.into_entry(base_url);
        packages.retain(|e| {
            !(e.name == entry.name && e.version == entry.version && e.arch == entry.arch)
        });
        packages.push(entry);
    }
    packages.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| manifest::compare_versions(&a.version, &b.version))
    });
    let manifest = Manifest {
        schema: manifest::SCHEMA,
        serial,
        packages,
    };
    manifest.validate()?;
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?;
    let signature = minisign::sign(
        Some(&pk),
        &sk,
        Cursor::new(&bytes),
        Some(&format!("stackmur manifest serial {serial}")),
        None,
    )
    .map_err(|e| e.to_string())?
    .into_string();
    verify_bytes(&bytes, &signature, &pk)?;

    let out = Path::new(flags.need("out")?);
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    fs::write(out.join("manifest.json"), &bytes).map_err(|e| e.to_string())?;
    fs::write(out.join("manifest.json.minisig"), &signature).map_err(|e| e.to_string())?;
    println!(
        "manifest serial {serial}: {} packages, signed by {}",
        manifest.packages.len(),
        pk.to_base64()
    );
    Ok(())
}

fn verify(flags: Flags) -> Result<()> {
    let bytes = fs::read(flags.need("manifest")?).map_err(|e| e.to_string())?;
    let sig = fs::read_to_string(flags.need("signature")?).map_err(|e| e.to_string())?;
    let pk =
        minisign::PublicKey::from_base64(flags.need("public-key")?).map_err(|e| e.to_string())?;
    verify_bytes(&bytes, &sig, &pk)?;
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    manifest.validate()?;
    println!(
        "ok: serial {}, {} packages",
        manifest.serial,
        manifest.packages.len()
    );
    Ok(())
}

fn verify_bytes(bytes: &[u8], signature: &str, pk: &minisign::PublicKey) -> Result<()> {
    let sig_box = minisign::SignatureBox::from_string(signature).map_err(|e| e.to_string())?;
    minisign::verify(pk, &sig_box, Cursor::new(bytes), true, false, false)
        .map_err(|e| format!("signature does not verify: {e}"))
}
