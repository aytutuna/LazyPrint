use crate::{JobContext, JobPlan, JobPrinter};
use lazyprint_layout::{LayoutInsets, LayoutSize, PrintableArea, Scaling, Sides};
use lazyprint_paper::{AUTO_MEDIA, MediaMember, MemberValue, match_size};
use lazyprint_settings::{ColorChoice, PrintSettings, QualityChoice};

/// The paper of a job: the media-col members to send (none when the printer picks from the name) and the PWG name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaChoice {
    pub entry: Option<Vec<MediaMember>>,
    pub name: String,
}

/// What a job asks of the printer. `sides` is "one-sided" or "two-sided-long-edge" ("two-sided-short-edge" only for a
/// document sent as is), `color_mode` "color" or "monochrome", `quality` 3, 4 or 5 when chosen, `scaling` "none" for
/// imposed sheets and "fit", "auto-fit" or "auto" for a document sent as is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobTicket {
    pub job_name: String,
    pub document_format: String,
    pub copies: i32,
    pub sides: String,
    pub color_mode: String,
    pub media: MediaChoice,
    pub quality: Option<i32>,
    pub scaling: Option<String>,
    pub collated_copies: bool,
}

/// A job of this session, as the Jobs tab lists it. The names are the contract's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Preparing,
    Sending,
    Waiting,
    Printing,
    Done,
    Failed,
    Canceled,
    NeedsUser,
}

impl JobState {
    pub fn name(self) -> &'static str {
        match self {
            Self::Preparing => "Preparing",
            Self::Sending => "Sending",
            Self::Waiting => "Waiting",
            Self::Printing => "Printing",
            Self::Done => "Done",
            Self::Failed => "Failed",
            Self::Canceled => "Canceled",
            Self::NeedsUser => "NeedsUser",
        }
    }
}

fn hundredths(points: f64) -> i32 {
    (points * 2540.0 / 72.0).round_ties_even() as i32
}

fn is_photo_type(m: &MediaMember) -> bool {
    m.name == "media-type"
        && matches!(m.values.first(), Some(MemberValue::Keyword(v)) if v.starts_with("photographic"))
}

/// The tray and type, when asked for and the media-col takes them, in place of the entry's own, except that an entry's
/// own photo type stays when the type was left on automatic.
fn choose(
    mut members: Vec<MediaMember>,
    supported: &[String],
    media_type: Option<&str>,
    source: Option<&str>,
    auto_type: bool,
) -> Vec<MediaMember> {
    let takes = |member: &str| supported.is_empty() || supported.iter().any(|s| s == member);
    if let Some(t) = media_type
        && takes("media-type")
        && !(auto_type && members.iter().any(is_photo_type))
    {
        members.retain(|m| m.name != "media-type");
        members.push(MediaMember::keyword("media-type", t));
    }
    if let Some(s) = source
        && takes("media-source")
    {
        members.retain(|m| m.name != "media-source");
        members.push(MediaMember::keyword("media-source", s));
    }
    members
}

/// A PWG self-describing media name: the one the printer lists for the sheet, else the standard one of a named size,
/// else a custom one in millimetres.
fn media_name(paper: LayoutSize, printer: Option<&JobPrinter>) -> String {
    if let Some(name) = printer.and_then(|p| p.media.listed_name(paper)) {
        return name.to_string();
    }
    match match_size(paper) {
        Some(size) => size.pwg.to_string(),
        None => format!(
            "custom_sheet_{}x{}mm",
            (paper.width * 25.4 / 72.0).round_ties_even() as i32,
            (paper.height * 25.4 / 72.0).round_ties_even() as i32
        ),
    }
}

fn print_scaling(
    scaling: Scaling,
    printer: Option<&JobPrinter>,
    as_is: bool,
    borderless: bool,
) -> Option<String> {
    let wanted: &[&str] = match scaling {
        _ if !as_is || !borderless => &["none"],
        Scaling::Fit => &["fit", "auto"],
        Scaling::ShrinkToFit => &["auto-fit", "fit"],
        _ => &["none"],
    };
    let listed = printer.map_or(&[][..], |p| &p.print_scaling_supported);
    wanted
        .iter()
        .find(|w| listed.iter().any(|l| l == **w))
        .map(|w| (*w).to_string())
}

