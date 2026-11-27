//! Plans the sheets of a job: one page per side, several per side, a booklet or a poster. A side that reads
//! landscape is worked out on a landscape reading view and turned a quarter counterclockwise onto the portrait paper
//! (its pages get 3 turns). Backs are laid out as the back of a long-edge job looks, and turned 180 degrees for a
//! short-edge flip and for every booklet.

use crate::{
    LayoutInsets, LayoutOptions, LayoutRect, LayoutSize, Placement, PlanWarning, PrintableArea,
    Scaling, Sheet, SheetOrientation, SheetPlan, SheetSide, Sides, SourcePage,
};

const EPSILON: f64 = 1e-9;
const SIZE_SLACK: f64 = 1e-6;
/// Less than this much cut off (0.05 in) is not worth a warning.
const CLIP_TOLERANCE: f64 = 0.05 * 72.0;
const POSTER_OVERLAP: f64 = 10.0 * 72.0 / 25.4;
/// The cut marks of a poster tile are this long, in the strip kept clear around it.
pub const POSTER_MARK_LENGTH: f64 = 6.0;
/// The cut marks at a cell's corners are this long.
pub const CUT_MARK_LENGTH: f64 = 4.0;

#[derive(Default)]
struct Notes {
    clipped: f64,
    padding: usize,
    printed: Option<f64>,
}

#[derive(Clone, Copy)]
struct Fitted {
    frame: LayoutRect,
    crop: Option<LayoutRect>,
    scale: f64,
}

fn is_poster(options: &LayoutOptions) -> bool {
    (2..=4).contains(&options.poster)
}

/// The sheets for `pages` (several documents run on as one) on paper with the printer's `area`. Pages are laid out
/// inside the chosen margin alone, equal on every side; the printer's own edge never moves them, it only cuts what
/// reaches into it.
pub fn plan_sheets(
    pages: &[SourcePage],
    options: &LayoutOptions,
    area: PrintableArea,
) -> SheetPlan {
    let duplex = is_duplex(options);
    let laid = laid(area, options);
    let mut notes = Notes::default();
    let sheets = if is_poster(options) {
        poster_sheets(pages, options, laid)
    } else if options.booklet {
        booklet_sheets(pages, options, laid, &mut notes)
    } else {
        flat_sheets(pages, options, duplex, laid, &mut notes)
    };

    let mut warnings = Vec::new();
    if notes.clipped > CLIP_TOLERANCE {
        warnings.push(PlanWarning::Clipped(notes.clipped));
    }
    if notes.padding > 0 {
        warnings.push(PlanWarning::PaddedWithBlanks(notes.padding));
    }
    let printed_scale = notes
        .printed
        .map_or(100, |scale| (scale * 100.0).round_ties_even() as i32);
    SheetPlan {
        area,
        sheets,
        duplex,
        warnings,
        printed_scale,
    }
}

pub fn is_duplex(options: &LayoutOptions) -> bool {
    !is_poster(options) && (options.booklet || options.sides != Sides::OneSided)
}

fn laid(area: PrintableArea, options: &LayoutOptions) -> PrintableArea {
    PrintableArea {
        paper: area.paper,
        margins: options.margins.unwrap_or(LayoutInsets::all(options.margin)),
    }
}

/// The margins of a side that is turned 180 degrees afterwards, so they land back where they were meant to be.
fn rotated(area: PrintableArea) -> PrintableArea {
    let m = area.margins;
    PrintableArea {
        paper: area.paper,
        margins: LayoutInsets {
            top: m.bottom,
            left: m.right,
            bottom: m.top,
            right: m.left,
        },
    }
}

