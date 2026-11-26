//! What a printer says about itself in Get-Printer-Attributes.

use crate::codec::{Attribute, Message, Value, Version};

/// The paper type the layout calls "automatic".
pub const AUTO_MEDIA: &str = "auto";

/// A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.
pub const FIT_TOLERANCE: f64 = 0.05 * 72.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PrinterState {
    #[default]
    Idle,
    Processing,
    Stopped,
}

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

/// One media-col entry (of media-col-database or media-col-ready). Sizes are in hundredths of a
/// millimetre, as a printer reports them. A size the printer takes in a range (custom sizes) has
/// `is_variable` set and its upper bounds as `width` and `height`; it never matches a paper.
/// `attributes` are the members a job sends as its media-col: the size, margins, type and source
/// the printer lists in media-col-supported, without the printer-side members (media-key,
/// media-size-name, media-info, ...) a database entry also carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaEntry {
    pub attributes: Vec<Attribute>,
    pub width: i32,
    pub height: i32,
    pub is_variable: bool,
    pub margins: Option<MediaMargins>,
    pub media_type: Option<String>,
    pub source: Option<String>,
}

/// Hundredths of a millimetre as points.
pub fn points(hundredths_mm: i32) -> f64 {
    hundredths_mm as f64 * 72.0 / 2540.0
}

/// The sizes a printer takes in a range (custom sizes), in hundredths of a millimetre: the
/// x-dimension is the width and the y-dimension the height, as media-size-supported lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaperRange {
    pub min_width: i32,
    pub max_width: i32,
    pub min_height: i32,
    pub max_height: i32,
}

impl PaperRange {
    /// A sheet (portrait, `(width, height)` in points) the range takes, held either way round.
    pub fn accepts(&self, paper: (f64, f64)) -> bool {
        let (w, h) = (paper.0 * 2540.0 / 72.0, paper.1 * 2540.0 / 72.0);
        let within = |w: f64, h: f64| {
            w >= self.min_width as f64
                && w <= self.max_width as f64
                && h >= self.min_height as f64
                && h <= self.max_height as f64
        };
        within(w, h) || within(h, w)
    }

    /// The sheet (portrait, in points) moved into the range.
    pub fn clamp(&self, paper: (f64, f64)) -> (f64, f64) {
        let w = (paper.0 * 2540.0 / 72.0).clamp(self.min_width as f64, self.max_width as f64);
        let h = (paper.1 * 2540.0 / 72.0).clamp(self.min_height as f64, self.max_height as f64);
        (w.min(h) * 72.0 / 2540.0, w.max(h) * 72.0 / 2540.0)
    }
}

/// One ink or toner supply. The level is a percent; -1 is unknown, -2 unavailable, -3 some left.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MarkerSupply {
    pub name: String,
    pub color: String,
    pub supply_type: String,
    pub level: i32,
    pub low_level: Option<i32>,
    pub high_level: Option<i32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capabilities {
    pub name: String,
    pub make_and_model: String,
    /// The printer-uuid without "urn:uuid:", lower case.
    pub uuid: Option<String>,
    pub ipp_versions_supported: Vec<Version>,
    pub state: PrinterState,
    pub state_reasons: Vec<String>,
    pub state_message: String,
    pub is_accepting_jobs: bool,
    pub page_ranges_supported: bool,
    pub document_formats_supported: Vec<String>,
    pub sides_supported: Vec<String>,
    pub print_color_modes_supported: Vec<String>,
    pub copies_supported: (i32, i32),
    pub multiple_document_handling_supported: Vec<String>,
    /// The members media-col may carry ("media-size", "media-type", ...).
    pub media_col_supported: Vec<String>,
    pub media_col_ready: Vec<MediaEntry>,
    pub media_col_database: Vec<MediaEntry>,
    pub media_ready: Vec<String>,
    /// media-supported: the sizes by name ("iso_a3_297x420mm"), as a printer without a media-col-database lists them.
    pub media_supported: Vec<String>,
    /// What a custom size may be; `None` when the printer takes only the sizes it lists.
    pub custom_paper: Option<PaperRange>,
    pub media_type_supported: Vec<String>,
    pub media_source_supported: Vec<String>,
    pub print_quality_supported: Vec<i32>,
    pub print_scaling_supported: Vec<String>,
    pub output_bin_default: Option<String>,
    /// printer-output-tray, one string per tray as the printer wrote it ("type=unRemovableBin;maxcapacity=100;...").
    pub output_trays: Vec<String>,
    /// In dots per inch.
    pub pwg_raster_resolutions: Vec<(i32, i32)>,
    pub pwg_raster_types: Vec<String>,
    pub pwg_raster_sheet_back: Option<String>,
    pub urf_supported: Vec<String>,
    pub supplies: Vec<MarkerSupply>,
    pub more_info: Option<String>,
    pub supply_info_uri: Option<String>,
}

