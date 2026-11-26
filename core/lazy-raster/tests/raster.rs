//! The same cases as the C# and Swift PwgRasterTests and UrfRasterTests; the golden files are
//! the ones those tests compare against.

use lazy_raster::*;
use std::path::PathBuf;

const W: usize = 64;
const H: usize = 40;

fn golden(name: &str) -> Vec<u8> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../testdata/ipp/raster")
        .join(name);
    std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn u32_at(data: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes(data[offset..offset + 4].try_into().unwrap())
}

/// Gradient, stripes, repeated lines, a white band and a diagonal.
fn pattern(width: usize, height: usize, color: bool, seed: u8) -> Vec<Vec<u8>> {
    let bpp = if color { 3 } else { 1 };
    (0..height)
        .map(|y| {
            let mut row = vec![0u8; width * bpp];
            for x in 0..width {
                let gray = match y {
                    0..10 => ((x * 4) as u8).wrapping_add(seed),
                    10..20 => (if x / 8 % 2 == 0 { 30u8 } else { 220 }).wrapping_add(seed),
                    20..28 => 255,
                    _ => ((x + y * 3) as u8).wrapping_add(seed),
                };
                for c in 0..bpp {
                    row[x * bpp + c] = if c == 0 {
                        gray
                    } else {
                        gray ^ (c as u8 * 0x55)
                    };
                }
            }
            row
        })
        .collect()
}

fn reverse_pixels(row: &[u8], bpp: usize) -> Vec<u8> {
    row.chunks_exact(bpp).rev().flatten().copied().collect()
}

struct Page {
    header: Vec<u8>,
    width: usize,
    bpp: usize,
    pixels: Vec<u8>,
}

impl Page {
    fn line(&self, y: usize) -> &[u8] {
        let n = self.width * self.bpp;
        &self.pixels[y * n..(y + 1) * n]
    }
}

// A reader written apart from the writers, so the tests do not share their mistakes.
fn lines(data: &[u8], pos: &mut usize, width: usize, height: usize, bpp: usize) -> Vec<u8> {
    let mut pixels = vec![0u8; width * height * bpp];
    let mut y = 0;
    while y < height {
        let repeat = data[*pos] as usize + 1;
        *pos += 1;
        let mut line = vec![0u8; width * bpp];
        let mut x = 0;
        while x < width {
            let n = data[*pos] as usize;
            *pos += 1;
            if n < 128 {
                for k in 0..=n {
                    line[(x + k) * bpp..(x + k + 1) * bpp].copy_from_slice(&data[*pos..*pos + bpp]);
                }
                *pos += bpp;
                x += n + 1;
            } else if n == 128 {
                line[x * bpp..].fill(0xFF);
                x = width;
            } else {
                let count = 257 - n;
                line[x * bpp..(x + count) * bpp].copy_from_slice(&data[*pos..*pos + count * bpp]);
                *pos += count * bpp;
                x += count;
            }
        }
        assert_eq!(x, width);
        assert!(y + repeat <= height, "line repeat runs past the page");
        for k in 0..repeat {
            pixels[(y + k) * width * bpp..(y + k + 1) * width * bpp].copy_from_slice(&line);
        }
        y += repeat;
    }
    pixels
}

fn read_pwg(data: &[u8]) -> Vec<Page> {
    assert_eq!(&data[..4], b"RaS2");
    let mut pages = vec![];
    let mut pos = 4;
    while pos < data.len() {
        let header = data[pos..pos + 1796].to_vec();
        pos += 1796;
        let width = u32_at(&header, 372) as usize;
        let height = u32_at(&header, 376) as usize;
        let bpp = u32_at(&header, 388) as usize / 8;
        let pixels = lines(data, &mut pos, width, height, bpp);
        pages.push(Page {
            header,
            width,
            bpp,
            pixels,
        });
    }
    pages
}

fn read_urf(data: &[u8]) -> Vec<Page> {
    assert_eq!(&data[..8], b"UNIRAST\0");
    let count = u32_at(data, 8);
    let mut pages = vec![];
    let mut pos = 12;
    for _ in 0..count {
        let header = data[pos..pos + 32].to_vec();
        pos += 32;
        let width = u32_at(&header, 12) as usize;
        let height = u32_at(&header, 16) as usize;
        let bpp = header[0] as usize / 8;
        let pixels = lines(data, &mut pos, width, height, bpp);
        pages.push(Page {
            header,
            width,
            bpp,
            pixels,
        });
    }
    assert_eq!(pos, data.len());
    pages
}