/// Whether a print of `size` (portrait) fits one cell of the layout, either way round, in any reading view the
/// orientation allows. A booklet and a poster ignore the size, so any fits.
pub fn size_fits(options: &LayoutOptions, area: PrintableArea, size: LayoutSize) -> bool {
    if options.booklet || is_poster(options) {
        return true;
    }
    let laid = laid(area, options);
    let views: &[bool] = match options.orientation {
        SheetOrientation::Portrait => &[false],
        SheetOrientation::Landscape => &[true],
        SheetOrientation::Automatic => &[false, true],
    };
    views.iter().any(|&landscape| {
        let (rows, columns) = grid(options.pages_per_sheet, landscape);
        let cell = cell_at(view_printable(laid, landscape), rows, columns, 0, 0);
        (size.width <= cell.width + SIZE_SLACK && size.height <= cell.height + SIZE_SLACK)
            || (size.height <= cell.width + SIZE_SLACK && size.width <= cell.height + SIZE_SLACK)
    })
}

/// How far the printer's own edge reaches in, in millimetres to one decimal: the largest of the area's four margins.
pub fn printer_edge(area: PrintableArea) -> f64 {
    let m = area.margins;
    let points = m.top.max(m.bottom).max(m.left.max(m.right));
    (points * 25.4 / 72.0 * 10.0).round_ties_even() / 10.0
}

/// Each page enlarged to fit n x n printable areas that overlap by 1 cm, anchored top left, one tile per sheet in
/// reading order; a tile with nothing of the page on it is left out. Each tile keeps a strip clear around it for its
/// cut marks.
fn poster_sheets(pages: &[SourcePage], options: &LayoutOptions, area: PrintableArea) -> Vec<Sheet> {
    let n = options.poster as usize;
    let nf = n as f64;
    let mut sheets = Vec::new();
    for page in pages {
        let landscape = match options.orientation {
            SheetOrientation::Automatic => page.size.width > page.size.height,
            o => o == SheetOrientation::Landscape,
        };
        let full = view_printable(area, landscape);
        let view = LayoutRect {
            x: full.x + POSTER_MARK_LENGTH,
            y: full.y + POSTER_MARK_LENGTH,
            width: (full.width - 2.0 * POSTER_MARK_LENGTH).max(0.0),
            height: (full.height - 2.0 * POSTER_MARK_LENGTH).max(0.0),
        };
        let total_width = nf * view.width - (nf - 1.0) * POSTER_OVERLAP;
        let total_height = nf * view.height - (nf - 1.0) * POSTER_OVERLAP;
        if page.size.width <= 0.0
            || page.size.height <= 0.0
            || total_width <= 0.0
            || total_height <= 0.0
        {
            continue;
        }

        let scale = fit_scale(
            page.size.width,
            page.size.height,
            LayoutRect {
                x: 0.0,
                y: 0.0,
                width: total_width,
                height: total_height,
            },
        );
        let poster_width = page.size.width * scale;
        let poster_height = page.size.height * scale;
        for row in 0..n {
            for column in 0..n {
                let left = column as f64 * (view.width - POSTER_OVERLAP);
                let top = row as f64 * (view.height - POSTER_OVERLAP);
                let width = view.width.min(poster_width - left);
                let height = view.height.min(poster_height - top);
                if width < 1.0 || height < 1.0 {
                    continue;
                }
                let crop = LayoutRect {
                    x: left / scale,
                    y: top / scale,
                    width: width / scale,
                    height: height / scale,
                };
                let shown = Fitted {
                    frame: LayoutRect {
                        x: view.x,
                        y: view.y,
                        width,
                        height,
                    },
                    crop: Some(crop),
                    scale,
                };
                let placement = place(page, shown, landscape, false, area.paper);
                let cell = placement.frame;
                let side = SheetSide {
                    placements: vec![placement],
                    borders: false,
                    cut_cells: vec![cell],
                };
                sheets.push(Sheet {
                    front: side,
                    back: None,
                });
            }
        }
    }
    sheets
}

fn chunk(pages: &[SourcePage], from: usize, count: usize) -> &[SourcePage] {
    let start = from.min(pages.len());
    &pages[start..(start + count).min(pages.len())]
}

