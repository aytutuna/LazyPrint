use crate::sizes::MAX_HUNDREDTHS;
use crate::{
    CUSTOM_ID, FIT_TOLERANCE, PaperRange, auto, common_for, default_for_region, dimension_text,
    dimensions, display_order, group_label, id_for, match_size, media_size, points, points_of,
    pwg_size, sheet_id,
};
use lazyprint_layout::{LayoutInsets, LayoutSize, PrintableArea};

/// The paper type value that lets the printer pick.
pub const AUTO_MEDIA: &str = "auto";

/// The heading of the sizes a list puts first.
pub const COMMON_GROUP: &str = "Most common";

/// The heading of the sizes a printer lists that the catalogue has no name for.
pub const PRINTER_GROUP: &str = "Printer sizes";

/// The most distinct sizes taken from a printer's lists; the work on them grows with the square of this.
const MAX_LISTED: usize = 500;

const TYPED_PREFIX: &str = "custom_sheet_";

/// The margins of a media-col entry, in hundredths of a millimetre.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaMargins {
    pub top: i32,
    pub left: i32,
    pub bottom: i32,
    pub right: i32,
}

impl MediaMargins {
    pub fn is_zero(&self) -> bool {
        self.top == 0 && self.left == 0 && self.bottom == 0 && self.right == 0
    }
}

/// A value of a media-col member, as far as the entries a printer lists and the ones a job sends use them. Any other
/// kind a printer reports is kept as its name, so the member still goes back as it came.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MemberValue {
    Integer(i32),
    Keyword(String),
    Collection(Vec<MediaMember>),
    Other(String),
}

/// A named member of a media-col, with one or more values.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaMember {
    pub name: String,
    pub values: Vec<MemberValue>,
}

impl MediaMember {
    pub fn keyword(name: &str, value: &str) -> Self {
        Self {
            name: name.into(),
            values: vec![MemberValue::Keyword(value.into())],
        }
    }

    pub fn integer(name: &str, value: i32) -> Self {
        Self {
            name: name.into(),
            values: vec![MemberValue::Integer(value)],
        }
    }
}

/// One media-col entry (of media-col-database or media-col-ready), sizes in hundredths of a millimetre as a printer
/// reports them. A size the printer takes in a range (custom sizes) is variable: its upper bounds are the width and
/// height, and it never matches a paper.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaEntry {
    pub width: i32,
    pub height: i32,
    pub is_variable: bool,
    pub margins: Option<MediaMargins>,
    pub media_type: Option<String>,
    pub source: Option<String>,
    /// The members of the entry as the printer lists them: what a job sends to ask for it.
    pub attributes: Vec<MediaMember>,
}

impl MediaEntry {
    pub fn hundredths_to_points(hundredths: i32) -> f64 {
        f64::from(hundredths) * 72.0 / 2540.0
    }

    /// The printable area of this entry in points, or none for a variable size or an entry without margins.
    pub fn printable_area(&self) -> Option<PrintableArea> {
        let m = self.margins?;
        if self.is_variable || !self.is_sane() {
            return None;
        }
        let p = Self::hundredths_to_points;
        Some(PrintableArea {
            paper: LayoutSize {
                width: p(self.width),
                height: p(self.height),
            },
            margins: LayoutInsets {
                top: p(m.top),
                left: p(m.left),
                bottom: p(m.bottom),
                right: p(m.right),
            },
        })
    }

    /// A size of at most 10 m and margins that leave something of the sheet; a printer's entry is no more than that.
    pub fn is_sane(&self) -> bool {
        let sized = (1..=MAX_HUNDREDTHS).contains(&self.width)
            && (1..=MAX_HUNDREDTHS).contains(&self.height);
        sized
            && self.margins.is_none_or(|m| {
                let (t, l, b, r) = (m.top, m.left, m.bottom, m.right);
                t >= 0
                    && l >= 0
                    && b >= 0
                    && r >= 0
                    && i64::from(l) + i64::from(r) < i64::from(self.width)
                    && i64::from(t) + i64::from(b) < i64::from(self.height)
            })
    }

    fn sheet(&self) -> LayoutSize {
        let (w, h) = (
            Self::hundredths_to_points(self.width),
            Self::hundredths_to_points(self.height),
        );
        LayoutSize {
            width: w.min(h),
            height: w.max(h),
        }
    }
}

/// What the layout needs to know of a printer's paper: its media lists.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PrinterMedia {
    pub media_col_database: Vec<MediaEntry>,
    pub media_col_ready: Vec<MediaEntry>,
    /// media-ready: the papers loaded, by name.
    pub media_ready: Vec<String>,
    /// media-supported: the sizes by name ("iso_a3_297x420mm"), as a printer without a media-col-database lists them.
    pub media_supported: Vec<String>,
    /// What a custom size may be; none when the printer takes only the sizes it lists.
    pub custom_paper: Option<PaperRange>,
}