impl JobContext<'_> {
    /// The ticket for a printer's Print-Job. The paper is the printer's database entry for the sheet size (borderless
    /// when the layout assumed no margins), so the margins are the ones laid out; sheets are asked for as they were
    /// planned (no scaling, two-sided on the long edge whatever the flip, since the planner turns the backs), and a
    /// manual pass is one-sided. Quality, scaling and the copies' collation are asked for only when the printer lists
    /// them. A paper the printer has no entry for is sent as a media-col with the margins laid out when it lists
    /// media-col-supported. A document `as_is` on borderless media is the printer's to scale ("auto-fit" or "fit" for
    /// shrink to fit, "fit"; "auto" would fill zero-margin media); on bordered media it is only sent when nothing
    /// needs scaling, so it asks for none. It goes two-sided on the short edge when asked and listed.
    pub fn ticket(
        &self,
        job: &JobPlan,
        settings: &PrintSettings,
        format: &str,
        name: &str,
        as_is: bool,
    ) -> JobTicket {
        let printer = self.printer;
        let area = job.plan.area;

        let mut mode = if settings.color == ColorChoice::Gray {
            "monochrome"
        } else {
            "color"
        };
        if let Some(p) = printer
            && !p.color_modes.is_empty()
            && !p.color_modes.iter().any(|m| m == mode)
            && p.color_modes.iter().any(|m| m == "monochrome")
        {
            mode = "monochrome";
        }

        let quality = match settings.quality {
            QualityChoice::Draft => 3,
            QualityChoice::Best => 5,
            QualityChoice::Normal => 4,
        };
        let short_edge_listed = printer.is_some_and(|p| {
            p.sides_supported
                .iter()
                .any(|s| s == "two-sided-short-edge")
        });
        let sides = if !job.plan.duplex || job.manual_duplex {
            "one-sided"
        } else if as_is && settings.sides == Sides::ShortEdge && short_edge_listed {
            "two-sided-short-edge"
        } else {
            "two-sided-long-edge"
        };
        let borderless = area.margins == LayoutInsets::default();
        JobTicket {
            job_name: name.to_string(),
            document_format: format.to_string(),
            copies: job.copies_in_job,
            sides: sides.to_string(),
            color_mode: mode.to_string(),
            media: self.media(
                &area,
                self.match_type(settings),
                printer.and_then(|p| p.listed_type(settings)),
                printer.and_then(|p| p.listed_source(settings)),
                settings.media_type == AUTO_MEDIA,
            ),
            quality: printer
                .is_some_and(|p| p.print_quality_supported.contains(&quality))
                .then_some(quality),
            scaling: print_scaling(settings.scaling, printer, as_is, borderless),
            collated_copies: job.copies_in_job > 1
                && settings.collate
                && printer.is_some_and(JobPrinter::collates),
        }
    }

    /// The printer's database entry for the sheet, else a media-col of the sheet's size and margins, else its name.
    fn media(
        &self,
        area: &PrintableArea,
        match_type: Option<&str>,
        media_type: Option<&str>,
        source: Option<&str>,
        auto_type: bool,
    ) -> MediaChoice {
        let name = media_name(area.paper, self.printer);
        let none: &[String] = &[];
        let supported = self.printer.map_or(none, |p| &p.media_col_supported);
        let borderless = area.margins == LayoutInsets::default();
        if let Some(entry) = self
            .printer
            .and_then(|p| p.media.match_entry(area.paper, borderless, match_type))
        {
            let members = if entry.attributes.is_empty() {
                Vec::new()
            } else {
                choose(
                    entry.attributes.clone(),
                    supported,
                    media_type,
                    source,
                    auto_type,
                )
            };
            return MediaChoice {
                entry: Some(members),
                name,
            };
        }

        let mut members = vec![MediaMember {
            name: "media-size".into(),
            values: vec![MemberValue::Collection(vec![
                MediaMember::integer("x-dimension", hundredths(area.paper.width)),
                MediaMember::integer("y-dimension", hundredths(area.paper.height)),
            ])],
        }];
        let margins = [
            ("media-top-margin", area.margins.top),
            ("media-left-margin", area.margins.left),
            ("media-bottom-margin", area.margins.bottom),
            ("media-right-margin", area.margins.right),
        ];
        for (member, points) in margins {
            if supported.iter().any(|s| s == member) {
                members.push(MediaMember::integer(member, hundredths(points)));
            }
        }
        let members = choose(members, supported, media_type, source, auto_type);
        MediaChoice {
            entry: (members.len() > 1).then_some(members),
            name,
        }
    }
}