fn flat_sheets(
    pages: &[SourcePage],
    options: &LayoutOptions,
    duplex: bool,
    area: PrintableArea,
    notes: &mut Notes,
) -> Vec<Sheet> {
    let (portrait_rows, portrait_columns) = grid(options.pages_per_sheet, false);
    let per_side = portrait_rows * portrait_columns;
    let per_sheet = if duplex { 2 * per_side } else { per_side };
    let turn_backs = options.sides == Sides::ShortEdge;
    let rotate_backs = turn_backs != options.backs_turned_after;
    let landscape =
        per_side > 1 && !pages.is_empty() && choose_landscape(pages[0].size, options, area);
    let (rows, columns) = grid(options.pages_per_sheet, landscape);
    let cells = per_side > 1 || options.cell_size.is_some();
    let scaling = if cells && options.scaling != Scaling::Fill {
        Scaling::Fit
    } else {
        options.scaling
    };
    let borders = options.page_borders && per_side > 1;

    let mut side = |side_pages: &[SourcePage], area: PrintableArea| -> SheetSide {
        let mut placements: Vec<Placement> = Vec::new();
        for page in side_pages {
            if per_side == 1 && options.cell_size.is_none() {
                placements.push(alone(
                    page,
                    area,
                    scaling,
                    options.scale,
                    options.orientation,
                    notes,
                ));
                continue;
            }
            if per_side == 1 {
                let own = match options.orientation {
                    SheetOrientation::Automatic => page.size.width > page.size.height,
                    o => o == SheetOrientation::Landscape,
                };
                placements.push(in_cell(
                    page,
                    view_printable(area, own),
                    scaling,
                    own,
                    area.paper,
                    options.cell_size,
                ));
                continue;
            }
            let index = placements.len();
            let (row, mut column) = (index / columns, index % columns);
            if options.right_to_left {
                column = columns - 1 - column;
            }
            let cell = cell_at(view_printable(area, landscape), rows, columns, row, column);
            placements.push(in_cell(
                page,
                cell,
                scaling,
                landscape,
                area.paper,
                options.cell_size,
            ));
        }
        let cut_cells = if options.cut_marks {
            mark_cells(&placements, per_side > 1, area.printable())
        } else {
            Vec::new()
        };
        SheetSide {
            placements,
            borders,
            cut_cells,
        }
    };

    let mut sheets = Vec::new();
    let mut start = 0;
    while start < pages.len() {
        let front = side(chunk(pages, start, per_side), area);
        let mut back = None;
        if duplex {
            let back_area = if rotate_backs { rotated(area) } else { area };
            let mut b = side(chunk(pages, start + per_side, per_side), back_area);
            if turn_backs {
                b = turned_side(&b, area.paper);
            }
            back = Some(b);
        }
        sheets.push(Sheet { front, back });
        start += per_sheet;
    }
    sheets
}

fn booklet_sheets(
    pages: &[SourcePage],
    options: &LayoutOptions,
    area: PrintableArea,
    notes: &mut Notes,
) -> Vec<Sheet> {
    let count = pages.len().div_ceil(4) * 4;
    notes.padding = count - pages.len();
    let scaling = if options.scaling == Scaling::Fill {
        Scaling::Fill
    } else {
        Scaling::Fit
    };

    // The view is the landscape spread; its fold is the paper's centre line.
    let view_width = area.paper.height;
    let view_height = area.paper.width;

    let spread = |mut left: usize, mut right: usize, area: PrintableArea| -> SheetSide {
        let view = view_printable(area, true);
        let left_half = intersect(
            LayoutRect {
                x: 0.0,
                y: 0.0,
                width: view_width / 2.0,
                height: view_height,
            },
            view,
        );
        let right_half = intersect(
            LayoutRect {
                x: view_width / 2.0,
                y: 0.0,
                width: view_width / 2.0,
                height: view_height,
            },
            view,
        );
        if options.right_to_left {
            std::mem::swap(&mut left, &mut right);
        }
        let mut placements = Vec::new();
        if left < pages.len() {
            placements.push(in_cell(
                &pages[left],
                left_half,
                scaling,
                true,
                area.paper,
                None,
            ));
        }
        if right < pages.len() {
            placements.push(in_cell(
                &pages[right],
                right_half,
                scaling,
                true,
                area.paper,
                None,
            ));
        }
        SheetSide {
            placements,
            borders: options.page_borders,
            cut_cells: Vec::new(),
        }
    };

    (0..count / 4)
        .map(|k| {
            let front = spread(count - 1 - 2 * k, 2 * k, area);
            let back_area = if options.backs_turned_after {
                area
            } else {
                rotated(area)
            };
            let back = turned_side(&spread(2 * k + 1, count - 2 - 2 * k, back_area), area.paper);
            Sheet {
                front,
                back: Some(back),
            }
        })
        .collect()
}

