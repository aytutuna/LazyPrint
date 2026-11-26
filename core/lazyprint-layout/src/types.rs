use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LayoutSize {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LayoutRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Distances from the four edges of a sheet.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LayoutInsets {
    pub top: f64,
    pub left: f64,
    pub bottom: f64,
    pub right: f64,
}

impl LayoutInsets {
    pub fn all(distance: f64) -> Self {
        Self {
            top: distance,
            left: distance,
            bottom: distance,
            right: distance,
        }
    }

    pub fn is_zero(&self) -> bool {
        *self == Self::default()
    }
}

/// Where a printer can put ink on its paper.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PrintableArea {
    /// The paper as it is fed, portrait: width at most height.
    pub paper: LayoutSize,
    /// The printer's unprintable edges; zero for borderless.
    pub margins: LayoutInsets,
}

impl PrintableArea {
    pub fn printable(&self) -> LayoutRect {
        let (paper, m) = (self.paper, self.margins);
        LayoutRect {
            x: m.left,
            y: m.top,
            width: (paper.width - m.left - m.right).max(0.0),
            height: (paper.height - m.top - m.bottom).max(0.0),
        }
    }
}

/// One page of one document, at the size it is shown (after a page's rotation or a photo's orientation).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourcePage {
    pub document: usize,
    pub index: usize,
    pub size: LayoutSize,
}

/// How a page is sized in the space it gets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scaling {
    /// A page larger than the printable area is made smaller, others print at real size.
    #[default]
    ShrinkToFit,
    Fit,
    /// 100 %, cut at the margin if it must be.
    ActualSize,
    /// Fills its frame, cropped in the middle (photos).
    Fill,
}

/// The paper edge a sheet turns over on, as in IPP and print dialogs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Sides {
    #[default]
    OneSided,
    LongEdge,
    ShortEdge,
}

/// Automatic gives each page the orientation it has; the others make every sheet portrait or landscape.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SheetOrientation {
    #[default]
    Automatic,
    Portrait,
    Landscape,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LayoutOptions {
    /// 1, 2, 4, 6, 9 or 16; any other number is 1.
    pub pages_per_sheet: u32,
    /// Two pages per side, in booklet order, folded in the middle.
    pub booklet: bool,
    /// Booklets and several pages per side read right to left.
    pub right_to_left: bool,
    pub scaling: Scaling,
    pub sides: Sides,
    /// A thin line around each page when there are several on a side.
    pub page_borders: bool,
    /// The size of a page alone on its side, in percent of its own. Cells of several pages, booklets and fit or fill ignore it.
    pub scale: i32,
    /// A booklet is always a landscape spread and ignores it.
    pub orientation: SheetOrientation,
    /// The distance kept clear on every sheet edge. The printer's own edge is not added to it.
    pub margin: f64,
    /// The printer's own edge on each side, kept clear instead of `margin` when set.
    pub margins: Option<LayoutInsets>,
    /// The backs are turned 180 degrees once more after planning, so their margins are laid the other way round.
    pub backs_turned_after: bool,
    /// 2, 3 or 4: each page is enlarged across that many sheets in both directions. Any other number is no poster.
    pub poster: u32,
    /// A print size, portrait: the most each page takes of its cell. Booklets and posters ignore it.
    pub cell_size: Option<LayoutSize>,
    /// Short marks at the corners of each printed page when there are several on a side or one smaller than the laid area.
    pub cut_marks: bool,
}

impl Default for LayoutOptions {
    fn default() -> Self {
        Self {
            pages_per_sheet: 1,
            booklet: false,
            right_to_left: false,
            scaling: Scaling::ShrinkToFit,
            sides: Sides::OneSided,
            page_borders: false,
            scale: 100,
            orientation: SheetOrientation::Automatic,
            margin: 0.0,
            margins: None,
            backs_turned_after: false,
            poster: 0,
            cell_size: None,
            cut_marks: false,
        }
    }
}

/// The margin choices. "small" in an older file is `Printer`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MarginChoice {
    None,
    #[default]
    #[serde(alias = "small")]
    Printer,
    Normal,
    Custom,
}

pub const MAX_MARGIN_MM: f64 = 50.0;

impl MarginChoice {
    /// 0, the printer's edge, 12, or the custom distance.
    pub fn millimetres(self, custom: f64, printer_edge: f64) -> f64 {
        match self {
            Self::Printer => printer_edge,
            Self::Normal => 12.0,
            Self::Custom => round_margin(custom),
            Self::None => 0.0,
        }
    }

    pub fn points(self, custom: f64, printer_edge: f64) -> f64 {
        self.millimetres(custom, printer_edge) * 72.0 / 25.4
    }
}

/// Clamped to 0 to 50 and rounded to 0.01, so 0.05 + 0.1 is 0.15 and compares equal to it.
pub fn round_margin(millimetres: f64) -> f64 {
    if millimetres.is_nan() {
        return 0.0;
    }
    (millimetres.clamp(0.0, MAX_MARGIN_MM) * 100.0).round() / 100.0
}

/// Where one page goes on a sheet side.
#[derive(Clone, Debug, PartialEq)]
pub struct Placement {
    pub page: SourcePage,
    /// On the sheet, the box the page's shown area fills after turning.
    pub frame: LayoutRect,
    /// Quarter turns clockwise applied to the page, 0 to 3.
    pub turns: u8,
    /// The part of the page shown, in page points, for `Scaling::Fill`; none is the whole page.
    pub crop: Option<LayoutRect>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SheetSide {
    pub placements: Vec<Placement>,
    pub borders: bool,
    /// On the sheet, the boxes that get short cut marks outside their corners.
    pub cut_cells: Vec<LayoutRect>,
}

/// A sheet of paper; `back` is none for a one-sided plan.
#[derive(Clone, Debug, PartialEq)]
pub struct Sheet {
    pub front: SheetSide,
    pub back: Option<SheetSide>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PlanWarning {
    /// Pages printed at real size run past the margin by this much on their worst side.
    Clipped(f64),
    /// A booklet was filled up with blank pages.
    PaddedWithBlanks(usize),
}

#[derive(Clone, Debug, PartialEq)]
pub struct SheetPlan {
    pub area: PrintableArea,
    pub sheets: Vec<Sheet>,
    /// Every sheet has a back (blank if need be).
    pub duplex: bool,
    pub warnings: Vec<PlanWarning>,
    /// The size, in whole percent, the smallest page alone on its side really prints at; 100 when no page is alone.
    pub printed_scale: i32,
}

impl SheetPlan {
    pub fn side_count(&self) -> usize {
        self.sheets
            .iter()
            .map(|s| if s.back.is_some() { 2 } else { 1 })
            .sum()
    }
}
