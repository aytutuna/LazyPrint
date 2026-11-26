use lazyprint_layout::{
    MarginChoice, PageSelection, PaperPath, Scaling, SheetOrientation, Sides, round_margin,
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize, Serializer};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The paper type or tray value that lets the printer pick.
pub const AUTO: &str = "auto";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorChoice {
    #[default]
    Color,
    Gray,
}

/// Asked of the printer as print-quality 4, 3 and 5.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QualityChoice {
    #[default]
    Normal,
    Draft,
    Best,
}

/// What the user chose for printing. Every field has a default, so older files load.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrintSettings {
    /// The task's raw value, kept as text so a newer task survives.
    pub task_id: Option<String>,
    /// The printer's id; none is the system's default printer.
    pub printer_id: Option<String>,
    /// 1 to 99. Not saved: each launch starts at 1.
    #[serde(skip)]
    pub copies: i32,
    pub collate: bool,
    pub color: ColorChoice,
    pub quality: QualityChoice,
    pub sides: Sides,
    pub pages_per_sheet: i32,
    pub booklet: bool,
    pub right_to_left: bool,
    pub page_borders: bool,
    pub scaling: Scaling,
    /// Percent, 10 to 400.
    pub scale: i32,
    pub orientation: SheetOrientation,
    pub margin: MarginChoice,
    /// Millimetres to 0.01, 0 to 50; what `MarginChoice::Custom` means. Written without a decimal point when whole.
    #[serde(serialize_with = "write_millimetres")]
    pub margin_mm: f64,
    /// 0 for no poster, else 2, 3 or 4 sheets across and down.
    pub poster: i32,
    /// Odd or even pages only, and the reverse order: asked for one job at a time, so not saved.
    #[serde(skip)]
    pub page_selection: PageSelection,
    #[serde(skip)]
    pub reverse_order: bool,
    /// A paper size's raw value; "auto" is what the printer has loaded, else the regional default.
    pub paper_id: String,
    /// A media-source keyword the printer lists ("main", "tray-2", "manual"); "auto" lets the printer pick.
    pub media_source: String,
    /// A media-type keyword the printer lists ("stationery", "photographic-glossy"); "auto" lets the printer pick.
    pub media_type: String,
    /// A photo size id: the most each print takes of its cell. "page" is the largest that fits.
    pub photo_size_id: String,
    pub cut_marks: bool,
}

fn write_millimetres<S: Serializer>(value: &f64, serializer: S) -> Result<S::Ok, S::Error> {
    if value.fract() == 0.0 {
        serializer.serialize_i64(*value as i64)
    } else {
        serializer.serialize_f64(*value)
    }
}

impl Default for PrintSettings {
    fn default() -> Self {
        Self {
            task_id: None,
            printer_id: None,
            copies: 1,
            collate: true,
            color: ColorChoice::Color,
            quality: QualityChoice::Normal,
            sides: Sides::OneSided,
            pages_per_sheet: 1,
            booklet: false,
            right_to_left: false,
            page_borders: false,
            scaling: Scaling::ShrinkToFit,
            scale: 100,
            orientation: SheetOrientation::Automatic,
            margin: MarginChoice::Printer,
            margin_mm: 10.0,
            poster: 0,
            page_selection: PageSelection::All,
            reverse_order: false,
            paper_id: AUTO.into(),
            media_source: AUTO.into(),
            media_type: AUTO.into(),
            photo_size_id: "page".into(),
            cut_marks: false,
        }
    }
}

/// What a file could not be read as.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DecodeError {}

/// One field read on its own: a missing key, null, a value of the wrong type or an enum name this version does not
/// know leaves only that field at its default.
pub(crate) fn lenient<T: DeserializeOwned>(
    object: &Map<String, Value>,
    key: &str,
    default: T,
) -> T {
    object
        .get(key)
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or(default)
}

pub(crate) fn parse_document(text: &str) -> Result<Value, DecodeError> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    serde_json::from_str(text).map_err(|e| DecodeError(e.to_string()))
}