/// The frames to mark: those of a side with several pages, or of a page smaller than the laid area.
fn mark_cells(placements: &[Placement], several: bool, laid: LayoutRect) -> Vec<LayoutRect> {
    let frames: Vec<LayoutRect> = placements.iter().map(|p| p.frame).collect();
    let smaller = frames
        .iter()
        .any(|f| f.width < laid.width - EPSILON || f.height < laid.height - EPSILON);
    if several || smaller {
        frames
    } else {
        Vec::new()
    }
}

/// The grid in a reading view: its longer count runs along the view's longer side.
fn grid(pages_per_sheet: u32, landscape: bool) -> (usize, usize) {
    let (fewer, more) = match pages_per_sheet {
        2 => (1, 2),
        4 => (2, 2),
        6 => (2, 3),
        9 => (3, 3),
        16 => (4, 4),
        _ => (1, 1),
    };
    if landscape {
        (fewer, more)
    } else {
        (more, fewer)
    }
}

/// One page on its side: with automatic orientation landscape pages get the landscape view. A page of the other shape
/// than a forced orientation is not turned; it is sized in the sheet as it is.
fn alone(
    page: &SourcePage,
    area: PrintableArea,
    scaling: Scaling,
    scale: i32,
    orientation: SheetOrientation,
    notes: &mut Notes,
) -> Placement {
    let landscape = match orientation {
        SheetOrientation::Automatic => page.size.width > page.size.height,
        o => o == SheetOrientation::Landscape,
    };
    let cell = view_printable(area, landscape);
    let factor = if matches!(scaling, Scaling::ShrinkToFit | Scaling::ActualSize) {
        f64::from(scale.clamp(10, 400)) / 100.0
    } else {
        1.0
    };
    let sized = LayoutSize {
        width: page.size.width * factor,
        height: page.size.height * factor,
    };
    let mut shown = shown(sized, cell, scaling, false);
    // `shown` measures a crop in the sized page; a placement's is in the page's own points.
    if let Some(c) = shown.crop
        && factor != 1.0
    {
        shown.crop = Some(LayoutRect {
            x: c.x / factor,
            y: c.y / factor,
            width: c.width / factor,
            height: c.height / factor,
        });
    }
    notes.printed = Some(notes.printed.unwrap_or(f64::MAX).min(factor * shown.scale));
    if scaling == Scaling::ActualSize {
        notes.clipped = notes
            .clipped
            .max((sized.width - cell.width).max(sized.height - cell.height) / 2.0);
    }
    place(page, shown, landscape, false, area.paper)
}

/// A page in one cell of a reading view, turned a quarter counterclockwise only when that makes it strictly larger.
fn in_cell(
    page: &SourcePage,
    cell: LayoutRect,
    scaling: Scaling,
    landscape: bool,
    paper: LayoutSize,
    size: Option<LayoutSize>,
) -> Placement {
    if let Some(print) = size
        && let Some((region, turn)) = sized_region(page, cell, print)
    {
        return place(
            page,
            shown(page.size, region, scaling, turn),
            landscape,
            turn,
            paper,
        );
    }
    let turn = fit_scale(page.size.height, page.size.width, cell)
        > fit_scale(page.size.width, page.size.height, cell) + EPSILON;
    place(
        page,
        shown(page.size, cell, scaling, turn),
        landscape,
        turn,
        paper,
    )
}

