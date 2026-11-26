//! The cases of the C# and Swift IppProblemsTests.

mod common;

use common::printer;
use lazy_ipp::Message;
use lazy_ipp::capabilities::Capabilities;
use lazy_ipp::problems::{Problem, describe};

fn reasons(list: &[&str]) -> Vec<Problem> {
    let list: Vec<String> = list.iter().map(|r| r.to_string()).collect();
    describe(&list, None, true)
}

#[test]
fn a_known_reason_gives_title_and_severity() {
    let cases = [
        ("media-empty", "Out of paper", true),
        ("media-empty-error", "Out of paper", true),
        ("media-empty-warning", "Out of paper", false),
        ("media-empty-report", "Out of paper", false),
        ("media-needed", "Out of paper", false),
        ("media-needed-error", "Out of paper", true),
        ("media-jam", "Paper jam", true),
        ("media-jam-warning", "Paper jam", false),
        ("cover-open", "Cover open", true),
        ("door-open-error", "Cover open", true),
        ("marker-supply-empty", "Ink empty", true),
        ("marker-supply-empty-warning", "Ink empty", false),
        ("marker-supply-low", "Ink low", false),
        ("marker-supply-low-warning", "Ink low", false),
        ("marker-supply-low-error", "Ink low", true),
        ("toner-empty-error", "Toner empty", true),
        ("toner-low-report", "Toner low", false),
        ("paused", "Printer paused", true),
        ("output-area-full-error", "Output tray full", true),
        ("marker-waste-full-error", "Waste tank full", true),
        (
            "document-format-error",
            "Printer can't print this file",
            true,
        ),
        (
            "document-unprintable-error",
            "Printer can't print this file",
            true,
        ),
        (
            "document-access-error",
            "Printer couldn't read the file",
            true,
        ),
        ("job-canceled-at-device", "Canceled at the printer", true),
        ("job-canceled-by-user", "Canceled at the printer", true),
        ("aborted-by-system", "Printer stopped the job", true),
        ("job-completed-with-errors", "Printed with errors", false),
    ];
    for (reason, title, is_error) in cases {
        let problems = reasons(&[reason]);
        assert_eq!(problems.len(), 1, "{reason}");
        assert_eq!(problems[0].title, title, "{reason}");
        assert_eq!(problems[0].is_error, is_error, "{reason}");
        assert!(!problems[0].advice.is_empty(), "{reason}");
    }
}

#[test]
fn none_is_nothing() {
    assert!(reasons(&["none"]).is_empty());
    assert!(reasons(&[]).is_empty());
}

#[test]
fn unknown_reasons_without_an_error_suffix_are_left_out() {
    let unknown = [
        "connecting-to-device",
        "other-warning",
        "spool-area-full",
        "timed-out-report",
    ];
    assert!(reasons(&unknown).is_empty());
}

#[test]
fn an_unknown_error_is_a_printer_error_with_the_printers_message() {
    let list = vec!["fuser-over-temp-error".to_string()];
    let problems = describe(&list, Some(" Fuser too hot "), true);
    assert_eq!(problems.len(), 1);
    assert_eq!(problems[0].title, "Printer error");
    assert_eq!(problems[0].advice, "Fuser too hot");
    assert!(problems[0].is_error);
    let plain = describe(&list, Some(""), true);
    assert_eq!(plain[0].advice, "Check the printer's display.");
}

#[test]
fn errors_come_first_and_each_kind_once() {
    let problems = reasons(&[
        "toner-low-report",
        "media-empty-warning",
        "media-jam",
        "media-empty-error",
        "media-empty-error",
        "marker-supply-low",
    ]);
    let titles: Vec<_> = problems.iter().map(|p| p.title.as_str()).collect();
    let errors: Vec<_> = problems.iter().map(|p| p.is_error).collect();
    assert_eq!(
        titles,
        [
            "Paper jam",
            "Out of paper",
            "Toner low",
            "Out of paper",
            "Ink low"
        ]
    );
    assert_eq!(errors, [true, true, false, false, false]);
}

#[test]
fn an_unreachable_printer_is_offline_alone() {
    let list = vec!["media-jam".to_string()];
    let problems = describe(&list, None, false);
    assert_eq!(problems.len(), 1);
    assert_eq!(problems[0].title, "Printer offline");
    assert!(problems[0].is_error);
}

#[test]
fn the_texts_of_the_contract() {
    assert_eq!(
        reasons(&["media-empty-error"])[0].advice,
        "Load paper in the tray, then press Resume."
    );
}

#[test]
fn the_canon_fixture_is_low_ink_without_an_error() {
    let message = Message::decode(&printer("canon-pixma")).unwrap().0;
    let caps = Capabilities::from_message(&message);
    let problems = describe(&caps.state_reasons, Some(&caps.state_message), true);
    assert_eq!(problems.len(), 1);
    assert_eq!(problems[0].title, "Ink low");
    assert!(!problems[0].is_error);
}
