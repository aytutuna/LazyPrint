//! Reads the shared test vectors in `core/testdata`, refusing a file whose hash is not in SHA256SUMS.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fmt::Write;
use std::path::PathBuf;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../testdata")
}

/// The bytes of `name` (a path below `testdata`), after checking them against SHA256SUMS.
pub fn bytes(name: &str) -> Vec<u8> {
    let data = std::fs::read(dir().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    let digest = Sha256::digest(&data)
        .iter()
        .fold(String::new(), |mut s, b| {
            write!(s, "{b:02x}").unwrap();
            s
        });
    let sums = std::fs::read_to_string(dir().join("SHA256SUMS")).unwrap();
    let listed = sums.lines().find_map(|line| {
        let (hash, file) = line.split_once(' ')?;
        (file.trim_start_matches('*') == name).then_some(hash)
    });
    assert_eq!(
        listed,
        Some(digest.as_str()),
        "{name} does not match SHA256SUMS"
    );
    data
}

/// A file holding one JSON document.
pub fn json(name: &str) -> Value {
    serde_json::from_slice(&bytes(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// A file holding one JSON document per line.
pub fn json_lines(name: &str) -> Vec<Value> {
    let text = String::from_utf8(bytes(name)).unwrap();
    text.lines()
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}