/// The part of `cell` a print of `size` (portrait) takes, centred, in the page's own orientation when that fits and
/// the other way round when only that does; none when neither fits, where the print is the cell.
fn sized_region(
    page: &SourcePage,
    cell: LayoutRect,
    size: LayoutSize,
) -> Option<(LayoutRect, bool)> {
    let landscape = page.size.width > page.size.height;
    for sideways in [landscape, !landscape] {
        let (width, height) = if sideways {
            (size.height, size.width)
        } else {
            (size.width, size.height)
        };
        if width > cell.width + SIZE_SLACK || height > cell.height + SIZE_SLACK {
            continue;
        }
        let region = LayoutRect {
            x: cell.x + (cell.width - width) / 2.0,
            y: cell.y + (cell.height - height) / 2.0,
            width,
            height,
        };
        return Some((region, sideways != landscape));
    }
    None
}

fn place(
    page: &SourcePage,
    shown: Fitted,
    landscape: bool,
    turned: bool,
    paper: LayoutSize,
) -> Placement {
    let frame = if landscape {
        view_to_sheet(shown.frame, paper)
    } else {
        shown.frame
    };
    let turns = ((if landscape { 3 } else { 0 }) + (if turned { 3 } else { 0 })) % 4;
    Placement {
        page: *page,
        frame,
        turns,
        crop: shown.crop,
    }
}

/// A forced orientation is the grid's reading view; otherwise the first page decides it for the whole job.
fn choose_landscape(first: LayoutSize, options: &LayoutOptions, area: PrintableArea) -> bool {
    if options.orientation != SheetOrientation::Automatic {
        return options.orientation == SheetOrientation::Landscape;
    }
    let per = options.pages_per_sheet;
    let (rows, columns) = grid(per, false);
    let (portrait_scale, portrait_turn) = best_fit(
        first,
        cell_at(view_printable(area, false), rows, columns, 0, 0),
    );
    let (rows, columns) = grid(per, true);
    let (landscape_scale, landscape_turn) = best_fit(
        first,
        cell_at(view_printable(area, true), rows, columns, 0, 0),
    );
    if (landscape_scale - portrait_scale).abs() > EPSILON {
        return landscape_scale > portrait_scale;
    }
    !landscape_turn && portrait_turn
}

fn best_fit(page: LayoutSize, cell: LayoutRect) -> (f64, bool) {
    let upright = fit_scale(page.width, page.height, cell);
    let turned = fit_scale(page.height, page.width, cell);
    (upright.max(turned), turned > upright + EPSILON)
}

fn fit_scale(width: f64, height: f64, cell: LayoutRect) -> f64 {
    if width <= 0.0 || height <= 0.0 {
        1.0
    } else {
        (cell.width / width).min(cell.height / height)
    }
}

