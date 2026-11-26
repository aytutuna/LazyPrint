use crate::LoadedDocument;
use lazyprint_layout::{
    DuplexPass, LayoutInsets, LayoutOptions, LayoutSize, MarginChoice, PHOTO_SIZES, PaperPath,
    PhotoSize, PlanWarning, PrintableArea, SheetPlan, SourcePage, is_duplex, manual_passes,
    photo_size, pick_pages, plan_copies, plan_sheets, printer_edge as edge_of, size_fits,
};
use lazyprint_paper::{
    AUTO_MEDIA, MediaEntry, PrinterMedia, default_for_region, points, points_of, pwg_size,
};
use lazyprint_settings::{ColorChoice, PrintSettings};

const COLLATED_COPIES: &str = "separate-documents-collated-copies";

/// What planning reads of a printer. A printer that is not known at all is `None` wherever one is taken.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JobPrinter {
    pub media: PrinterMedia,
    pub sides_supported: Vec<String>,
    /// The most copies the printer makes at once.
    pub copies_upper: i32,
    pub multiple_document_handling: Vec<String>,
    pub media_types: Vec<String>,
    pub media_sources: Vec<String>,
    pub color_modes: Vec<String>,
    pub media_col_supported: Vec<String>,
    pub print_scaling_supported: Vec<String>,
    pub print_quality_supported: Vec<i32>,
}

impl JobPrinter {
    pub(crate) fn can_two_sided(&self) -> bool {
        self.sides_supported
            .iter()
            .any(|s| s == "two-sided-long-edge")
    }

    pub(crate) fn collates(&self) -> bool {
        self.multiple_document_handling
            .iter()
            .any(|s| s == COLLATED_COPIES)
    }

    /// The printer lists its color modes, has no color and can print monochrome.
    fn prints_gray_only_with_mono(&self) -> bool {
        !self.color_modes.iter().any(|m| m == "color")
            && self.color_modes.iter().any(|m| m == "monochrome")
    }

    /// The paper type to ask for: the chosen one when the printer lists it, else none and the printer picks.
    pub(crate) fn listed_type<'a>(&self, settings: &'a PrintSettings) -> Option<&'a str> {
        let t = settings.media_type.as_str();
        let listed = !t.is_empty() && t != AUTO_MEDIA && self.media_types.iter().any(|m| m == t);
        listed.then_some(t)
    }

    /// The tray to ask for: the chosen one when the printer lists it, else none and the printer picks.
    pub(crate) fn listed_source<'a>(&self, settings: &'a PrintSettings) -> Option<&'a str> {
        let s = settings.media_source.as_str();
        let listed = !s.is_empty() && s != AUTO_MEDIA && self.media_sources.iter().any(|m| m == s);
        listed.then_some(s)
    }
}

/// What a job will print.
#[derive(Clone, Debug, PartialEq)]
pub struct JobPlan {
    pub plan: SheetPlan,
    /// Two-sided was asked for and the printer can't: two passes.
    pub manual_duplex: bool,
    /// One pass, or the fronts then the backs.
    pub passes: Vec<DuplexPass>,
    pub copies_in_job: i32,
    pub notes: Vec<String>,
}

/// The printer and the place the user lives in, which decides the usual paper.
#[derive(Clone, Copy, Debug, Default)]
pub struct JobContext<'a> {
    pub printer: Option<&'a JobPrinter>,
    /// A two-letter ISO 3166 region code.
    pub region: Option<&'a str>,
}

