//! The cases of the C# and Swift IppRequestsTests, against the same golden request files.

mod common;

use common::fixture;
use lazy_ipp::requests::*;
use lazy_ipp::{Attribute, Message, Value, Version, tag};
use lazyprint_paper::{MediaMember, MemberValue};

const URI: &str = "ipp://printer.local:631/ipp/print";

fn golden(name: &str, request: &Message) {
    assert_eq!(
        request.encode(),
        fixture(&format!("requests/{name}.bin")),
        "{name}"
    );
}

fn int(name: &str, n: i32) -> Attribute {
    Attribute::one(name, Value::Integer(n))
}

fn a4_entry() -> Vec<MediaMember> {
    vec![
        MediaMember::integer("media-bottom-margin", 300),
        MediaMember::integer("media-left-margin", 300),
        MediaMember::integer("media-right-margin", 300),
        MediaMember {
            name: "media-size".into(),
            values: vec![MemberValue::Collection(vec![
                MediaMember::integer("x-dimension", 21000),
                MediaMember::integer("y-dimension", 29700),
            ])],
        },
        MediaMember::keyword("media-source", "main"),
        MediaMember::integer("media-top-margin", 300),
        MediaMember::keyword("media-type", "stationery"),
    ]
}

fn ticket(name: &str) -> JobTicket {
    JobTicket {
        job_name: name.into(),
        document_format: "application/pdf".into(),
        copies: 1,
        sides: "one-sided".into(),
        color_mode: "color".into(),
        media: MediaChoice {
            entry: None,
            name: "iso_a4_210x297mm".into(),
        },
        quality: None,
        scaling: None,
        collated_copies: false,
        page_range: None,
    }
}

fn every_choice(quality: i32) -> JobTicket {
    JobTicket {
        job_name: "Sheets".into(),
        document_format: "image/pwg-raster".into(),
        copies: 3,
        sides: "two-sided-long-edge".into(),
        color_mode: "monochrome".into(),
        media: MediaChoice {
            entry: Some(a4_entry()),
            name: "iso_a4_210x297mm".into(),
        },
        quality: Some(quality),
        scaling: Some("none".into()),
        collated_copies: true,
        page_range: None,
    }
}

fn names(message: &Message, group: u8) -> Vec<&str> {
    let group = message.groups.iter().find(|g| g.tag == group).unwrap();
    group.attributes.iter().map(|a| a.name.as_str()).collect()
}

const OPERATION_START: [&str; 4] = [
    "attributes-charset",
    "attributes-natural-language",
    "printer-uri",
    "requesting-user-name",
];

