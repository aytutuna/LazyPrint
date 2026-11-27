//! PWG raster (PWG 5102.4) writer.

use crate::sheet::{RasterError, transforms, write_lines};
use std::io::Write;

pub const HEADER_SIZE: usize = 1796;

/// One page of a PWG raster file. `page_width` and `page_height` are points, `media_name` the PWG
/// media name. `sheet_back` is the printer's sheet-back keyword when this page is the back of a
/// two-sided sheet, `None` for fronts and one-sided pages; `duplex` is set on both sides of a
/// two-sided sheet. `total_pages` is 0 when unknown.
#[derive(Clone, Debug, Default)]
pub struct PwgPageHeader {
    pub width: u32,
    pub height: u32,
    pub color: bool,
    pub dpi: u32,
    pub page_width: u32,
    pub page_height: u32,
    pub media_name: String,
    pub duplex: bool,
    pub sheet_back: Option<String>,
    pub quality: u32,
    pub total_pages: u32,
}

/// The most dots per inch taken from a printer's list; a printer saying more is not believed.
pub(crate) const MAX_DPI: i32 = 4800;

/// The resolution a job goes at: 300 dpi when listed, else the lowest square one, else 300.
pub fn pwg_resolution(supported: &[(i32, i32)]) -> i32 {
    if supported.contains(&(300, 300)) {
        return 300;
    }
    supported
        .iter()
        .filter(|(x, y)| x == y && (1..=MAX_DPI).contains(x))
        .map(|(x, _)| *x)
        .min()
        .unwrap_or(300)
}

pub fn pwg_file_header(out: &mut impl Write) -> std::io::Result<()> {
    out.write_all(b"RaS2")
}

/// Writes a page: its header, then the lines, `rows` giving line y of the sheet as drawn.
pub fn write_pwg_page(
    out: &mut impl Write,
    header: &PwgPageHeader,
    rows: impl FnMut(usize) -> Vec<u8>,
) -> Result<(), RasterError> {
    let (cross, feed) = transforms(header.sheet_back.as_deref());
    let bpp: u32 = if header.color { 3 } else { 1 };
    let mut h = vec![0u8; HEADER_SIZE];
    text(&mut h, 0, "PwgRaster");
    u32_at(&mut h, 272, header.duplex as u32);
    u32_at(&mut h, 276, header.dpi);
    u32_at(&mut h, 280, header.dpi);
    u32_at(&mut h, 352, header.page_width);
    u32_at(&mut h, 356, header.page_height);
    u32_at(&mut h, 372, header.width);
    u32_at(&mut h, 376, header.height);
    u32_at(&mut h, 384, 8);
    u32_at(&mut h, 388, bpp * 8);
    u32_at(&mut h, 392, header.width * bpp);
    u32_at(&mut h, 396, 0);
    u32_at(&mut h, 400, if header.color { 19 } else { 18 });
    u32_at(&mut h, 420, bpp);
    u32_at(&mut h, 452, header.total_pages);
    u32_at(&mut h, 456, cross as u32);
    u32_at(&mut h, 460, feed as u32);
    u32_at(&mut h, 484, header.quality);
    text(&mut h, 1732, &header.media_name);
    out.write_all(&h)?;
    write_lines(
        out,
        header.width as usize,
        header.height as usize,
        bpp as usize,
        rows,
        cross,
        feed,
    )
}

fn u32_at(buffer: &mut [u8], offset: usize, value: u32) {
    buffer[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
}

// At most 63 bytes, so the field stays terminated; anything outside ASCII is written as '?'.
fn text(buffer: &mut [u8], offset: usize, value: &str) {
    for (i, c) in value.chars().take(63).enumerate() {
        buffer[offset + i] = if c.is_ascii() { c as u8 } else { b'?' };
    }
}
