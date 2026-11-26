use lazyprint_jobs::*;
use lazyprint_layout::{LayoutSize, MarginChoice, PaperPath};
use lazyprint_paper::{MediaEntry, MediaMargins, PrinterMedia};
use lazyprint_settings::PrintSettings;

fn letter(margin: i32) -> MediaEntry {
    MediaEntry {
        width: 21590,
        height: 27940,
        is_variable: false,
        margins: Some(MediaMargins {
            top: margin,
            left: margin,
            bottom: margin,
            right: margin,
        }),
        media_type: None,
        source: None,
        attributes: Vec::new(),
    }
}

fn printer(documents_borderless: bool) -> JobPrinter {
    JobPrinter {
        documents_borderless,
        media: PrinterMedia {
            media_col_database: vec![letter(423), letter(0)],
            ..PrinterMedia::default()
        },
        ..JobPrinter::default()
    }
}

fn borderless_settings() -> PrintSettings {
    let mut settings = PrintSettings::default();
    settings.margin = MarginChoice::None;
    settings.paper_id = "letter".into();
    settings
}

fn page() -> Vec<LayoutSize> {
    vec![LayoutSize {
        width: 612.0,
        height: 792.0,
    }]
}

#[test]
fn airprint_keeps_the_edge_for_documents_and_drops_it_for_photos() {
    let airprint = printer(false);
    let context = JobContext {
        printer: Some(&airprint),
        region: None,
    };
    let settings = borderless_settings();
    let pdf = [LoadedDocument::new(
        "a",
        DocumentKind::Pdf { encrypted: false },
        page(),
    )];
    let photo = [LoadedDocument::new("b", DocumentKind::Photo, page())];
    assert!(photos_only(&photo));
    assert!(!photos_only(&pdf));
    assert!(!photos_only(&[]));
    assert!(!photos_only(&[pdf[0].clone(), photo[0].clone()]));

    assert!(context.area(&settings, false).margins.top > 0.0);
    assert!(context.printer_edge(&settings, false).unwrap() > 0.0);
    assert_eq!(context.area(&settings, true).margins.top, 0.0);
    assert_eq!(context.printer_edge(&settings, true), Some(0.0));

    let path = PaperPath::default();
    let plan = context.plan(&pdf, None, &settings, &path);
    assert!(plan.plan.area.margins.top > 0.0);
    let plan = context.plan(&photo, None, &settings, &path);
    assert_eq!(plan.plan.area.margins.top, 0.0);
}

#[test]
fn other_printers_and_no_printer_ask_for_borderless() {
    let full = printer(true);
    let settings = borderless_settings();
    let with = JobContext {
        printer: Some(&full),
        region: None,
    };
    assert_eq!(with.area(&settings, false).margins.top, 0.0);
    assert!(with.wants_borderless(&settings, false));
    assert!(JobContext::default().wants_borderless(&settings, false));
}

#[test]
fn an_absurd_ready_size_is_not_the_sheet() {
    let mut ready = letter(0);
    ready.width = i32::MAX;
    ready.height = i32::MAX;
    let hostile = JobPrinter {
        media: PrinterMedia {
            media_col_ready: vec![ready],
            ..PrinterMedia::default()
        },
        ..JobPrinter::default()
    };
    let context = JobContext {
        printer: Some(&hostile),
        region: None,
    };
    let sheet = context.sheet("auto");
    assert!(sheet.width < 2000.0 && sheet.height < 2000.0, "{sheet:?}");
}
