//! End to end: keygen, pack, manifest, verify, and the manifest checked with
//! `minisign-verify`, the verifier Stackmur itself uses.

use std::path::Path;
use std::process::{Command, Output};

fn pkgtool(args: &[&str], key: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_pkgtool"));
    cmd.args(args).env_remove("STACKMUR_SIGNING_KEY");
    if let Some(key) = key {
        cmd.env("STACKMUR_SIGNING_KEY", key);
    }
    cmd.output().unwrap()
}

fn ok(out: Output) -> String {
    assert!(
        out.status.success(),
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

fn s(p: &Path) -> &str {
    p.to_str().unwrap()
}

#[test]
fn keygen_pack_manifest_and_verify() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let key = t.join("signing.key");
    let out = ok(pkgtool(&["keygen", "--secret-key", s(&key)], None));
    let public = out
        .lines()
        .find_map(|l| l.strip_prefix("public key: "))
        .unwrap()
        .to_owned();
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        std::fs::metadata(&key).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // Never overwrites a key.
    assert!(
        !pkgtool(&["keygen", "--secret-key", s(&key)], None)
            .status
            .success()
    );
    let secret = std::fs::read_to_string(&key).unwrap();

    let pkg = t.join("php");
    std::fs::create_dir_all(pkg.join("bin")).unwrap();
    std::fs::write(pkg.join("bin/php-fpm"), b"fpm").unwrap();
    let frags = t.join("frags");
    for version in ["8.4.27", "8.4.28+1"] {
        ok(pkgtool(
            &[
                "pack",
                "--name",
                "php-8.4",
                "--version",
                version,
                "--license",
                "PHP-3.01",
                "--dir",
                s(&pkg),
                "--out",
                s(&frags),
            ],
            None,
        ));
    }
    assert!(frags.join("php-8.4-8.4.28_1-arm64.tar.zst").exists());

    let (m1json, m1sig, y) = (
        t.join("m1/manifest.json"),
        t.join("m1/manifest.json.minisig"),
        t.join("y"),
    );
    let base = "https://github.com/Murovix/stackmur-packages/releases/download/r1";
    let m1 = t.join("m1");
    ok(pkgtool(
        &[
            "manifest",
            "--fragments",
            s(&frags),
            "--base-url",
            base,
            "--serial",
            "10",
            "--out",
            s(&m1),
            "--expect-public-key",
            &public,
        ],
        Some(&secret),
    ));
    ok(pkgtool(
        &[
            "verify",
            "--manifest",
            s(&m1.join("manifest.json")),
            "--signature",
            s(&m1.join("manifest.json.minisig")),
            "--public-key",
            &public,
        ],
        None,
    ));

    // Stackmur's verifier accepts it.
    let bytes = std::fs::read(m1.join("manifest.json")).unwrap();
    let sig = std::fs::read_to_string(m1.join("manifest.json.minisig")).unwrap();
    let pk = minisign_verify::PublicKey::from_base64(&public).unwrap();
    pk.verify(
        &bytes,
        &minisign_verify::Signature::decode(&sig).unwrap(),
        false,
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["serial"], 10);
    assert_eq!(json["packages"].as_array().unwrap().len(), 2);
    assert_eq!(
        json["packages"][1]["url"],
        format!("{base}/php-8.4-8.4.28_1-arm64.tar.zst")
    );

    // A wrong expected key, an old serial and a missing key are refused.
    let wrong = pkgtool(
        &[
            "manifest",
            "--fragments",
            s(&frags),
            "--base-url",
            base,
            "--serial",
            "11",
            "--out",
            s(&t.join("x")),
            "--expect-public-key",
            "RWQ",
        ],
        Some(&secret),
    );
    assert!(!wrong.status.success());
    let previous = ["--previous", s(&m1json), "--previous-signature", s(&m1sig)];
    let mut args = vec![
        "manifest",
        "--fragments",
        s(&frags),
        "--base-url",
        base,
        "--serial",
        "10",
        "--out",
        s(&y),
    ];
    args.extend(previous);
    assert!(!pkgtool(&args, Some(&secret)).status.success());
    assert!(
        !pkgtool(
            &[
                "manifest",
                "--fragments",
                s(&frags),
                "--base-url",
                base,
                "--serial",
                "12",
                "--out",
                s(&t.join("z"))
            ],
            None
        )
        .status
        .success()
    );

    // Merging: a new release keeps the earlier builds listed.
    let frags2 = t.join("frags2");
    ok(pkgtool(
        &[
            "pack",
            "--name",
            "nginx",
            "--version",
            "1.30.6",
            "--license",
            "BSD-2-Clause",
            "--dir",
            s(&pkg),
            "--out",
            s(&frags2),
        ],
        None,
    ));
    let m2 = t.join("m2");
    let mut args = vec![
        "manifest",
        "--fragments",
        s(&frags2),
        "--serial",
        "11",
        "--out",
        s(&m2),
        "--base-url",
        "https://github.com/Murovix/stackmur-packages/releases/download/r2",
    ];
    args.extend(previous);
    ok(pkgtool(&args, Some(&secret)));
    let json: serde_json::Value =
        serde_json::from_slice(&std::fs::read(m2.join("manifest.json")).unwrap()).unwrap();
    let urls: Vec<&str> = json["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["url"].as_str().unwrap())
        .collect();
    assert_eq!(urls.len(), 3);
    assert!(urls[0].contains("/r2/nginx-1.30.6"), "{urls:?}");
    assert!(urls[1].contains("/r1/"), "{urls:?}");
}
