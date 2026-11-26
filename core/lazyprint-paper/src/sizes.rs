use crate::{ALL, PaperGroup, PaperSize};
use lazyprint_layout::LayoutSize;

/// A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.
pub const FIT_TOLERANCE: f64 = 0.05 * 72.0;

/// Countries and territories that use US Letter (the ICU paper-size list): everywhere else uses A4.
pub const LETTER_REGIONS: [&str; 14] = [
    "US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE",
];

/// The id of the picker entry that stands for a size typed in; never stored.
pub const CUSTOM_ID: &str = "custom";

const LISTED_PREFIX: &str = "listed_sheet_";

const GROUP_ORDER: [PaperGroup; 7] = [
    PaperGroup::Us,
    PaperGroup::IsoA,
    PaperGroup::IsoB,
    PaperGroup::JisB,
    PaperGroup::Photo,
    PaperGroup::Envelope,
    PaperGroup::Card,
];

/// The names CUPS and PPD files give sizes, as PWG names; looked up without regard to case.
const CUPS_NAMES: &[(&str, &str)] = &[
    ("Letter", "na_letter_8.5x11in"),
    ("Legal", "na_legal_8.5x14in"),
    ("Executive", "na_executive_7.25x10.5in"),
    ("Statement", "na_invoice_5.5x8.5in"),
    ("FanFoldGermanLegal", "na_foolscap_8.5x13in"),
    ("Folio", "om_folio_210x330mm"),
    ("A0", "iso_a0_841x1189mm"),
    ("A1", "iso_a1_594x841mm"),
    ("A2", "iso_a2_420x594mm"),
    ("A3", "iso_a3_297x420mm"),
    ("A4", "iso_a4_210x297mm"),
    ("A5", "iso_a5_148x210mm"),
    ("A6", "iso_a6_105x148mm"),
    ("A7", "iso_a7_74x105mm"),
    ("A8", "iso_a8_52x74mm"),
    ("B5", "jis_b5_182x257mm"),
    ("Tabloid", "na_ledger_11x17in"),
    ("11x17", "na_ledger_11x17in"),
    ("4x6", "na_index-4x6_4x6in"),
    ("5x7", "na_5x7_5x7in"),
    ("8x10", "na_govt-letter_8x10in"),
    ("Hagaki", "jpn_hagaki_100x148mm"),
    ("Postcard", "jpn_hagaki_100x148mm"),
    ("EnvDL", "iso_dl_110x220mm"),
    ("Env10", "na_number-10_4.125x9.5in"),
    ("Env9", "na_number-9_3.875x8.875in"),
    ("EnvMonarch", "na_monarch_3.875x7.5in"),
    ("EnvC4", "iso_c4_229x324mm"),
    ("EnvC5", "iso_c5_162x229mm"),
    ("EnvC6", "iso_c6_114x162mm"),
];

/// The sizes a printer takes in a range (custom sizes), in hundredths of a millimetre: the width is the x-dimension
/// and the height the y-dimension, as media-size-supported lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaperRange {
    pub min_width: i32,
    pub max_width: i32,
    pub min_height: i32,
    pub max_height: i32,
}

impl PaperRange {
    /// A sheet (portrait, in points) the range takes, held either way round.
    pub fn accepts(&self, paper: LayoutSize) -> bool {
        let (w, h) = (paper.width * 2540.0 / 72.0, paper.height * 2540.0 / 72.0);
        let inside = |w: f64, h: f64| {
            w >= f64::from(self.min_width)
                && w <= f64::from(self.max_width)
                && h >= f64::from(self.min_height)
                && h <= f64::from(self.max_height)
        };
        inside(w, h) || inside(h, w)
    }

    /// The sheet (portrait, in points) moved into the range.
    pub fn clamp(&self, paper: LayoutSize) -> LayoutSize {
        let w = (paper.width * 2540.0 / 72.0)
            .clamp(f64::from(self.min_width), f64::from(self.max_width));
        let h = (paper.height * 2540.0 / 72.0)
            .clamp(f64::from(self.min_height), f64::from(self.max_height));
        LayoutSize {
            width: w.min(h) * 72.0 / 2540.0,
            height: w.max(h) * 72.0 / 2540.0,
        }
    }
}

