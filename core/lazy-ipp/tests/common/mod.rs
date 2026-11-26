use std::path::PathBuf;

pub const PRINTERS: [&str; 4] = [
    "hp-laserjet",
    "epson-ecotank",
    "brother-laser",
    "canon-pixma",
];

pub fn fixture(path: &str) -> Vec<u8> {
    let full = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata/ipp")
        .join(path);
    std::fs::read(&full).unwrap_or_else(|e| panic!("{}: {e}", full.display()))
}

pub fn printer(name: &str) -> Vec<u8> {
    fixture(&format!("printers/{name}.bin"))
}
