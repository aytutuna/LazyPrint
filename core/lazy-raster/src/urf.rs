//! Apple raster (UNIRAST) writer for AirPrint-only printers.

use crate::sheet::{RasterError, transforms, write_lines};
use std::io::Write;

pub const HEADER_SIZE: usize = 32;

/// One page of an Apple raster file. `sheet_back` is the PWG keyword the printer's DM token stands
/// for ([`urf_sheet_back`]) when this page is the back of a two-sided sheet, `None` otherwise.
#[derive(Clone, Debug, Default)]
pub struct UrfPageHeader {
    pub width: u32,
    pub height: u32,
    pub color: bool,
    pub dpi: u32,
    pub duplex: bool,
    pub sheet_back: Option<String>,
    pub quality: u8,
}

/// The resolution from the RS token ("RS300-600"): 300 when listed, else the lowest, else 300.
pub fn urf_resolution(urf_supported: &[String]) -> i32 {
    let dpis: Vec<i32> = urf_supported
        .iter()
        .filter_map(|token| token.strip_prefix("RS"))
        .flat_map(|rest| rest.split('-'))
        .filter_map(|part| part.parse::<i32>().ok())
        .filter(|dpi| (1..=crate::pwg::MAX_DPI).contains(dpi))
        .collect();
    if dpis.is_empty() || dpis.contains(&300) {
        300
    } else {
        *dpis.iter().min().unwrap()
    }
}

/// The sheet-back keyword for the printer's DM token: DM1 normal, DM2 flipped, DM3 rotated, DM4
/// manual-tumble. Normal when none is listed.
pub fn urf_sheet_back(urf_supported: &[String]) -> &'static str {
    urf_supported
        .iter()
        .find_map(|token| match token.as_str() {
            "DM1" => Some("normal"),
            "DM2" => Some("flipped"),
            "DM3" => Some("rotated"),
            "DM4" => Some("manual-tumble"),
            _ => None,
        })
        .unwrap_or("normal")
}

pub fn urf_file_header(out: &mut impl Write, page_count: u32) -> std::io::Result<()> {
    let mut h = [0u8; 12];
    h[..7].copy_from_slice(b"UNIRAST");
    h[8..].copy_from_slice(&page_count.to_be_bytes());
    out.write_all(&h)
}

/// Writes a page: its header, then the lines, `rows` giving line y of the sheet as drawn.
pub fn write_urf_page(
    out: &mut impl Write,
    header: &UrfPageHeader,
    rows: impl FnMut(usize) -> Vec<u8>,
) -> Result<(), RasterError> {
    let (cross, feed) = transforms(header.sheet_back.as_deref());
    let bpp: usize = if header.color { 3 } else { 1 };
    let mut h = [0u8; HEADER_SIZE];
    h[0] = (bpp * 8) as u8;
    h[1] = header.color as u8;
    h[2] = if header.duplex { 3 } else { 1 };
    h[3] = header.quality;
    h[12..16].copy_from_slice(&header.width.to_be_bytes());
    h[16..20].copy_from_slice(&header.height.to_be_bytes());
    h[20..24].copy_from_slice(&header.dpi.to_be_bytes());
    out.write_all(&h)?;
    write_lines(
        out,
        header.width as usize,
        header.height as usize,
        bpp,
        rows,
        cross,
        feed,
    )
}