fn same(a: LayoutSize, b: LayoutSize) -> bool {
    (a.width - b.width).abs() <= FIT_TOLERANCE && (a.height - b.height).abs() <= FIT_TOLERANCE
}

impl PrinterMedia {
    /// The database entry for a paper (portrait, in points), each side within `FIT_TOLERANCE`: the first with zero
    /// margins when `borderless`, else the first with margins; the other kind when only that exists. A borderless entry
    /// also has to suit the paper `media_type` (a paper type keyword, or "auto"): one without a type, one of that type,
    /// or, for automatic, one of plain paper. No type takes any entry. A borderless entry that does not suit is the last
    /// resort, so a size listed only that way gives the same entry whether or not borderless was asked for. Its
    /// printable area is the area to lay out on and the entry is what the job sends.
    pub fn match_entry(
        &self,
        paper: LayoutSize,
        borderless: bool,
        media_type: Option<&str>,
    ) -> Option<&MediaEntry> {
        let (mut other, mut unsuited) = (None, None);
        for entry in &self.media_col_database {
            let Some(margins) = entry.margins else {
                continue;
            };
            if entry.is_variable || !entry.is_sane() {
                continue;
            }
            let p = MediaEntry::hundredths_to_points;
            if (p(entry.width) - paper.width).abs() > FIT_TOLERANCE
                || (p(entry.height) - paper.height).abs() > FIT_TOLERANCE
            {
                continue;
            }
            if margins.is_zero() == borderless {
                if !borderless || type_fits(entry.media_type.as_deref(), media_type) {
                    return Some(entry);
                }
                unsuited.get_or_insert(entry);
                continue;
            }
            other.get_or_insert(entry);
        }
        other.or(unsuited)
    }

    /// The sizes the printer lists, portrait, each once: its database and ready papers and the names in
    /// media-supported and media-ready.
    pub fn listed(&self) -> Vec<LayoutSize> {
        let mut found: Vec<LayoutSize> = Vec::new();
        let mut add = |size: Option<LayoutSize>| {
            if let Some(s) = size
                && s.width > 0.0
                && found.len() < MAX_LISTED
                && !found.iter().any(|&f| same(f, s))
            {
                found.push(s);
            }
        };
        for entry in self.media_col_database.iter().chain(&self.media_col_ready) {
            if entry.is_variable || !entry.is_sane() {
                continue;
            }
            add(Some(entry.sheet()));
        }
        for name in self.names() {
            add(media_size(name));
        }
        found
    }

    /// The PWG name the printer lists (media-supported or media-ready) for a sheet; none when it lists none of that
    /// size.
    pub fn listed_name(&self, paper: LayoutSize) -> Option<&str> {
        self.names()
            .find(|name| pwg_size(name).is_some_and(|s| same(s, paper)))
            .map(String::as_str)
    }

    /// The names of media-supported, then media-ready, as many of each as `listed` can use.
    fn names(&self) -> impl Iterator<Item = &String> {
        self.media_supported
            .iter()
            .take(MAX_LISTED)
            .chain(self.media_ready.iter().take(MAX_LISTED))
    }

    /// The printer lists no sizes, or this one is among them or in its custom range: nothing to say against it.
    pub fn supports(&self, paper: LayoutSize) -> bool {
        let listed = self.listed();
        listed.is_empty()
            || listed.iter().any(|&s| same(s, paper))
            || self.custom_paper.is_some_and(|r| r.accepts(paper))
    }
}

fn type_fits(entry_type: Option<&str>, wanted: Option<&str>) -> bool {
    match (entry_type, wanted) {
        (None, _) | (_, None) => true,
        (Some(e), Some(w)) => {
            e == w || (w == AUTO_MEDIA && matches!(e, "stationery" | "stationery-inkjet"))
        }
    }
}

/// A picker entry; `id` is what a paper id setting keeps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaperOption {
    pub id: String,
    pub label: String,
    pub detail: String,
    /// The heading the entry sits under in a grouped picker: empty for Automatic and Custom size, else `COMMON_GROUP`,
    /// a group's name or `PRINTER_GROUP`.
    pub group: String,
}

/// What a paper picker lists and which entry shows as chosen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaperChoices {
    pub options: Vec<PaperOption>,
    pub selected: String,
}

fn option(id: String, label: &str, detail: String, group: &str) -> PaperOption {
    PaperOption {
        id,
        label: label.to_string(),
        detail,
        group: group.to_string(),
    }
}