fn pwg_header(color: bool, duplex: bool, back: Option<&str>, total: u32) -> PwgPageHeader {
    PwgPageHeader {
        width: W as u32,
        height: H as u32,
        color,
        dpi: 300,
        page_width: 612,
        page_height: 792,
        media_name: "na_letter_8.5x11in".into(),
        duplex,
        sheet_back: back.map(String::from),
        quality: 4,
        total_pages: total,
    }
}

fn write_pwg(pages: &[(PwgPageHeader, Vec<Vec<u8>>)]) -> Vec<u8> {
    let mut out = vec![];
    pwg_file_header(&mut out).unwrap();
    for (header, rows) in pages {
        write_pwg_page(&mut out, header, |y| rows[y].clone()).unwrap();
    }
    out
}

fn urf_header(color: bool, duplex: bool, back: Option<&str>) -> UrfPageHeader {
    UrfPageHeader {
        width: W as u32,
        height: H as u32,
        color,
        dpi: 300,
        duplex,
        sheet_back: back.map(String::from),
        quality: 4,
    }
}

fn write_urf(pages: &[(UrfPageHeader, Vec<Vec<u8>>)]) -> Vec<u8> {
    let mut out = vec![];
    urf_file_header(&mut out, pages.len() as u32).unwrap();
    for (header, rows) in pages {
        write_urf_page(&mut out, header, |y| rows[y].clone()).unwrap();
    }
    out
}

fn flat(rows: &[Vec<u8>]) -> Vec<u8> {
    rows.concat()
}

fn expected_back(
    rows: &[Vec<u8>],
    bpp: usize,
    reverse_pixels_too: bool,
    reverse_lines: bool,
) -> Vec<u8> {
    let mut rows = rows.to_vec();
    if reverse_lines {
        rows.reverse();
    }
    if reverse_pixels_too {
        rows = rows.iter().map(|r| reverse_pixels(r, bpp)).collect();
    }
    flat(&rows)
}

fn text(data: &[u8], offset: usize) -> String {
    let field = &data[offset..offset + 64];
    let end = field.iter().position(|b| *b == 0).unwrap_or(64);
    String::from_utf8(field[..end].to_vec()).unwrap()
}

#[test]
fn pwg_gray_header_fields_sit_at_their_offsets() {
    let data = write_pwg(&[(pwg_header(false, false, None, 1), pattern(W, H, false, 0))]);
    let pages = read_pwg(&data);
    assert_eq!(pages.len(), 1);
    let h = &pages[0].header;
    assert_eq!(h.len(), 1796);
    assert_eq!(text(h, 0), "PwgRaster");
    let expected = [
        (272, 0),
        (276, 300),
        (280, 300),
        (352, 612),
        (356, 792),
        (368, 0),
        (372, 64),
        (376, 40),
        (384, 8),
        (388, 8),
        (392, 64),
        (396, 0),
        (400, 18),
        (420, 1),
        (452, 1),
        (456, 1),
        (460, 1),
        (484, 4),
    ];
    for (offset, value) in expected {
        assert_eq!(u32_at(h, offset), value, "offset {offset}");
    }
    assert_eq!(text(h, 1732), "na_letter_8.5x11in");
}

#[test]
fn pwg_color_header_is_srgb24() {
    let data = write_pwg(&[(pwg_header(true, false, None, 1), pattern(W, H, true, 0))]);
    let h = &read_pwg(&data)[0].header;
    assert_eq!(u32_at(h, 388), 24);
    assert_eq!(u32_at(h, 392), 192);
    assert_eq!(u32_at(h, 400), 19);
    assert_eq!(u32_at(h, 420), 3);
}

#[test]
fn pwg_pixels_round_trip() {
    for color in [false, true] {
        let rows = pattern(W, H, color, 0);
        let data = write_pwg(&[(pwg_header(color, false, None, 1), rows.clone())]);
        assert_eq!(read_pwg(&data)[0].pixels, flat(&rows));
    }
}