impl PrintSettings {
    /// Reads settings.json. A document that is not an object does not decode; inside it every field is read leniently,
    /// and a file saved while the layout was a style of its own gets the values that style forced.
    pub fn from_json(text: &str) -> Result<Self, DecodeError> {
        Self::from_value(&parse_document(text)?)
    }

    pub fn from_value(value: &Value) -> Result<Self, DecodeError> {
        let object = value
            .as_object()
            .ok_or_else(|| DecodeError("The file does not contain settings.".into()))?;
        Ok(Self::from_object(object))
    }

    pub(crate) fn from_object(o: &Map<String, Value>) -> Self {
        let d = Self::default();
        let mut s = Self {
            task_id: lenient(o, "taskId", None),
            printer_id: lenient(o, "printerId", None),
            copies: d.copies,
            collate: lenient(o, "collate", d.collate),
            color: lenient(o, "color", d.color),
            quality: lenient(o, "quality", d.quality),
            sides: lenient(o, "sides", d.sides),
            pages_per_sheet: lenient(o, "pagesPerSheet", d.pages_per_sheet),
            booklet: lenient(o, "booklet", d.booklet),
            right_to_left: lenient(o, "rightToLeft", d.right_to_left),
            page_borders: lenient(o, "pageBorders", d.page_borders),
            scaling: lenient(o, "scaling", d.scaling),
            scale: lenient(o, "scale", d.scale),
            orientation: lenient(o, "orientation", d.orientation),
            margin: lenient(o, "margin", d.margin),
            margin_mm: round_margin(lenient(o, "marginMm", d.margin_mm)),
            poster: lenient(o, "poster", d.poster),
            page_selection: d.page_selection,
            reverse_order: d.reverse_order,
            paper_id: lenient(o, "paperId", d.paper_id),
            media_source: lenient(o, "mediaSource", d.media_source),
            media_type: lenient(o, "mediaType", d.media_type),
            photo_size_id: lenient(o, "photoSizeId", d.photo_size_id),
            cut_marks: lenient(o, "cutMarks", d.cut_marks),
        };
        let layout_style: Option<String> = lenient(o, "layoutStyle", None);
        let photo_fill: Option<bool> = lenient(o, "photoFill", None);
        s.migrate(layout_style, photo_fill);
        s
    }

    /// A file with a layout style gets the values that style forced. One with a photo fill but no style comes from the
    /// builds before the style was saved, whose 4x6 and cut marks were defaults only photo layouts used, so its style
    /// follows the task. Anything else is already in the current form.
    fn migrate(&mut self, layout_style: Option<String>, photo_fill: Option<bool>) {
        let style = layout_style.or_else(|| {
            photo_fill?;
            Some(
                match self.task_id.as_deref() {
                    Some("photos") => "photoPrints",
                    Some("photoSheet") => "photoSheet",
                    _ => "pages",
                }
                .to_string(),
            )
        });
        match style.as_deref() {
            Some("photoPrints") => {
                self.scaling = if photo_fill == Some(false) {
                    Scaling::Fit
                } else {
                    Scaling::Fill
                };
                self.pages_per_sheet = 1;
                self.sides = Sides::OneSided;
                self.booklet = false;
                self.poster = 0;
                self.margin = MarginChoice::None;
            }
            Some("photoSheet") => {
                self.photo_size_id = "page".into();
                self.sides = Sides::OneSided;
                self.booklet = false;
                self.poster = 0;
                self.margin = MarginChoice::None;
            }
            Some(_) => {
                self.photo_size_id = "page".into();
                self.cut_marks = false;
            }
            None => {}
        }
    }

    /// The settings as the printer will get them: a quality or color it cannot take is the one it uses instead.
    pub fn used(&self, printer_has_no_quality: bool, printer_is_gray_only: bool) -> Self {
        Self {
            quality: if printer_has_no_quality {
                QualityChoice::Normal
            } else {
                self.quality
            },
            color: if printer_is_gray_only {
                ColorChoice::Gray
            } else {
                self.color
            },
            ..self.clone()
        }
    }

