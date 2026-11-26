// Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

//! The paper size catalogue and the rules for reading, naming and matching sizes. Sizes are in points.

mod catalogue;
mod media;
mod sizes;

pub use catalogue::ALL;
pub use media::*;
pub use sizes::*;

/// Where a size belongs in a list of sizes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaperGroup {
    Auto,
    Us,
    IsoA,
    IsoB,
    JisB,
    Photo,
    Card,
    Envelope,
}

/// A paper size of the catalogue. Automatic comes first: it is the default and the fallback for a size a newer
/// version adds, and it means the printer's own paper. `raw_value` is what a setting stores ("a4", "b5Jis",
/// "idCard"); `pwg` is its PWG 5101.1 self-describing name, which also gives the size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaperSize {
    pub raw_value: &'static str,
    pub pwg: &'static str,
    pub label: &'static str,
    pub group: PaperGroup,
    /// The Windows PrintTicket PageMediaSizeName of the size, without a prefix; none where Windows has none.
    pub psk: Option<&'static str>,
}

impl PaperSize {
    pub fn is_auto(&self) -> bool {
        self.raw_value == "auto"
    }

    /// The dimensions as people know them, from the PWG name: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it
    /// prints on.
    pub fn detail(&self) -> String {
        if self.is_auto() {
            return "The paper in the printer".into();
        }
        let tail = self.pwg.rsplit('_').next().unwrap_or("");
        tail.replace('x', " × ")
            .replace("mm", " mm")
            .replace("in", " in")
    }
}