/// A page of `page` size, turned or not, sized by `scaling` in `cell` and centred; `Scaling::Fill` takes the whole
/// cell and crops the page.
fn shown(page: LayoutSize, cell: LayoutRect, scaling: Scaling, turn: bool) -> Fitted {
    let (width, height) = if turn {
        (page.height, page.width)
    } else {
        (page.width, page.height)
    };
    if scaling == Scaling::Fill
        && width > 0.0
        && height > 0.0
        && (cell.width > 0.0 || cell.height > 0.0)
    {
        let fill = (cell.width / width).max(cell.height / height);
        let (shown_width, shown_height) = (cell.width / fill, cell.height / fill);
        let (crop_width, crop_height) = if turn {
            (shown_height, shown_width)
        } else {
            (shown_width, shown_height)
        };
        let crop =
            if (crop_width - page.width).abs() < 1e-6 && (crop_height - page.height).abs() < 1e-6 {
                None
            } else {
                Some(LayoutRect {
                    x: (page.width - crop_width) / 2.0,
                    y: (page.height - crop_height) / 2.0,
                    width: crop_width,
                    height: crop_height,
                })
            };
        return Fitted {
            frame: cell,
            crop,
            scale: fill,
        };
    }
    let scale = match scaling {
        Scaling::Fit => fit_scale(width, height, cell),
        Scaling::ActualSize => 1.0,
        _ => fit_scale(width, height, cell).min(1.0),
    };
    let (w, h) = (width * scale, height * scale);
    let frame = LayoutRect {
        x: cell.x + (cell.width - w) / 2.0,
        y: cell.y + (cell.height - h) / 2.0,
        width: w,
        height: h,
    };
    if !turn && (w > cell.width + EPSILON || h > cell.height + EPSILON) {
        let visible = intersect(frame, cell);
        let crop = LayoutRect {
            x: (visible.x - frame.x) / scale,
            y: (visible.y - frame.y) / scale,
            width: visible.width / scale,
            height: visible.height / scale,
        };
        return Fitted {
            frame: visible,
            crop: Some(crop),
            scale,
        };
    }
    Fitted {
        frame,
        crop: None,
        scale,
    }
}

/// The printable area in a reading view: the portrait paper itself, or the landscape view whose top is the paper's
/// left edge and whose left is the paper's bottom.
fn view_printable(area: PrintableArea, landscape: bool) -> LayoutRect {
    let p = area.printable();
    if landscape {
        LayoutRect {
            x: area.paper.height - (p.y + p.height),
            y: p.x,
            width: p.height,
            height: p.width,
        }
    } else {
        p
    }
}

fn view_to_sheet(view: LayoutRect, paper: LayoutSize) -> LayoutRect {
    LayoutRect {
        x: view.y,
        y: paper.height - (view.x + view.width),
        width: view.height,
        height: view.width,
    }
}

fn cell_at(view: LayoutRect, rows: usize, columns: usize, row: usize, column: usize) -> LayoutRect {
    let width = view.width / columns as f64;
    let height = view.height / rows as f64;
    LayoutRect {
        x: view.x + column as f64 * width,
        y: view.y + row as f64 * height,
        width,
        height,
    }
}

fn intersect(a: LayoutRect, b: LayoutRect) -> LayoutRect {
    let (x1, y1) = (a.x.max(b.x), a.y.max(b.y));
    let (x2, y2) = (
        (a.x + a.width).min(b.x + b.width),
        (a.y + a.height).min(b.y + b.height),
    );
    if x2 <= x1 || y2 <= y1 {
        LayoutRect {
            x: x1,
            y: y1,
            width: 0.0,
            height: 0.0,
        }
    } else {
        LayoutRect {
            x: x1,
            y: y1,
            width: x2 - x1,
            height: y2 - y1,
        }
    }
}

fn turned_rect(r: LayoutRect, paper: LayoutSize) -> LayoutRect {
    LayoutRect {
        x: paper.width - r.x - r.width,
        y: paper.height - r.y - r.height,
        width: r.width,
        height: r.height,
    }
}

/// A side turned 180 degrees on the paper: every frame mirrored through the paper's centre, every page turned two
/// quarters more.
pub fn turned_side(side: &SheetSide, paper: LayoutSize) -> SheetSide {
    SheetSide {
        borders: side.borders,
        cut_cells: side
            .cut_cells
            .iter()
            .map(|&c| turned_rect(c, paper))
            .collect(),
        placements: side
            .placements
            .iter()
            .map(|p| Placement {
                frame: turned_rect(p.frame, paper),
                turns: (p.turns + 2) % 4,
                ..p.clone()
            })
            .collect(),
    }
}