#[test]
fn pwg_back_is_reordered_for_the_sheet_back_keyword() {
    for (keyword, cross, feed) in [
        ("normal", 1, 1),
        ("manual-tumble", 1, 1),
        ("rotated", -1, -1),
        ("flipped", 1, -1),
    ] {
        for color in [false, true] {
            let bpp = if color { 3 } else { 1 };
            let rows = pattern(W, H, color, 1);
            let data = write_pwg(&[(pwg_header(color, true, Some(keyword), 2), rows.clone())]);
            let page = &read_pwg(&data)[0];
            assert_eq!(u32_at(&page.header, 272), 1);
            assert_eq!(u32_at(&page.header, 456), cross as u32);
            assert_eq!(u32_at(&page.header, 460), feed as u32);
            assert_eq!(page.pixels, expected_back(&rows, bpp, cross < 0, feed < 0));
        }
    }
}

#[test]
fn pwg_a_front_and_a_one_sided_page_have_no_transform() {
    let rows = pattern(W, H, false, 0);
    let data = write_pwg(&[(pwg_header(false, true, None, 2), rows.clone())]);
    let page = &read_pwg(&data)[0];
    assert_eq!(u32_at(&page.header, 272), 1);
    assert_eq!(u32_at(&page.header, 456), 1);
    assert_eq!(u32_at(&page.header, 460), 1);
    assert_eq!(page.pixels, flat(&rows));
}

#[test]
fn pwg_long_runs_and_repeats_are_split() {
    let (width, height) = (300, 600);
    let white = vec![255u8; width];
    let odd: Vec<u8> = (0..width).map(|x| (x * 7) as u8).collect();
    let header = PwgPageHeader {
        width: width as u32,
        height: height as u32,
        dpi: 300,
        page_width: 72,
        page_height: 144,
        media_name: "custom".into(),
        ..Default::default()
    };
    let mut out = vec![];
    pwg_file_header(&mut out).unwrap();
    write_pwg_page(&mut out, &header, |y| {
        if y < 400 { white.clone() } else { odd.clone() }
    })
    .unwrap();
    let page = &read_pwg(&out)[0];
    for y in 0..height {
        assert_eq!(page.line(y), if y < 400 { &white } else { &odd });
    }
    // 400 white lines are two repeat groups of one short line each, the 200 odd ones one group of a literal line
    assert!(out.len() < 4 + 1796 + 2 * 10 + 330);
}

#[test]
fn a_row_of_the_wrong_length_is_rejected() {
    let mut out = vec![];
    let error = write_pwg_page(&mut out, &pwg_header(false, false, None, 1), |_| {
        vec![0; W - 1]
    })
    .unwrap_err();
    assert!(matches!(
        error,
        RasterError::BadLine { line: 0, length, expected } if length == W - 1 && expected == W
    ));
}

#[test]
fn pwg_resolution_is_300_when_listed_else_the_lowest() {
    assert_eq!(pwg_resolution(&[(600, 600), (300, 300)]), 300);
    assert_eq!(pwg_resolution(&[(600, 600), (150, 150)]), 150);
    assert_eq!(pwg_resolution(&[(600, 300)]), 300);
    assert_eq!(pwg_resolution(&[]), 300);
}

#[test]
fn pwg_goldens() {
    let gray = write_pwg(&[(pwg_header(false, false, None, 1), pattern(W, H, false, 0))]);
    assert_eq!(gray, golden("pwg-gray.pwg"));
    let rgb = write_pwg(&[(pwg_header(true, false, None, 1), pattern(W, H, true, 0))]);
    assert_eq!(rgb, golden("pwg-rgb.pwg"));
    for keyword in ["normal", "manual-tumble", "rotated", "flipped"] {
        let data = write_pwg(&[
            (pwg_header(true, true, None, 2), pattern(W, H, true, 0)),
            (
                pwg_header(true, true, Some(keyword), 2),
                pattern(W, H, true, 1),
            ),
        ]);
        assert_eq!(
            data,
            golden(&format!("pwg-two-sided-{keyword}.pwg")),
            "{keyword}"
        );
    }
}

