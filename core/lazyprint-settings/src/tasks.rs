use crate::{AUTO, ColorChoice, PrintSettings, QualityChoice};
use lazyprint_layout::{MarginChoice, Scaling, Sides};
use std::collections::HashSet;

/// The built-in presets. A task's raw value is what settings keep.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrintTask {
    Document,
    TwoSided,
    Booklet,
    Handouts,
    Photos,
    PhotoSheet,
    TestPage,
    ScanAndPrint,
    FromPhone,
}

pub const ALL_TASKS: [PrintTask; 9] = [
    PrintTask::Document,
    PrintTask::TwoSided,
    PrintTask::Booklet,
    PrintTask::Handouts,
    PrintTask::Photos,
    PrintTask::PhotoSheet,
    PrintTask::TestPage,
    PrintTask::ScanAndPrint,
    PrintTask::FromPhone,
];

impl PrintTask {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Document => "document",
            Self::TwoSided => "twoSided",
            Self::Booklet => "booklet",
            Self::Handouts => "handouts",
            Self::Photos => "photos",
            Self::PhotoSheet => "photoSheet",
            Self::TestPage => "testPage",
            Self::ScanAndPrint => "scanAndPrint",
            Self::FromPhone => "fromPhone",
        }
    }

    /// The task stored as `raw`; none for any other text, such as a newer version's task.
    pub fn parse(raw: Option<&str>) -> Option<Self> {
        ALL_TASKS.into_iter().find(|t| Some(t.raw_value()) == raw)
    }
}

/// The groups of tasks, in the order the Preset menu shows them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskGroup {
    Documents,
    Photos,
    Other,
}

impl TaskGroup {
    pub fn title(self) -> &'static str {
        match self {
            Self::Documents => "Documents",
            Self::Photos => "Photos",
            Self::Other => "Other",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TaskDefinition {
    pub task: PrintTask,
    pub title: &'static str,
    /// What the task does, in one short line: the menu item's tooltip.
    pub subtitle: &'static str,
    /// Names the task's icon; each platform maps it to its own symbol.
    pub icon_key: &'static str,
    pub group: TaskGroup,
    /// The task starts by asking for files.
    pub opens_files: bool,
}

const fn def(
    task: PrintTask,
    title: &'static str,
    subtitle: &'static str,
    icon_key: &'static str,
    group: TaskGroup,
    opens_files: bool,
) -> TaskDefinition {
    TaskDefinition {
        task,
        title,
        subtitle,
        icon_key,
        group,
        opens_files,
    }
}

/// Every task, in menu order.
pub const TASKS: [TaskDefinition; 9] = [
    def(
        PrintTask::Document,
        "Print a document",
        "PDFs and images, one page per side.",
        "document",
        TaskGroup::Documents,
        true,
    ),
    def(
        PrintTask::TwoSided,
        "Two-sided",
        "Both sides of the paper, even without duplex.",
        "twoSided",
        TaskGroup::Documents,
        true,
    ),
    def(
        PrintTask::Booklet,
        "Booklet",
        "Pages in booklet order, to fold and staple.",
        "booklet",
        TaskGroup::Documents,
        true,
    ),
    def(
        PrintTask::Handouts,
        "Handouts",
        "Two pages on each side, with borders.",
        "handouts",
        TaskGroup::Documents,
        true,
    ),
    def(
        PrintTask::Photos,
        "Photo prints",
        "Photos at 4 × 6 or another size.",
        "photos",
        TaskGroup::Photos,
        true,
    ),
    def(
        PrintTask::PhotoSheet,
        "Photo sheet",
        "Four photos on a sheet, with cut marks.",
        "photoSheet",
        TaskGroup::Photos,
        true,
    ),
    def(
        PrintTask::TestPage,
        "Test page",
        "Check your printer with one page.",
        "testPage",
        TaskGroup::Other,
        false,
    ),
    def(
        PrintTask::ScanAndPrint,
        "Scan and print",
        "Scan with Lazy Scan, then print.",
        "scanAndPrint",
        TaskGroup::Other,
        false,
    ),
    def(
        PrintTask::FromPhone,
        "From your phone",
        "Print what your phone sends.",
        "fromPhone",
        TaskGroup::Other,
        false,
    ),
];

pub fn task_definition(task: PrintTask) -> &'static TaskDefinition {
    TASKS
        .iter()
        .find(|d| d.task == task)
        .expect("every task has a definition")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppPlatform {
    Windows,
    Mac,
    Ios,
}

/// The tasks the platform shows: the phone window is not on the iPhone.
pub fn tasks_for(platform: AppPlatform) -> Vec<&'static TaskDefinition> {
    TASKS
        .iter()
        .filter(|d| platform != AppPlatform::Ios || d.task != PrintTask::FromPhone)
        .collect()
}

/// What decides whether a task can be started.
#[derive(Clone, Copy, Debug)]
pub struct TaskContext {
    pub has_printer: bool,
    pub lazy_scan_installed: bool,
}

/// Whether a task can be started, and if not, why (the menu item's tooltip). The test page needs a printer and Scan
/// and print needs Lazy Scan; the rest can be started without a printer, which may still be found while the layout
/// shows.
pub fn task_availability(task: PrintTask, context: TaskContext) -> Result<(), &'static str> {
    match task {
        PrintTask::TestPage if !context.has_printer => Err("Needs a printer"),
        PrintTask::ScanAndPrint if !context.lazy_scan_installed => Err("Needs Lazy Scan"),
        _ => Ok(()),
    }
}