    /// Whether `settings` still has every option `preset` sets. Options the preset's layout doesn't use don't count, so
    /// a hidden value can't clear a match.
    pub fn same_in_use(preset: &Self, settings: &Self) -> bool {
        let poster = (2..=4).contains(&preset.poster);
        let sized = preset.photo_size_id != "page";
        let alone = !poster && !preset.booklet && preset.pages_per_sheet == 1 && !sized;
        let mut p = Self {
            task_id: None,
            ..preset.clone()
        };
        if p.margin != MarginChoice::Custom {
            p.margin_mm = settings.margin_mm;
        }
        if !(alone && matches!(p.scaling, Scaling::ShrinkToFit | Scaling::ActualSize)) {
            p.scale = settings.scale;
        }
        if !(p.booklet || p.pages_per_sheet > 1) || poster {
            p.right_to_left = settings.right_to_left;
        }
        if p.pages_per_sheet == 1 && !p.booklet {
            p.page_borders = settings.page_borders;
        }
        if p.booklet {
            p.orientation = settings.orientation;
        }
        if p.booklet || poster {
            p.sides = settings.sides;
            p.photo_size_id = settings.photo_size_id.clone();
            p.cut_marks = settings.cut_marks;
        }
        p == Self {
            task_id: None,
            ..settings.clone()
        }
    }
}

/// What is remembered about one printer.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrinterPrefs {
    pub paper_path: PaperPath,
    /// What was last used with this printer; none until it was used, which leaves the current choice alone.
    pub paper_id: Option<String>,
    pub sides: Option<Sides>,
    pub color: Option<ColorChoice>,
    pub quality: Option<QualityChoice>,
    pub media_source: Option<String>,
    pub media_type: Option<String>,
}

impl PrinterPrefs {
    fn from_object(o: &Map<String, Value>) -> Self {
        Self {
            paper_path: match o.get("paperPath") {
                Some(Value::Object(p)) => paper_path_from_object(p),
                _ => PaperPath::default(),
            },
            paper_id: lenient(o, "paperId", None),
            sides: lenient(o, "sides", None),
            color: lenient(o, "color", None),
            quality: lenient(o, "quality", None),
            media_source: lenient(o, "mediaSource", None),
            media_type: lenient(o, "mediaType", None),
        }
    }

    /// Brings back the paper, tray, paper type, sides, color and quality last used with the printer; copies, range and
    /// layout stay.
    pub fn apply_to(&self, settings: &mut PrintSettings) {
        if let Some(v) = &self.paper_id {
            settings.paper_id = v.clone();
        }
        if let Some(v) = self.sides {
            settings.sides = v;
        }
        if let Some(v) = self.color {
            settings.color = v;
        }
        if let Some(v) = self.quality {
            settings.quality = v;
        }
        if let Some(v) = &self.media_source {
            settings.media_source = v.clone();
        }
        if let Some(v) = &self.media_type {
            settings.media_type = v.clone();
        }
    }

    pub fn remembering(&self, settings: &PrintSettings) -> Self {
        Self {
            paper_id: Some(settings.paper_id.clone()),
            sides: Some(settings.sides),
            color: Some(settings.color),
            quality: Some(settings.quality),
            media_source: Some(settings.media_source.clone()),
            media_type: Some(settings.media_type.clone()),
            ..self.clone()
        }
    }

    /// The prefs of each printer by id, from printers.json.
    pub fn map_from_json(text: &str) -> Result<BTreeMap<String, PrinterPrefs>, DecodeError> {
        let document = parse_document(text)?;
        let object = document
            .as_object()
            .ok_or_else(|| DecodeError("The file does not contain printers.".into()))?;
        object
            .iter()
            .map(|(id, v)| match v {
                Value::Object(o) => Ok((id.clone(), Self::from_object(o))),
                _ => Err(DecodeError(format!("The prefs of {id} are not an object."))),
            })
            .collect()
    }
}

fn paper_path_from_object(o: &Map<String, Value>) -> PaperPath {
    let d = PaperPath::default();
    PaperPath {
        turn_stack_over: lenient(o, "turnStackOver", d.turn_stack_over),
        turn_backs: lenient(o, "turnBacks", d.turn_backs),
        checked: lenient(o, "checked", d.checked),
    }
}