pub fn size_by_raw_value(raw: &str) -> &'static PaperSize {
    ALL.iter()
        .find(|s| s.raw_value == raw)
        .expect("a size of the catalogue")
}

pub fn auto() -> &'static PaperSize {
    &ALL[0]
}

/// The size stored as `text` (its raw value, compared without regard to case and surrounding spaces); Automatic for
/// none and anything else.
pub fn parse_paper_size(text: Option<&str>) -> &'static PaperSize {
    let trimmed = text.unwrap_or("").trim();
    ALL.iter()
        .find(|s| s.raw_value.eq_ignore_ascii_case(trimmed))
        .unwrap_or(auto())
}

/// The usual paper where the user lives: Letter in `LETTER_REGIONS`, A4 everywhere else and when the region is
/// unknown. `region` is a two-letter ISO 3166 code in any case.
pub fn default_for_region(region: Option<&str>) -> &'static PaperSize {
    size_by_raw_value(if uses_inches(region) { "letter" } else { "a4" })
}

/// Inches where the region uses Letter, millimetres elsewhere.
pub fn uses_inches(region: Option<&str>) -> bool {
    let code = region.unwrap_or("").trim().to_uppercase();
    LETTER_REGIONS.contains(&code.as_str())
}

/// Portrait width x height in points; none for Automatic.
pub fn points(size: &PaperSize) -> Option<LayoutSize> {
    pwg_size(size.pwg)
}

/// The named size a sheet of `size` is (a printer's paper), either way round, each side within `FIT_TOLERANCE`;
/// none for a size without a name here.
pub fn match_size(size: LayoutSize) -> Option<&'static PaperSize> {
    let short = size.width.min(size.height);
    let long = size.width.max(size.height);
    if short <= 0.0 {
        return None;
    }
    ALL.iter().find(|s| {
        points(s).is_some_and(|p| {
            (p.width - short).abs() <= FIT_TOLERANCE && (p.height - long).abs() <= FIT_TOLERANCE
        })
    })
}

/// The sizes a list shows first: Letter, Legal, Tabloid, photo and envelope sizes where Letter is used, A4, A5, A3 and
/// the metric ones elsewhere.
pub fn common_for(region: Option<&str>) -> Vec<&'static PaperSize> {
    let raws: &[&str] = if uses_inches(region) {
        &[
            "letter",
            "legal",
            "tabloid",
            "photo4x6",
            "photo5x7",
            "photo8x10",
            "a4",
            "envNumber10",
        ]
    } else {
        &[
            "a4",
            "a5",
            "a3",
            "photo10x15",
            "photo13x18",
            "letter",
            "envDl",
        ]
    };
    raws.iter().map(|r| size_by_raw_value(r)).collect()
}

/// The sizes as pickers list them: Automatic, the common ones for the region, then each group by area.
pub fn display_order(region: Option<&str>) -> Vec<&'static PaperSize> {
    let common = common_for(region);
    let mut order = vec![auto()];
    order.extend(common.iter().copied());
    for group in GROUP_ORDER {
        let mut rest: Vec<&PaperSize> = ALL
            .iter()
            .filter(|s| s.group == group && !common.contains(s))
            .collect();
        rest.sort_by(|a, b| area_of(a).total_cmp(&area_of(b)));
        order.extend(rest);
    }
    order
}

fn area_of(size: &PaperSize) -> f64 {
    points(size).map_or(0.0, |p| p.width * p.height)
}