impl JobContext<'_> {
    fn quarter_inch_area(paper: LayoutSize) -> PrintableArea {
        PrintableArea {
            paper,
            margins: LayoutInsets::all(0.25 * 72.0),
        }
    }

    /// The paper a job goes on, portrait, in points: the chosen size, else what the printer has loaded, else the
    /// usual paper.
    pub fn sheet(&self, paper_id: &str) -> LayoutSize {
        points_of(Some(paper_id))
            .or_else(|| self.printer.and_then(loaded))
            .or_else(|| points(default_for_region(self.region)))
            .expect("the usual paper has a size")
    }

    /// Where the printer can print on a paper: the printer's matching media-col-database entry (borderless or not, the
    /// other kind when only that exists), else 0.25 in on every side. `paper_id` is a named size or any PWG name.
    pub fn area_of(
        &self,
        paper_id: &str,
        borderless: bool,
        media_type: Option<&str>,
    ) -> PrintableArea {
        let size = self.sheet(paper_id);
        self.printer
            .and_then(|p| p.media.match_entry(size, borderless, media_type))
            .and_then(|entry| entry.printable_area())
            .unwrap_or_else(|| Self::quarter_inch_area(size))
    }

    /// The area a job with these settings is laid out on, and what the ticket's paper is matched from.
    pub fn area(&self, settings: &PrintSettings) -> PrintableArea {
        self.area_of(
            &settings.paper_id,
            wants_borderless(settings),
            self.match_type(settings),
        )
    }

    /// How far the printer's own edge reaches in on the paper the settings print on, 0 when the layout is borderless;
    /// none when the printer has no entry for the paper (or there is no printer), where the edge is only a guess.
    pub fn printer_edge(&self, settings: &PrintSettings) -> Option<f64> {
        let size = self.sheet(&settings.paper_id);
        self.printer?.media.match_entry(
            size,
            wants_borderless(settings),
            self.match_type(settings),
        )?;
        Some(edge_of(self.area(settings)))
    }

    /// The distance `MarginChoice::Printer` keeps clear: the edge of the bordered area, 0.25 in without an entry.
    pub fn printer_margin(&self, settings: &PrintSettings) -> f64 {
        let mut printer_edge = settings.clone();
        printer_edge.margin = MarginChoice::Printer;
        edge_of(self.area(&printer_edge))
    }

    /// The paper type a borderless entry has to suit: the chosen one, automatic when the printer picks.
    pub(crate) fn match_type<'a>(&self, settings: &'a PrintSettings) -> Option<&'a str> {
        Some(
            self.printer
                .and_then(|p| p.listed_type(settings))
                .unwrap_or(AUTO_MEDIA),
        )
    }

    fn layout_of(&self, settings: &PrintSettings) -> LayoutOptions {
        LayoutOptions {
            pages_per_sheet: u32::try_from(settings.pages_per_sheet).unwrap_or(0),
            booklet: settings.booklet,
            right_to_left: settings.right_to_left,
            scaling: settings.scaling,
            sides: settings.sides,
            page_borders: settings.page_borders,
            scale: settings.scale,
            orientation: settings.orientation,
            margin: settings
                .margin
                .points(settings.margin_mm(), self.printer_margin(settings)),
            margins: (settings.margin == MarginChoice::Printer)
                .then(|| self.area(settings).margins),
            poster: u32::try_from(settings.poster).unwrap_or(0),
            cut_marks: settings.cut_marks,
            ..LayoutOptions::default()
        }
    }

    /// The layout the settings ask for.
    pub fn layout_options(&self, settings: &PrintSettings) -> LayoutOptions {
        let options = self.layout_of(settings);
        match photo_size(&settings.photo_size_id).size {
            Some(print) if size_fits(&options, self.area(settings), print) => LayoutOptions {
                cell_size: Some(print),
                ..options
            },
            _ => options,
        }
    }

    /// The print sizes a picker offers: those that fit one cell at the pages per side, paper, margin and orientation
    /// in use, then "Largest that fits". A saved size that no longer fits is planned as the last, and the settings keep
    /// it.
    pub fn photo_sizes(&self, settings: &PrintSettings) -> Vec<&'static PhotoSize> {
        let options = self.layout_of(settings);
        let area = self.area(settings);
        PHOTO_SIZES
            .iter()
            .filter(|p| p.size.is_none_or(|size| size_fits(&options, area, size)))
            .collect()
    }

    /// The sheets of a job. The pages of all documents run on as one, and `page_range` (0-based, as the page range
    /// parser gives it) counts along that run; an index past its end is skipped. The settings' odd or even pages and
    /// reverse order come next, before the layout. A printer without two-sided gets the fronts and the backs as two
    /// passes, the backs turned and ordered for the learnt paper path.
    pub fn plan(
        &self,
        documents: &[LoadedDocument],
        page_range: Option<&[usize]>,
        settings: &PrintSettings,
        paper_path: &PaperPath,
    ) -> JobPlan {
        let all: Vec<SourcePage> = documents
            .iter()
            .enumerate()
            .flat_map(|(d, doc)| {
                (0..doc.pages.len()).map(move |i| SourcePage {
                    document: d,
                    index: i,
                    size: doc.size(i),
                })
            })
            .collect();
        let chosen: Vec<usize> = match page_range {
            Some(range) => range.iter().copied().filter(|&i| i < all.len()).collect(),
            None => (0..all.len()).collect(),
        };
        let pages: Vec<SourcePage> =
            pick_pages(&chosen, settings.page_selection, settings.reverse_order)
                .into_iter()
                .map(|i| all[i])
                .collect();

        let options = self.layout_options(settings);
        let manual = is_duplex(&options) && !self.printer.is_some_and(JobPrinter::can_two_sided);
        let backs_turned_after = manual && paper_path.turn_backs;
        let plan = plan_sheets(
            &pages,
            &LayoutOptions {
                backs_turned_after,
                ..options
            },
            self.area(settings),
        );
        let passes = if manual {
            let (fronts, backs) = manual_passes(&plan, paper_path);
            vec![fronts, backs]
        } else {
            let sides = plan
                .sheets
                .iter()
                .flat_map(|s| std::iter::once(s.front.clone()).chain(s.back.clone()))
                .collect();
            vec![DuplexPass {
                sides,
                marked: Vec::new(),
            }]
        };

        let can_collate = !settings.collate || self.printer.is_some_and(JobPrinter::collates);
        let copies = plan_copies(
            settings.copies,
            self.printer.map(|p| p.copies_upper),
            plan.side_count(),
            can_collate,
        );
        let notes = self.notes(&plan.warnings, settings);
        JobPlan {
            plan,
            manual_duplex: manual,
            passes,
            copies_in_job: copies.ticket_copies,
            notes,
        }
    }

    fn notes(&self, warnings: &[PlanWarning], settings: &PrintSettings) -> Vec<String> {
        let mut notes: Vec<String> = warnings
            .iter()
            .map(|w| match w {
                PlanWarning::PaddedWithBlanks(n) => {
                    format!("{n} blank page{} added", if *n == 1 { "" } else { "s" })
                }
                PlanWarning::Clipped(points) => {
                    let mm = ((points * 25.4 / 72.0).round_ties_even() as i64).max(1);
                    format!("Edges cut off ({mm} mm)")
                }
            })
            .collect();
        if settings.color == ColorChoice::Color
            && self
                .printer
                .is_some_and(JobPrinter::prints_gray_only_with_mono)
        {
            notes.push("Printed in gray: this printer has no color".into());
        }
        notes
    }
}

/// Whether the layout asks for the paper without margins: margin None. The printer may have no such entry, then its
/// edge stays.
pub fn wants_borderless(settings: &PrintSettings) -> bool {
    settings.margin == MarginChoice::None
}

/// The first ready paper of the printer that has a fixed size (media-col-ready, else media-ready), portrait, in points.
fn loaded(printer: &JobPrinter) -> Option<LayoutSize> {
    let media = &printer.media;
    if let Some(entry) = media
        .media_col_ready
        .iter()
        .find(|e| !e.is_variable && e.width > 0 && e.height > 0)
    {
        let (w, h) = (
            MediaEntry::hundredths_to_points(entry.width),
            MediaEntry::hundredths_to_points(entry.height),
        );
        return Some(LayoutSize {
            width: w.min(h),
            height: w.max(h),
        });
    }
    media
        .media_ready
        .iter()
        .filter_map(|n| pwg_size(n))
        .find(|s| s.width > 0.0)
}
