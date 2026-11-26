//! Which document format a job goes in.

use crate::status;

pub const PDF: &str = "application/pdf";
pub const PWG_RASTER: &str = "image/pwg-raster";
pub const URF: &str = "image/urf";
pub const JPEG: &str = "image/jpeg";

/// What is being printed, as far as the format is concerned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentKind {
    /// A PDF printed as it is.
    Pdf { encrypted: bool },
    /// One photo printed whole on paper of its own size.
    Photo,
    /// Sheets drawn by Lazy Print.
    Imposed,
}

/// The format a job goes in. A PDF goes as itself only when it is printed as it is (one page per
/// side, every page once in order, fit or shrink to fit, no booklet, no manual duplex), and not
/// encrypted. One photo goes as JPEG only when it is printed whole on paper of its own size.
/// Everything else is sheets drawn by Lazy Print: PDF where the platform can write one
/// (`can_write_pdf`), else PWG raster, then URF. `None` when the printer takes none of them.
pub fn choose(
    supported: &[String],
    kind: DocumentKind,
    can_write_pdf: bool,
) -> Option<&'static str> {
    let takes = |format: &str| supported.iter().any(|s| s.eq_ignore_ascii_case(format));
    if kind == (DocumentKind::Pdf { encrypted: false }) && takes(PDF) {
        return Some(PDF);
    }
    if kind == DocumentKind::Photo && takes(JPEG) {
        return Some(JPEG);
    }
    if can_write_pdf && takes(PDF) {
        return Some(PDF);
    }
    if takes(PWG_RASTER) {
        return Some(PWG_RASTER);
    }
    if takes(URF) {
        return Some(URF);
    }
    None
}

/// A job refused with document-format-not-supported, document-format-error or
/// document-unprintable-error is sent once more as raster.
pub fn retries_as_raster(status: u16) -> bool {
    matches!(
        status,
        status::CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED
            | status::CLIENT_ERROR_DOCUMENT_FORMAT_ERROR
            | status::CLIENT_ERROR_DOCUMENT_UNPRINTABLE_ERROR
    )
}
