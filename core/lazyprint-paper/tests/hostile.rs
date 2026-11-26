use lazyprint_layout::LayoutSize;
use lazyprint_paper::*;

#[test]
fn an_inverted_range_is_refused_and_clamping_never_panics() {
    let names = ["custom_min_300x100mm", "custom_max_100x300mm"];
    assert_eq!(custom_range(names), None);
    let inverted = PaperRange {
        min_width: 30000,
        max_width: 10000,
        min_height: 10000,
        max_height: 30000,
    };
    let clamped = inverted.clamp(LayoutSize {
        width: 600.0,
        height: 700.0,
    });
    assert!(clamped.width.is_finite() && clamped.height.is_finite());
}

#[test]
fn names_with_absurd_sizes_are_not_sizes() {
    assert_eq!(pwg_size("om_x_1e999x1e999mm"), None);
    assert_eq!(pwg_size("om_x_1e300x1e300mm"), None);
    let digits = "9".repeat(400);
    assert_eq!(pwg_size(&format!("om_x_{digits}x{digits}mm")), None);
    assert_eq!(media_size(&format!("Custom.{digits}x{digits}")), None);
    assert!(pwg_size("iso_a4_210x297mm").is_some());
}

fn entry(width: i32, height: i32, margins: Option<MediaMargins>) -> MediaEntry {
    MediaEntry {
        width,
        height,
        is_variable: false,
        margins,
        media_type: None,
        source: None,
        attributes: Vec::new(),
    }
}

fn margins(top: i32, left: i32, bottom: i32, right: i32) -> Option<MediaMargins> {
    Some(MediaMargins {
        top,
        left,
        bottom,
        right,
    })
}

#[test]
fn the_custom_range_stops_at_ten_metres_and_so_does_what_it_writes() {
    let range = custom_range(["custom_min_100x100mm", "custom_max_90000x90000mm"]).unwrap();
    assert_eq!(range.max_width, 1_000_000);
    let printer = PrinterMedia {
        custom_paper: Some(range),
        ..PrinterMedia::default()
    };
    let id = custom_size_id(90000.0, 90000.0, None, Some(&printer));
    assert!(points_of(Some(&id)).is_some(), "{id}");
}

#[test]
fn entries_with_absurd_sizes_or_margins_are_skipped() {
    let printer = PrinterMedia {
        media_col_database: vec![
            entry(i32::MAX, 29700, margins(0, 0, 0, 0)),
            entry(21000, 29700, margins(-500, 0, 0, 0)),
            entry(21000, 29700, margins(15000, 0, 15000, 0)),
            entry(21000, 29700, margins(300, 300, 300, 300)),
        ],
        ..PrinterMedia::default()
    };
    let a4 = media_size("iso_a4_210x297mm").unwrap();
    assert_eq!(printer.listed().len(), 1);
    let found = printer.match_entry(a4, false, None).unwrap();
    assert_eq!(found.margins, margins(300, 300, 300, 300));
    assert_eq!(printer.match_entry(a4, true, None), Some(found));
    assert!(
        entry(i32::MAX, 29700, margins(0, 0, 0, 0))
            .printable_area()
            .is_none()
    );
}

#[test]
fn a_printer_listing_thousands_of_sizes_is_cut_short() {
    let printer = PrinterMedia {
        media_col_database: (1..=5000)
            .map(|i| entry(10000 + i * 10, 20000, None))
            .collect(),
        ..PrinterMedia::default()
    };
    assert!(printer.listed().len() <= 500);
}
