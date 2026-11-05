//! The manifest format of `stackmur-packages` (Stackmur repository,
//! `crates/stackmur-packages/src/manifest.rs`). Field names, validation and
//! version order are copied from there and must stay identical.

use serde::{Deserialize, Serialize};

pub const SCHEMA: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    pub serial: u64,
    pub packages: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub name: String,
    pub version: String,
    pub arch: Arch,
    pub min_macos: String,
    pub url: String,
    pub sha256: String,
    pub size: u64,
    pub license: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Arch {
    Arm64,
}

/// What `pkgtool pack` writes next to an archive; the URL is added when the
/// release location is known.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fragment {
    pub name: String,
    pub version: String,
    pub min_macos: String,
    pub license: String,
    pub file: String,
    pub sha256: String,
    pub size: u64,
}

impl Fragment {
    pub fn into_entry(self, base_url: &str) -> Entry {
        Entry {
            url: format!("{base_url}/{}", self.file),
            name: self.name,
            version: self.version,
            arch: Arch::Arm64,
            min_macos: self.min_macos,
            sha256: self.sha256,
            size: self.size,
            license: self.license,
        }
    }
}

impl Manifest {
    /// The checks `stackmur-packages` applies, so a manifest that passes here
    /// is accepted by Stackmur.
    pub fn validate(&self) -> Result<(), String> {
        let mut seen = std::collections::BTreeSet::new();
        for e in &self.packages {
            validate_name(&e.name)?;
            validate_version(&e.version)?;
            let what = format!("{} {}", e.name, e.version);
            if e.sha256.len() != 64
                || !e
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(format!("{what}: bad sha256"));
            }
            if e.size == 0 {
                return Err(format!("{what}: size is zero"));
            }
            if !e.url.starts_with("https://") || !e.url.ends_with(".tar.zst") {
                return Err(format!("{what}: url must be https://….tar.zst"));
            }
            if e.min_macos.is_empty()
                || !e.min_macos.bytes().all(|b| b.is_ascii_digit() || b == b'.')
            {
                return Err(format!("{what}: bad min_macos"));
            }
            if !seen.insert((&e.name, &e.version)) {
                return Err(format!("{what} is listed twice"));
            }
        }
        Ok(())
    }
}

/// Package names: `[a-z0-9][a-z0-9.-]{0,63}`.
pub fn validate_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty()
        && name.len() <= 64
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.')
        && !name.contains("..");
    ok.then_some(())
        .ok_or_else(|| format!("invalid package name {name:?}"))
}

/// Versions: digits and dots, optional `+build` of `[0-9A-Za-z.]`.
pub fn validate_version(version: &str) -> Result<(), String> {
    let (core, build) = version.split_once('+').unwrap_or((version, ""));
    let core_ok = !core.is_empty()
        && core
            .split('.')
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    let build_ok = build
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.')
        && (build.is_empty() == !version.contains('+'));
    (core_ok && build_ok && version.len() <= 64)
        .then_some(())
        .ok_or_else(|| format!("invalid package version {version:?}"))
}

/// Numeric order of `1.2.10` > `1.2.9`; a build suffix breaks ties.
pub fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let parts = |v: &str| -> (Vec<u64>, String) {
        let (core, build) = v.split_once('+').unwrap_or((v, ""));
        (
            core.split('.').map(|p| p.parse().unwrap_or(0)).collect(),
            build.to_owned(),
        )
    };
    let (a, a_build) = parts(a);
    let (b, b_build) = parts(b);
    a.cmp(&b).then_with(|| {
        let num = |s: &str| s.parse::<u64>().ok();
        match (num(&a_build), num(&b_build)) {
            (Some(x), Some(y)) => x.cmp(&y),
            _ => a_build.cmp(&b_build),
        }
    })
}