/// The heading a group's sizes sit under.
pub fn group_label(group: PaperGroup) -> &'static str {
    match group {
        PaperGroup::Us => "US",
        PaperGroup::IsoA => "ISO A",
        PaperGroup::IsoB => "ISO B",
        PaperGroup::JisB => "JIS B",
        PaperGroup::Photo => "Photo",
        PaperGroup::Envelope => "Envelopes",
        PaperGroup::Card => "Cards",
        PaperGroup::Auto => "",
    }
}

/// The size fits `area` (portrait, within `FIT_TOLERANCE`). Automatic always fits, and so does every size when the
/// area is unknown.
pub fn fits(size: &PaperSize, area: Option<LayoutSize>) -> bool {
    match (points(size), area) {
        (Some(paper), Some(a)) if a.width > 0.0 && a.height > 0.0 => {
            paper.width <= a.width + FIT_TOLERANCE && paper.height <= a.height + FIT_TOLERANCE
        }
        _ => true,
    }
}

/// A number as `double.TryParse` reads it with the invariant culture: digits, a point, a sign and an exponent.
fn parse_number(text: &str) -> Option<f64> {
    let text = text.trim();
    if text.is_empty()
        || !text
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'.' | b'+' | b'-' | b'e' | b'E'))
    {
        return None;
    }
    text.parse().ok()
}

/// `name` as the width and height written in the end of a PWG name or custom bound, with `unit` of the first of
/// "mm" and "in" it ends with.
fn dimensions_of(last: &str, mm: f64, inches: f64) -> Option<(f64, f64)> {
    let unit = if last.ends_with("mm") {
        mm
    } else if last.ends_with("in") {
        inches
    } else {
        return None;
    };
    let body = &last[..last.len().checked_sub(2)?];
    let (a, b) = body.split_once('x')?;
    if b.contains('x') {
        return None;
    }
    let (a, b) = (parse_number(a)?, parse_number(b)?);
    (a > 0.0 && b > 0.0).then_some((a * unit, b * unit))
}

/// The size in a PWG self-describing name ("iso_a4_210x297mm", "na_letter_8.5x11in"), portrait, in points; none for
/// any other, and for the "min" and "max" names of a custom range.
pub fn pwg_size(name: &str) -> Option<LayoutSize> {
    let parts: Vec<&str> = name.trim().split('_').collect();
    if parts.len() < 3 || parts[1] == "min" || parts[1] == "max" {
        return None;
    }
    let (a, b) = dimensions_of(parts[parts.len() - 1], 72.0 / 25.4, 72.0)?;
    Some(LayoutSize {
        width: a.min(b),
        height: a.max(b),
    })
}

/// The range a printer takes from the "custom_min_" and "custom_max_" names in its media list (width first, as
/// written); none unless both are there.
pub fn custom_range<'a>(names: impl IntoIterator<Item = &'a str> + Clone) -> Option<PaperRange> {
    let bound = |kind: &str| -> Option<(i32, i32)> {
        names.clone().into_iter().find_map(|name| {
            let parts: Vec<&str> = name.trim().split('_').collect();
            if parts.len() < 3 || parts[0] != "custom" || parts[1] != kind {
                return None;
            }
            let (w, h) = dimensions_of(parts[parts.len() - 1], 100.0, 2540.0)?;
            Some((w.round_ties_even() as i32, h.round_ties_even() as i32))
        })
    };
    let (min, max) = (bound("min")?, bound("max")?);
    (min != max).then_some(PaperRange {
        min_width: min.0,
        max_width: max.0,
        min_height: min.1,
        max_height: max.1,
    })
}