#[test]
fn urf_header_fields_sit_at_their_offsets() {
    for (color, bits, space) in [(false, 8, 0), (true, 24, 1)] {
        let data = write_urf(&[(urf_header(color, true, None), pattern(W, H, color, 0))]);
        assert_eq!(&data[..8], b"UNIRAST\0");
        assert_eq!(u32_at(&data, 8), 1);
        let h = &read_urf(&data)[0].header;
        assert_eq!(h.len(), 32);
        assert_eq!((h[0], h[1], h[2], h[3]), (bits, space, 3, 4));
        for (offset, value) in [
            (4, 0),
            (8, 0),
            (12, 64),
            (16, 40),
            (20, 300),
            (24, 0),
            (28, 0),
        ] {
            assert_eq!(u32_at(h, offset), value, "offset {offset}");
        }
    }
}

#[test]
fn urf_one_sided_page_says_so() {
    let data = write_urf(&[(urf_header(false, false, None), pattern(W, H, false, 0))]);
    assert_eq!(read_urf(&data)[0].header[2], 1);
}

#[test]
fn urf_pixels_round_trip() {
    for color in [false, true] {
        let rows = pattern(W, H, color, 0);
        let data = write_urf(&[(urf_header(color, false, None), rows.clone())]);
        assert_eq!(read_urf(&data)[0].pixels, flat(&rows));
    }
}

#[test]
fn urf_back_is_reordered_for_the_sheet_back_keyword() {
    for (keyword, pixels, lines) in [
        ("normal", false, false),
        ("manual-tumble", false, false),
        ("rotated", true, true),
        ("flipped", false, true),
    ] {
        for color in [false, true] {
            let rows = pattern(W, H, color, 1);
            let data = write_urf(&[(urf_header(color, true, Some(keyword)), rows.clone())]);
            let bpp = if color { 3 } else { 1 };
            assert_eq!(
                read_urf(&data)[0].pixels,
                expected_back(&rows, bpp, pixels, lines)
            );
        }
    }
}

#[test]
fn urf_long_runs_and_repeats_are_split() {
    let (width, height) = (300, 600);
    let white = vec![255u8; width * 3];
    let odd: Vec<u8> = (0..width * 3).map(|i| (i * 7) as u8).collect();
    let header = UrfPageHeader {
        width: width as u32,
        height: height as u32,
        color: true,
        dpi: 300,
        ..Default::default()
    };
    let mut out = vec![];
    urf_file_header(&mut out, 1).unwrap();
    write_urf_page(&mut out, &header, |y| {
        if y < 400 { white.clone() } else { odd.clone() }
    })
    .unwrap();
    let page = &read_urf(&out)[0];
    for y in 0..height {
        assert_eq!(page.line(y), if y < 400 { &white } else { &odd });
    }
}

#[test]
fn urf_tokens_choose_resolution_and_sheet_back() {
    let tokens = |t: &[&str]| t.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        urf_resolution(&tokens(&["CP1", "RS300-600", "W8", "SRGB24", "DM1"])),
        300
    );
    assert_eq!(urf_resolution(&tokens(&["RS600"])), 600);
    assert_eq!(urf_resolution(&tokens(&["W8"])), 300);
    assert_eq!(urf_sheet_back(&tokens(&["DM1"])), "normal");
    assert_eq!(urf_sheet_back(&tokens(&["SRGB24", "DM2"])), "flipped");
    assert_eq!(urf_sheet_back(&tokens(&["DM3"])), "rotated");
    assert_eq!(urf_sheet_back(&tokens(&["DM4"])), "manual-tumble");
    assert_eq!(urf_sheet_back(&[]), "normal");
}

#[test]
fn urf_goldens() {
    let gray = write_urf(&[(urf_header(false, false, None), pattern(W, H, false, 0))]);
    assert_eq!(gray, golden("urf-gray.urf"));
    let rgb = write_urf(&[(urf_header(true, false, None), pattern(W, H, true, 0))]);
    assert_eq!(rgb, golden("urf-rgb.urf"));
    for (token, keyword) in [
        ("DM1", "normal"),
        ("DM2", "flipped"),
        ("DM3", "rotated"),
        ("DM4", "manual-tumble"),
    ] {
        assert_eq!(urf_sheet_back(&[token.to_string()]), keyword);
        let data = write_urf(&[
            (urf_header(true, true, None), pattern(W, H, true, 0)),
            (
                urf_header(true, true, Some(keyword)),
                pattern(W, H, true, 1),
            ),
        ]);
        assert_eq!(
            data,
            golden(&format!("urf-two-sided-{}.urf", token.to_lowercase())),
            "{token}"
        );
    }
}
