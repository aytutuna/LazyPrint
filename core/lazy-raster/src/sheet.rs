//! The line coding PWG raster and Apple raster share.

use std::io::{self, Write};

#[derive(Debug)]
pub enum RasterError {
    /// A row the caller supplied is not `width * bytes per pixel` long.
    BadLine {
        line: usize,
        length: usize,
        expected: usize,
    },
    Io(io::Error),
}

impl std::fmt::Display for RasterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RasterError::BadLine {
                line,
                length,
                expected,
            } => write!(f, "line {line} has {length} bytes, expected {expected}"),
            RasterError::Io(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for RasterError {}

impl From<io::Error> for RasterError {
    fn from(e: io::Error) -> Self {
        RasterError::Io(e)
    }
}

/// The (cross-feed, feed) transforms a sheet-back keyword stands for. Unknown keywords are normal.
pub(crate) fn transforms(sheet_back: Option<&str>) -> (i32, i32) {
    match sheet_back {
        Some("rotated") => (-1, -1),
        Some("flipped") => (1, -1),
        _ => (1, 1),
    }
}

/// Writes the lines of one page. `row` returns line y of the sheet as drawn (gray bytes or RGB
/// triples); cross -1 writes each line right to left, feed -1 writes the lines bottom to top.
pub(crate) fn write_lines(
    out: &mut impl Write,
    width: usize,
    height: usize,
    bpp: usize,
    mut row: impl FnMut(usize) -> Vec<u8>,
    cross: i32,
    feed: i32,
) -> Result<(), RasterError> {
    let mut previous: Option<Vec<u8>> = None;
    let mut repeats = 0;
    for i in 0..height {
        let mut line = row(if feed < 0 { height - 1 - i } else { i });
        if line.len() != width * bpp {
            return Err(RasterError::BadLine {
                line: i,
                length: line.len(),
                expected: width * bpp,
            });
        }
        if cross < 0 {
            line = reversed(&line, bpp);
        }
        if let Some(prev) = &previous {
            if repeats < 256 && *prev == line {
                repeats += 1;
                continue;
            }
            write_line(out, prev, bpp, repeats)?;
        }
        previous = Some(line);
        repeats = 1;
    }
    if let Some(prev) = &previous {
        write_line(out, prev, bpp, repeats)?;
    }
    Ok(())
}

fn reversed(line: &[u8], bpp: usize) -> Vec<u8> {
    line.chunks_exact(bpp).rev().flatten().copied().collect()
}

fn write_line(out: &mut impl Write, line: &[u8], bpp: usize, repeats: usize) -> io::Result<()> {
    out.write_all(&[(repeats - 1) as u8])?;
    let pixels = line.len() / bpp;
    let same = |a: usize, b: usize| line[a * bpp..(a + 1) * bpp] == line[b * bpp..(b + 1) * bpp];
    let mut i = 0;
    while i < pixels {
        let mut run = 1;
        while i + run < pixels && run < 128 && same(i, i + run) {
            run += 1;
        }
        if run >= 2 {
            out.write_all(&[(run - 1) as u8])?;
            out.write_all(&line[i * bpp..(i + 1) * bpp])?;
            i += run;
            continue;
        }
        let mut literal = 1;
        while i + literal < pixels
            && literal < 128
            && !(i + literal + 1 < pixels && same(i + literal, i + literal + 1))
        {
            literal += 1;
        }
        let count = if literal == 1 {
            0
        } else {
            (257 - literal) as u8
        };
        out.write_all(&[count])?;
        out.write_all(&line[i * bpp..(i + literal) * bpp])?;
        i += literal;
    }
    Ok(())
}
