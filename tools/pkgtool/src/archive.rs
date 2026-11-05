//! Reproducible `tar.zst` archives in the shape Stackmur's unpacker accepts:
//! directories, regular files and relative symlinks that stay inside the
//! package. Owner and times are zeroed, entries sorted, modes normalised to
//! 0755 (anything executable) or 0644.

use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

type Result<T> = std::result::Result<T, String>;

/// zstd level: small downloads matter more than build time.
const LEVEL: i32 = 19;

/// Writes `dir` as `out` and returns its SHA-256 and size.
pub fn pack(dir: &Path, out: &Path) -> Result<(String, u64)> {
    let mut entries = Vec::new();
    walk(dir, Path::new(""), &mut entries)?;
    if entries.is_empty() {
        return Err(format!("{} is empty", dir.display()));
    }
    let file = File::create(out).map_err(|e| format!("{}: {e}", out.display()))?;
    let hashing = HashingWriter {
        inner: BufWriter::new(file),
        hash: Sha256::new(),
        size: 0,
    };
    let mut encoder = zstd::Encoder::new(hashing, LEVEL).map_err(|e| e.to_string())?;
    encoder.include_checksum(true).map_err(|e| e.to_string())?;
    let mut builder = tar::Builder::new(encoder);
    builder.mode(tar::HeaderMode::Deterministic);
    for relative in entries {
        let path = dir.join(&relative);
        let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        let mut header = tar::Header::new_gnu();
        header.set_uid(0);
        header.set_gid(0);
        header.set_mtime(0);
        let kind = meta.file_type();
        if kind.is_dir() {
            header.set_entry_type(tar::EntryType::Directory);
            header.set_mode(0o755);
            header.set_size(0);
            builder
                .append_data(&mut header, &relative, io::empty())
                .map_err(|e| e.to_string())?;
        } else if kind.is_file() {
            let exec = meta.permissions().mode() & 0o111 != 0;
            header.set_entry_type(tar::EntryType::Regular);
            header.set_mode(if exec { 0o755 } else { 0o644 });
            header.set_size(meta.len());
            let data = File::open(&path).map_err(|e| e.to_string())?;
            builder
                .append_data(&mut header, &relative, data)
                .map_err(|e| e.to_string())?;
        } else if kind.is_symlink() {
            let target = fs::read_link(&path).map_err(|e| e.to_string())?;
            let base = relative.parent().unwrap_or(Path::new(""));
            if target.is_absolute() || !stays_inside(&base.join(&target)) {
                return Err(format!(
                    "symlink {} -> {} leaves the package",
                    relative.display(),
                    target.display()
                ));
            }
            header.set_entry_type(tar::EntryType::Symlink);
            header.set_mode(0o777);
            header.set_size(0);
            builder
                .append_link(&mut header, &relative, &target)
                .map_err(|e| e.to_string())?;
        } else {
            return Err(format!(
                "{} is not a file, directory or symlink",
                relative.display()
            ));
        }
    }
    let encoder = builder.into_inner().map_err(|e| e.to_string())?;
    let mut hashing = encoder.finish().map_err(|e| e.to_string())?;
    hashing.inner.flush().map_err(|e| e.to_string())?;
    hashing
        .inner
        .get_ref()
        .sync_all()
        .map_err(|e| e.to_string())?;
    let sha: String = hashing
        .hash
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    Ok((sha, hashing.size))
}

/// Sorted, depth-first, parents before children.
fn walk(root: &Path, relative: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let dir = root.join(relative);
    let mut names: Vec<_> = fs::read_dir(&dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .map(|e| e.map(|e| e.file_name()))
        .collect::<io::Result<_>>()
        .map_err(|e| e.to_string())?;
    names.sort();
    for name in names {
        let child = relative.join(&name);
        out.push(child.clone());
        if fs::symlink_metadata(root.join(&child))
            .map_err(|e| e.to_string())?
            .is_dir()
        {
            walk(root, &child, out)?;
        }
    }
    Ok(())
}

fn stays_inside(path: &Path) -> bool {
    let mut depth = 0usize;
    for c in path.components() {
        match c {
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::ParentDir => {
                if depth == 0 {
                    return false;
                }
                depth -= 1;
            }
            Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    true
}

struct HashingWriter<W: Write> {
    inner: W,
    hash: Sha256,
    size: u64,
}

impl<W: Write> Write for HashingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(buf)?;
        self.hash.update(&buf[..n]);
        self.size += n as u64;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn packs_reproducibly_and_round_trips() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("bin")).unwrap();
        fs::write(src.join("bin/php-fpm"), b"fpm").unwrap();
        fs::set_permissions(src.join("bin/php-fpm"), fs::Permissions::from_mode(0o4775)).unwrap();
        fs::write(src.join("LICENSE"), b"license").unwrap();
        std::os::unix::fs::symlink("php-fpm", src.join("bin/php-cgi")).unwrap();

        let a = tmp.path().join("a.tar.zst");
        let b = tmp.path().join("b.tar.zst");
        let (sha_a, size_a) = pack(&src, &a).unwrap();
        // Different times on disk, same archive.
        fs::write(src.join("LICENSE"), b"license").unwrap();
        let (sha_b, _) = pack(&src, &b).unwrap();
        assert_eq!(sha_a, sha_b);
        assert_eq!(size_a, fs::metadata(&a).unwrap().len());
        let expected: String = Sha256::digest(fs::read(&a).unwrap())
            .iter()
            .map(|x| format!("{x:02x}"))
            .collect();
        assert_eq!(sha_a, expected);

        // Read back with the decoder Stackmur uses.
        let decoder = ruzstd::decoding::StreamingDecoder::new(File::open(&a).unwrap()).unwrap();
        let mut tar = tar::Archive::new(decoder);
        let mut seen = Vec::new();
        for entry in tar.entries().unwrap() {
            let mut entry = entry.unwrap();
            let path = entry.path().unwrap().into_owned();
            let header = entry.header();
            assert_eq!(header.uid().unwrap(), 0);
            assert_eq!(header.mtime().unwrap(), 0);
            let mode = header.mode().unwrap();
            let kind = header.entry_type();
            let mut body = Vec::new();
            entry.read_to_end(&mut body).unwrap();
            seen.push((path.display().to_string(), kind, mode));
        }
        assert_eq!(
            seen,
            vec![
                ("LICENSE".into(), tar::EntryType::Regular, 0o644),
                ("bin".into(), tar::EntryType::Directory, 0o755),
                ("bin/php-cgi".into(), tar::EntryType::Symlink, 0o777),
                ("bin/php-fpm".into(), tar::EntryType::Regular, 0o755),
            ]
        );
    }

    #[test]
    fn refuses_links_that_leave_the_package() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(&src).unwrap();
        std::os::unix::fs::symlink("../../etc", src.join("x")).unwrap();
        assert!(pack(&src, &tmp.path().join("o.tar.zst")).is_err());
        fs::remove_file(src.join("x")).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", src.join("x")).unwrap();
        assert!(pack(&src, &tmp.path().join("o.tar.zst")).is_err());
    }
}