fn operation_names(own: &[&'static str]) -> Vec<&'static str> {
    OPERATION_START.iter().chain(own).copied().collect()
}

#[test]
fn get_printer_attributes_is_the_golden_request() {
    golden(
        "get-printer-attributes",
        &get_printer_attributes(URI, "anna", 1),
    );
}

#[test]
fn get_printer_attributes_as_version_1_1_is_the_golden_request() {
    let request = downgraded(get_printer_attributes(URI, "anna", 1));
    assert_eq!(request.version, Version::V11);
    golden("get-printer-attributes-11", &request);
}

#[test]
fn get_printer_attributes_asks_for_all_and_the_media_database() {
    let request = get_printer_attributes(URI, "anna", 1);
    assert_eq!(
        names(&request, tag::OPERATION_ATTRIBUTES),
        operation_names(&["requested-attributes"])
    );
    assert_eq!(
        request.get("requested-attributes").unwrap().values,
        vec![
            Value::Keyword("all".into()),
            Value::Keyword("media-col-database".into())
        ]
    );
    assert_eq!(request.code, 0x000B);
    assert_eq!(request.version, Version::V20);
}

#[test]
fn print_job_with_a_name_is_the_golden_request() {
    golden(
        "print-job-pdf",
        &print_job(URI, "anna", &ticket("Report.pdf"), 1),
    );
}

#[test]
fn print_job_with_a_page_range_is_the_golden_request() {
    let mut t = ticket("Report.pdf");
    t.page_range = Some((2, 4));
    golden("print-job-page-ranges", &print_job(URI, "anna", &t, 1));
}

#[test]
fn get_printer_reasons_is_the_golden_request() {
    let request = get_printer_reasons(URI, "anna", 1);
    assert_eq!(
        request.get("requested-attributes").unwrap().values,
        vec![Value::Keyword("printer-state-reasons".into())]
    );
    golden("get-printer-reasons", &request);
}

#[test]
fn print_job_with_every_choice_is_the_golden_request() {
    golden(
        "print-job-media-col",
        &print_job(URI, "iPhone", &every_choice(5), 1),
    );
}

#[test]
fn print_job_with_a_long_non_ascii_name_is_the_golden_request() {
    let name = "日".repeat(100);
    golden(
        "print-job-long-name",
        &print_job(URI, "anna", &ticket(&name), 1),
    );
}

#[test]
fn print_job_attribute_order_follows_the_contract() {
    let request = print_job(URI, "anna", &every_choice(4), 1);
    assert_eq!(
        names(&request, tag::OPERATION_ATTRIBUTES),
        operation_names(&["job-name", "document-format"])
    );
    assert_eq!(
        names(&request, tag::JOB_ATTRIBUTES),
        [
            "copies",
            "sides",
            "print-color-mode",
            "media-col",
            "print-quality",
            "print-scaling",
            "multiple-document-handling"
        ]
    );
    let groups: Vec<u8> = request.groups.iter().map(|g| g.tag).collect();
    assert_eq!(groups, [tag::OPERATION_ATTRIBUTES, tag::JOB_ATTRIBUTES]);
    assert_eq!(request.first("print-quality"), Some(&Value::Enum(4)));
    assert_eq!(
        request.first("multiple-document-handling"),
        Some(&Value::Keyword("separate-documents-collated-copies".into()))
    );
}

#[test]
fn print_job_defaults_leave_out_the_optional_attributes() {
    let request = print_job(URI, "anna", &ticket("Report.pdf"), 1);
    assert_eq!(
        names(&request, tag::JOB_ATTRIBUTES),
        ["sides", "print-color-mode", "media"]
    );
    assert_eq!(
        request.first("media"),
        Some(&Value::Keyword("iso_a4_210x297mm".into()))
    );
    assert_eq!(request.code, 0x0002);
}

#[test]
fn a_media_entry_is_sent_verbatim_as_media_col() {
    let mut t = ticket("Report.pdf");
    t.media.entry = Some(a4_entry());
    let request = print_job(URI, "anna", &t, 1);
    assert!(request.get("media").is_none());
    let keyword = |name: &str, k: &str| Attribute::one(name, Value::Keyword(k.into()));
    let expected = vec![
        int("media-bottom-margin", 300),
        int("media-left-margin", 300),
        int("media-right-margin", 300),
        Attribute::one(
            "media-size",
            Value::Collection(vec![int("x-dimension", 21000), int("y-dimension", 29700)]),
        ),
        keyword("media-source", "main"),
        int("media-top-margin", 300),
        keyword("media-type", "stationery"),
    ];
    assert_eq!(
        request.first("media-col"),
        Some(&Value::Collection(expected))
    );
}

#[test]
fn get_job_attributes_is_the_golden_request() {
    let request = get_job_attributes(URI, "anna", 42, 1);
    assert_eq!(
        names(&request, tag::OPERATION_ATTRIBUTES),
        operation_names(&["job-id", "requested-attributes"])
    );
    golden("get-job-attributes", &request);
}

#[test]
fn get_jobs_is_the_golden_request() {
    let request = get_jobs(URI, "anna", 42);
    assert_eq!(
        names(&request, tag::OPERATION_ATTRIBUTES),
        operation_names(&["which-jobs", "requested-attributes"])
    );
    golden("get-jobs", &request);
}

#[test]
fn cancel_job_is_the_golden_request() {
    let request = cancel_job(URI, "anna", 42, 1);
    assert_eq!(
        names(&request, tag::OPERATION_ATTRIBUTES),
        operation_names(&["job-id"])
    );
    golden("cancel-job", &request);
}

#[test]
fn the_printer_uri_is_always_ipp_or_ipps() {
    for (typed, sent) in [
        (
            "http://printer.local/ipp/print",
            "ipp://printer.local/ipp/print",
        ),
        (
            "HTTPS://printer.local:443/ipp/print",
            "ipps://printer.local:443/ipp/print",
        ),
        (
            "ipp://printer.local:631/ipp/print",
            "ipp://printer.local:631/ipp/print",
        ),
        (
            "ipps://printer.local/ipp/print",
            "ipps://printer.local/ipp/print",
        ),
    ] {
        let request = cancel_job(typed, "anna", 1, 1);
        assert_eq!(request.first("printer-uri"), Some(&Value::Uri(sent.into())));
    }
}

#[test]
fn names_are_cut_at_255_bytes_without_splitting_a_character() {
    assert_eq!(truncated("short"), "short");
    assert_eq!(truncated(&"a".repeat(300)).len(), 255);

    let cjk = truncated(&"日".repeat(100));
    assert_eq!(cjk.chars().count(), 85);
    assert_eq!(cjk.len(), 255);

    let emoji = truncated(&format!("a{}", "\u{1F600}".repeat(100)));
    assert_eq!(emoji.chars().count(), 1 + 63);
    assert_eq!(emoji.len(), 253);
}

#[test]
fn names_are_cut_in_the_request() {
    let request = print_job(URI, &"u".repeat(400), &ticket(&"n".repeat(400)), 1);
    let Some(Value::Name(job)) = request.first("job-name") else {
        panic!("no job-name")
    };
    let Some(Value::Name(user)) = request.first("requesting-user-name") else {
        panic!("no user name")
    };
    assert_eq!((job.len(), user.len()), (255, 255));
}