impl Default for Capabilities {
    fn default() -> Self {
        Capabilities {
            name: String::new(),
            make_and_model: String::new(),
            uuid: None,
            ipp_versions_supported: vec![],
            state: PrinterState::Idle,
            state_reasons: vec![],
            state_message: String::new(),
            is_accepting_jobs: true,
            page_ranges_supported: false,
            document_formats_supported: vec![],
            sides_supported: vec![],
            print_color_modes_supported: vec![],
            copies_supported: (1, 1),
            multiple_document_handling_supported: vec![],
            media_col_supported: vec![],
            media_col_ready: vec![],
            media_col_database: vec![],
            media_ready: vec![],
            media_supported: vec![],
            custom_paper: None,
            media_type_supported: vec![],
            media_source_supported: vec![],
            print_quality_supported: vec![],
            print_scaling_supported: vec![],
            output_bin_default: None,
            output_trays: vec![],
            pwg_raster_resolutions: vec![],
            pwg_raster_types: vec![],
            pwg_raster_sheet_back: None,
            urf_supported: vec![],
            supplies: vec![],
            more_info: None,
            supply_info_uri: None,
        }
    }
}

impl Capabilities {
    /// The printer lists IPP 2.x; one that does not is asked as 1.1.
    pub fn speaks_20(&self) -> bool {
        self.ipp_versions_supported.iter().any(|v| v.major == 2)
    }

    /// The printer lists its color modes and color is not one of them.
    pub fn gray_only(&self) -> bool {
        !self.print_color_modes_supported.is_empty()
            && !self
                .print_color_modes_supported
                .iter()
                .any(|m| m == "color")
    }

    /// The printer lists no print quality to choose from.
    pub fn no_quality(&self) -> bool {
        self.print_quality_supported.is_empty()
    }