/// The id of a size typed in (the region's unit, either way round), moved into the range the printer lists when it
/// lists one. The id is portrait.
pub fn custom_size_id(
    width: f64,
    height: f64,
    region: Option<&str>,
    printer: Option<&PrinterMedia>,
) -> String {
    let unit = if crate::uses_inches(region) {
        72.0
    } else {
        72.0 / 25.4
    };
    let mut sheet = LayoutSize {
        width: width.min(height) * unit,
        height: width.max(height) * unit,
    };
    if let Some(range) = printer.and_then(|p| p.custom_paper) {
        sheet = range.clamp(sheet);
    }
    sheet_id(TYPED_PREFIX, sheet)
}

/// What a picker lists and shows as chosen: Automatic, the common sizes for the region, every other size by group, the
/// sizes the printer lists that have no name here, and Custom size when it takes a range. Every size can be chosen
/// whatever the printer lists. A chosen size that is not an entry is shown as Custom size when the range takes it, else
/// as an entry of its own.
pub fn paper_choices(
    printer: Option<&PrinterMedia>,
    chosen_id: Option<&str>,
    region: Option<&str>,
) -> PaperChoices {
    let a = auto();
    let mut options = vec![option("auto".into(), a.label, a.detail(), "")];
    let common = common_for(region);
    for size in display_order(region).into_iter().filter(|s| !s.is_auto()) {
        let group = if common.contains(&size) {
            COMMON_GROUP
        } else {
            group_label(size.group)
        };
        options.push(option(
            size.raw_value.into(),
            size.label,
            size.detail(),
            group,
        ));
    }
    let mut unnamed: Vec<LayoutSize> = printer
        .map(PrinterMedia::listed)
        .unwrap_or_default()
        .into_iter()
        .filter(|&s| match_size(s).is_none())
        .collect();
    unnamed.sort_by(|a, b| (a.width * a.height).total_cmp(&(b.width * b.height)));
    for size in unnamed {
        options.push(printer_option(size, region, printer));
    }
    let range = printer.and_then(|p| p.custom_paper);

    let mut selected = "auto".to_string();
    if let Some(chosen) = points_of(chosen_id) {
        let id = id_for(chosen);
        let typed = chosen_id.is_some_and(|c| c.trim().starts_with(TYPED_PREFIX));
        let listed = options.iter().any(|o| o.id == id);
        if range.is_some_and(|r| r.accepts(chosen)) && (typed || !listed) {
            selected = CUSTOM_ID.into();
        } else if listed {
            selected = id;
        } else {
            options.push(printer_option(chosen, region, printer));
            selected = id;
        }
    }
    if range.is_some() {
        options.push(option(CUSTOM_ID.into(), "Custom size", String::new(), ""));
    }
    PaperChoices { options, selected }
}

/// The id to keep when Custom size is picked: the one already chosen when it is custom, else the chosen size (or the
/// usual paper) moved into what the printer takes.
pub fn start_custom(
    printer: Option<&PrinterMedia>,
    chosen_id: Option<&str>,
    region: Option<&str>,
) -> String {
    if paper_choices(printer, chosen_id, region).selected == CUSTOM_ID
        && let Some(id) = chosen_id
    {
        return id.to_string();
    }
    let start = points_of(chosen_id)
        .or_else(|| points(default_for_region(region)))
        .expect("the usual paper has a size");
    let (width, height) = dimensions(start, region);
    custom_size_id(width, height, region, printer)
}

/// The entry for a sheet without a catalogue name: the name the printer gives it ("Small photo"), else its dimensions.
fn printer_option(
    size: LayoutSize,
    region: Option<&str>,
    printer: Option<&PrinterMedia>,
) -> PaperOption {
    let dimensions = dimension_text(size, region);
    let name = printer
        .and_then(|p| p.listed_name(size))
        .map(friendly_name)
        .filter(|n| !n.is_empty());
    match name {
        Some(name) => option(id_for(size), &name, dimensions, PRINTER_GROUP),
        None => option(id_for(size), &dimensions, String::new(), PRINTER_GROUP),
    }
}

/// The middle of a PWG name as words: "om_small-photo_100x150mm" is "Small photo".
fn friendly_name(pwg: &str) -> String {
    let parts: Vec<&str> = pwg.split('_').collect();
    if parts.len() < 3 {
        return String::new();
    }
    let text = parts[1].replace('-', " ");
    let mut chars = text.chars();
    match chars.next() {
        Some(first) if !first.is_ascii_digit() => first.to_uppercase().chain(chars).collect(),
        _ => String::new(),
    }
}