/// What a built-in preset asks of the printer.
#[derive(Clone, Copy, Debug, Default)]
pub struct TaskPrinter<'a> {
    pub two_sided_long_edge: bool,
    /// The paper types the printer lists.
    pub media_types: &'a [String],
}

/// The photo paper among `types`, plain photo paper first; none when there is none.
pub fn photo_media_type(types: &[String]) -> Option<&String> {
    const ORDER: [&str; 6] = [
        "photographic",
        "photographic-glossy",
        "photographic-semi-gloss",
        "photographic-satin",
        "photographic-matte",
        "photographic-high-gloss",
    ];
    ORDER
        .iter()
        .find_map(|o| types.iter().find(|t| t == o))
        .or_else(|| types.iter().find(|t| t.starts_with("photographic")))
}

/// The paper types a printer lists, without "auto".
fn listed_types(types: &[String]) -> Vec<String> {
    let mut seen: HashSet<&str> = HashSet::new();
    types
        .iter()
        .filter(|t| !t.is_empty() && *t != AUTO && seen.insert(t))
        .cloned()
        .collect()
}

/// A preset starts from the defaults; only the printer, its paper, tray, paper type and color, and this job's copies,
/// collation and page choices carry over.
pub fn apply_task(
    task: PrintTask,
    settings: &PrintSettings,
    printer: TaskPrinter,
) -> PrintSettings {
    let types = listed_types(printer.media_types);
    let mut s = PrintSettings {
        task_id: Some(task.raw_value().into()),
        printer_id: settings.printer_id.clone(),
        printer_name: settings.printer_name.clone(),
        paper_id: settings.paper_id.clone(),
        media_source: settings.media_source.clone(),
        media_type: kept_media_type(settings, &types),
        color: settings.color,
        copies: settings.copies,
        collate: settings.collate,
        page_selection: settings.page_selection,
        reverse_order: settings.reverse_order,
        ..PrintSettings::default()
    };
    let photo_type = |s: &PrintSettings| {
        if s.media_type == AUTO {
            photo_media_type(&types)
                .cloned()
                .unwrap_or_else(|| AUTO.into())
        } else {
            s.media_type.clone()
        }
    };
    match task {
        PrintTask::Document => {
            s.sides = if printer.two_sided_long_edge {
                Sides::LongEdge
            } else {
                Sides::OneSided
            };
            s
        }
        // A printer that can't turn the sheet itself gets two passes: the plan decides, not the setting.
        PrintTask::TwoSided => PrintSettings {
            sides: Sides::LongEdge,
            ..s
        },
        PrintTask::Booklet => PrintSettings {
            booklet: true,
            sides: Sides::LongEdge,
            ..s
        },
        PrintTask::Handouts => PrintSettings {
            pages_per_sheet: 2,
            page_borders: true,
            ..s
        },
        PrintTask::Photos => PrintSettings {
            photo_size_id: "4x6".into(),
            scaling: Scaling::Fill,
            cut_marks: true,
            margin: MarginChoice::None,
            quality: QualityChoice::Best,
            color: ColorChoice::Color,
            media_type: photo_type(&s),
            ..s
        },
        PrintTask::PhotoSheet => PrintSettings {
            pages_per_sheet: 4,
            scaling: Scaling::Fill,
            cut_marks: true,
            margin: MarginChoice::None,
            media_type: photo_type(&s),
            ..s
        },
        _ => PrintSettings {
            task_id: Some(task.raw_value().into()),
            ..settings.clone()
        },
    }
}

/// The paper type carries over, except the photo type a photo preset picked for itself.
fn kept_media_type(s: &PrintSettings, types: &[String]) -> String {
    let picked_by_photo_preset = matches!(s.task_id.as_deref(), Some("photos" | "photoSheet"))
        && Some(&s.media_type) == photo_media_type(types);
    if picked_by_photo_preset {
        AUTO.into()
    } else {
        s.media_type.clone()
    }
}