/// `Custom.612x792` and `w612h792`, in points unless a unit follows. None when the text is not of that form; Some(None)
/// when it is but its numbers are not sizes.
fn custom_media_size(text: &str) -> Option<Option<LayoutSize>> {
    let lower = text.to_ascii_lowercase();
    let rest = lower
        .strip_prefix("custom.")
        .or_else(|| lower.strip_prefix('w'))?;
    let digits = |s: &str| {
        s.bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b'.')
            .count()
    };
    let a_len = digits(rest);
    let (a, rest) = rest.split_at(a_len);
    let rest = rest.strip_prefix(['x', 'h'])?;
    let b_len = digits(rest);
    let (b, unit) = rest.split_at(b_len);
    if a.is_empty() || b.is_empty() || !matches!(unit, "" | "in" | "mm" | "cm" | "pt") {
        return None;
    }
    let factor = match unit {
        "in" => 72.0,
        "mm" => 72.0 / 25.4,
        "cm" => 72.0 / 2.54,
        _ => 1.0,
    };
    let (Some(a), Some(b)) = (parse_number(a), parse_number(b)) else {
        return Some(None);
    };
    if a <= 0.0 || b <= 0.0 {
        return Some(None);
    }
    Some(Some(LayoutSize {
        width: a.min(b) * factor,
        height: a.max(b) * factor,
    }))
}

/// The size of a media name as a printer or CUPS gives it: a PWG name, a PPD name ("A4", "Letter", "EnvDL") with an
/// optional ".Borderless"-style ending, or "Custom.612x792" and "w612h792" (points unless a unit follows); portrait,
/// in points.
pub fn media_size(name: &str) -> Option<LayoutSize> {
    if let Some(pwg) = pwg_size(name) {
        return Some(pwg);
    }
    let text = name.trim();
    if let Some(custom) = custom_media_size(text) {
        return custom;
    }
    let key = match text.find('.') {
        Some(dot) if dot > 0 => &text[..dot],
        _ => text,
    };
    CUPS_NAMES
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case(key))
        .and_then(|(_, pwg)| pwg_size(pwg))
}

/// The size an id stands for, portrait, in points: a paper size's raw value or a PWG name such as `id_for` makes;
/// none for "auto" and anything else.
pub fn points_of(id: Option<&str>) -> Option<LayoutSize> {
    let text = id.unwrap_or("").trim();
    let named = parse_paper_size(Some(text));
    if named.is_auto() {
        pwg_size(text)
    } else {
        points(named)
    }
}

/// A PWG name for a sheet in millimetres. A size typed in has its own prefix, so it stays Custom size when it has a
/// name.
pub(crate) fn sheet_id(prefix: &str, size: LayoutSize) -> String {
    let mm = |v: f64| (v * 25.4 / 72.0 * 10.0).round_ties_even() / 10.0;
    format!("{prefix}{}x{}mm", mm(size.width), mm(size.height))
}

/// The id to keep for a sheet (portrait, in points): the raw value of the named size, else its size in millimetres.
pub fn id_for(size: LayoutSize) -> String {
    match match_size(size) {
        Some(named) => named.raw_value.to_string(),
        None => sheet_id(LISTED_PREFIX, size),
    }
}

/// The name people know a sheet by ("Letter", "A3", "Envelope DL"); none for a size without one.
pub fn name_of(size: LayoutSize) -> Option<&'static str> {
    match_size(size).map(|s| s.label)
}

/// A sheet's width and height in the region's unit: inches to 0.01, millimetres to 0.1.
pub fn dimensions(size: LayoutSize, region: Option<&str>) -> (f64, f64) {
    let convert = |v: f64| {
        if uses_inches(region) {
            (v / 72.0 * 100.0).round_ties_even() / 100.0
        } else {
            (v * 25.4 / 72.0 * 10.0).round_ties_even() / 10.0
        }
    };
    (convert(size.width), convert(size.height))
}

/// "8.5 × 11 in" or "210 × 297 mm".
pub fn dimension_text(size: LayoutSize, region: Option<&str>) -> String {
    let (width, height) = dimensions(size, region);
    format!(
        "{width} × {height} {}",
        if uses_inches(region) { "in" } else { "mm" }
    )
}

/// The label of the size an id stands for ("Letter", "A3", "182 × 257 mm"); none for Automatic.
pub fn label_of(id: Option<&str>, region: Option<&str>) -> Option<String> {
    let size = points_of(id)?;
    Some(name_of(size).map_or_else(|| dimension_text(size, region), str::to_string))
}