    /// The database entry for a paper (portrait, `(width, height)` in points), each side within
    /// [`FIT_TOLERANCE`]: the first with zero margins when `borderless`, else the first with
    /// margins; the other kind when only that exists. A borderless entry also has to suit the paper
    /// `media_type` (a paper type keyword, or [`AUTO_MEDIA`]): one without a type, one of that
    /// type, or, for automatic, one of plain paper. A `None` type takes any entry. A borderless
    /// entry that does not suit is the last resort, so a size listed only that way gives the same
    /// entry whether or not borderless was asked for.
    pub fn match_paper(
        &self,
        paper: (f64, f64),
        borderless: bool,
        media_type: Option<&str>,
    ) -> Option<&MediaEntry> {
        let mut other = None;
        let mut unsuited = None;
        for entry in &self.media_col_database {
            let Some(margins) = entry.margins else {
                continue;
            };
            if entry.is_variable
                || (points(entry.width) - paper.0).abs() > FIT_TOLERANCE
                || (points(entry.height) - paper.1).abs() > FIT_TOLERANCE
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

    /// Reads a Get-Printer-Attributes response; an attribute that is missing or of an unexpected
    /// type gives its default.
    pub fn from_message(message: &Message) -> Capabilities {
        let strings = |name: &str| -> Vec<String> {
            message
                .get(name)
                .map(|a| a.values.iter().filter_map(text).collect())
                .unwrap_or_default()
        };
        let first = |name: &str| strings(name).into_iter().next();
        let ints = |name: &str| -> Vec<i32> {
            message
                .get(name)
                .map(|a| a.values.iter().filter_map(number).collect())
                .unwrap_or_default()
        };
        let media_col_supported = strings("media-col-supported");
        let entries = |name: &str| -> Vec<MediaEntry> {
            message
                .get(name)
                .map(|a| {
                    a.values
                        .iter()
                        .filter_map(|v| match v {
                            Value::Collection(members) => entry(members, &media_col_supported),
                            _ => None,
                        })
                        .collect()
                })
                .unwrap_or_default()
        };

        let mut uuid = first("printer-uuid").unwrap_or_default();
        if uuid
            .get(..9)
            .is_some_and(|p| p.eq_ignore_ascii_case("urn:uuid:"))
        {
            uuid = uuid[9..].to_string();
        }
        let name = first("printer-name")
            .filter(|n| !n.is_empty())
            .or_else(|| first("printer-info"))
            .unwrap_or_default();

        Capabilities {
            name,
            make_and_model: first("printer-make-and-model").unwrap_or_default(),
            uuid: (!uuid.is_empty()).then(|| uuid.to_lowercase()),
            ipp_versions_supported: strings("ipp-versions-supported")
                .iter()
                .filter_map(|v| version(v))
                .collect(),
            state: match message.first("printer-state") {
                Some(Value::Enum(4)) => PrinterState::Processing,
                Some(Value::Enum(5)) => PrinterState::Stopped,
                _ => PrinterState::Idle,
            },
            state_reasons: strings("printer-state-reasons"),
            state_message: first("printer-state-message").unwrap_or_default(),
            is_accepting_jobs: !matches!(
                message.first("printer-is-accepting-jobs"),
                Some(Value::Bool(false))
            ),
            page_ranges_supported: matches!(
                message.first("page-ranges-supported"),
                Some(Value::Bool(true))
            ),
            document_formats_supported: strings("document-format-supported"),
            sides_supported: strings("sides-supported"),
            print_color_modes_supported: strings("print-color-mode-supported"),
            copies_supported: match message.first("copies-supported") {
                Some(Value::Range(lower, upper)) => (*lower, *upper),
                Some(Value::Integer(n)) => (1, *n),
                _ => (1, 1),
            },
            multiple_document_handling_supported: strings("multiple-document-handling-supported"),
            media_col_ready: entries("media-col-ready"),
            media_col_database: entries("media-col-database"),
            media_ready: strings("media-ready"),
            media_supported: strings("media-supported"),
            custom_paper: custom_range(message.get("media-size-supported"))
                .or_else(|| custom_range_from_names(&strings("media-supported"))),
            media_type_supported: strings("media-type-supported"),
            media_source_supported: strings("media-source-supported"),
            print_quality_supported: ints("print-quality-supported"),
            print_scaling_supported: strings("print-scaling-supported"),
            output_bin_default: first("output-bin-default"),
            output_trays: strings("printer-output-tray"),
            pwg_raster_resolutions: message
                .get("pwg-raster-document-resolution-supported")
                .map(|a| {
                    a.values
                        .iter()
                        .filter_map(|v| match v {
                            Value::Resolution { x, y, units } => Some(dpi(*x, *y, *units)),
                            _ => None,
                        })
                        .collect()
                })
                .unwrap_or_default(),
            pwg_raster_types: strings("pwg-raster-document-type-supported"),
            pwg_raster_sheet_back: first("pwg-raster-document-sheet-back"),
            urf_supported: strings("urf-supported"),
            supplies: make_supplies(
                &strings("marker-names"),
                &strings("marker-colors"),
                &strings("marker-types"),
                &ints("marker-levels"),
                &ints("marker-low-levels"),
                &ints("marker-high-levels"),
            ),
            more_info: first("printer-more-info"),
            supply_info_uri: first("printer-supply-info-uri"),
            media_col_supported,
        }
    }
}

fn type_fits(entry_type: Option<&str>, wanted: Option<&str>) -> bool {
    match (entry_type, wanted) {
        (None, _) | (_, None) => true,
        (Some(e), Some(w)) => {
            e == w || (w == AUTO_MEDIA && (e == "stationery" || e == "stationery-inkjet"))
        }
    }
}

fn make_supplies(
    names: &[String],
    colors: &[String],
    types: &[String],
    levels: &[i32],
    lows: &[i32],
    highs: &[i32],
) -> Vec<MarkerSupply> {
    names
        .iter()
        .enumerate()
        .map(|(i, name)| MarkerSupply {
            name: name.clone(),
            color: colors.get(i).cloned().unwrap_or_default(),
            supply_type: types.get(i).cloned().unwrap_or_default(),
            level: levels.get(i).copied().unwrap_or(-1),
            low_level: lows.get(i).copied(),
            high_level: highs.get(i).copied(),
        })
        .collect()
}

/// The first media-size-supported entry that takes a range; its fixed side counts as a range of one value.
fn custom_range(sizes: Option<&Attribute>) -> Option<PaperRange> {
    let bounds = |value: Option<&Value>| match value {
        Some(Value::Integer(v)) => Some((*v, *v)),
        Some(Value::Range(lower, upper)) => Some((*lower, *upper)),
        _ => None,
    };
    for size in &sizes?.values {
        let Value::Collection(members) = size else {
            continue;
        };
        let (Some(x), Some(y)) = (
            bounds(first_value(members, "x-dimension")),
            bounds(first_value(members, "y-dimension")),
        ) else {
            continue;
        };
        if x.0 != x.1 || y.0 != y.1 {
            return Some(PaperRange {
                min_width: x.0,
                max_width: x.1,
                min_height: y.0,
                max_height: y.1,
            });
        }
    }
    None
}

/// The range a printer takes from the "custom_min_" and "custom_max_" names in its media list
/// (width first, as written); `None` unless both are there and they differ.
pub fn custom_range_from_names(names: &[String]) -> Option<PaperRange> {
    let bound = |kind: &str| -> Option<(i32, i32)> {
        names.iter().find_map(|name| {
            let parts: Vec<&str> = name.trim().split('_').collect();
            if parts.len() < 3 || parts[0] != "custom" || parts[1] != kind {
                return None;
            }
            let last = parts[parts.len() - 1];
            let unit = if last.ends_with("mm") {
                100.0
            } else if last.ends_with("in") {
                2540.0
            } else {
                return None;
            };
            let (w, h) = last[..last.len() - 2].split_once('x')?;
            let (w, h) = (w.parse::<f64>().ok()?, h.parse::<f64>().ok()?);
            if !w.is_finite() || !h.is_finite() || w <= 0.0 || h <= 0.0 {
                return None;
            }
            Some((
                (w * unit).round_ties_even() as i32,
                (h * unit).round_ties_even() as i32,
            ))
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

/// The text of a string-like value; octet strings are read as UTF-8.
fn text(value: &Value) -> Option<String> {
    match value {
        Value::Keyword(s)
        | Value::Name(s)
        | Value::Text(s)
        | Value::Uri(s)
        | Value::UriScheme(s)
        | Value::MimeType(s)
        | Value::Charset(s)
        | Value::Language(s) => Some(s.clone()),
        Value::Octets(b) => Some(String::from_utf8_lossy(b).into_owned()),
        _ => None,
    }
}

fn number(value: &Value) -> Option<i32> {
    match value {
        Value::Integer(n) | Value::Enum(n) => Some(*n),
        _ => None,
    }
}

fn version(text: &str) -> Option<Version> {
    let (major, minor) = text.split_once('.')?;
    Some(Version {
        major: major.parse().ok()?,
        minor: minor.parse().ok()?,
    })
}

fn dpi(x: i32, y: i32, units: u8) -> (i32, i32) {
    if units == 4 {
        (
            (x as f64 * 2.54).round_ties_even() as i32,
            (y as f64 * 2.54).round_ties_even() as i32,
        )
    } else {
        (x, y)
    }
}

fn first_value<'a>(attributes: &'a [Attribute], name: &str) -> Option<&'a Value> {
    attributes
        .iter()
        .find(|a| a.name == name)
        .and_then(|a| a.values.first())
}

fn dimension(value: Option<&Value>) -> Option<(i32, bool)> {
    match value {
        Some(Value::Integer(v)) => Some((*v, false)),
        Some(Value::Range(_, upper)) => Some((*upper, true)),
        _ => None,
    }
}

fn entry(members: &[Attribute], supported: &[String]) -> Option<MediaEntry> {
    let Some(Value::Collection(size)) = first_value(members, "media-size") else {
        return None;
    };
    let (width, width_range) = dimension(first_value(size, "x-dimension"))?;
    let (height, height_range) = dimension(first_value(size, "y-dimension"))?;

    let margin = |name: &str| match first_value(members, name) {
        Some(Value::Integer(v)) => Some(*v),
        _ => None,
    };
    let edges = [
        margin("media-top-margin"),
        margin("media-left-margin"),
        margin("media-bottom-margin"),
        margin("media-right-margin"),
    ];
    let margins = edges.iter().any(Option::is_some).then(|| MediaMargins {
        top: edges[0].unwrap_or(0),
        left: edges[1].unwrap_or(0),
        bottom: edges[2].unwrap_or(0),
        right: edges[3].unwrap_or(0),
    });
    let label = |name: &str| first_value(members, name).and_then(text);
    Some(MediaEntry {
        attributes: job_members(members, supported),
        width,
        height,
        is_variable: width_range || height_range,
        margins,
        media_type: label("media-type"),
        source: label("media-source"),
    })
}

const JOB_MEMBER_NAMES: [&str; 6] = [
    "media-top-margin",
    "media-left-margin",
    "media-bottom-margin",
    "media-right-margin",
    "media-type",
    "media-source",
];

fn job_members(members: &[Attribute], supported: &[String]) -> Vec<Attribute> {
    let mut kept = vec![];
    for member in members {
        if member.name == "media-size" {
            if let Some(Value::Collection(size)) = member.values.first()
                && let Some(x @ Value::Integer(_)) = first_value(size, "x-dimension")
                && let Some(y @ Value::Integer(_)) = first_value(size, "y-dimension")
            {
                kept.push(Attribute::one(
                    "media-size",
                    Value::Collection(vec![
                        Attribute::one("x-dimension", x.clone()),
                        Attribute::one("y-dimension", y.clone()),
                    ]),
                ));
            }
            continue;
        }
        if !JOB_MEMBER_NAMES.contains(&member.name.as_str())
            || (!supported.is_empty() && !supported.contains(&member.name))
        {
            continue;
        }
        let margin = member.name.ends_with("-margin");
        if let Some(value) = member.values.first()
            && (if margin {
                matches!(value, Value::Integer(_))
            } else {
                text(value).is_some()
            })
        {
            kept.push(Attribute::one(&member.name, value.clone()));
        }
    }
    kept
}
