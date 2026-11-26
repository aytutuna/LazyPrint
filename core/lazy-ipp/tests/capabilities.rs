//! The cases of the C# and Swift PrinterCapabilitiesTests, DocumentFormatsTests, IppRetryTests
//! (the timing rules), IppStatusTests and the TXT record tests, read from the same printer fixtures.

mod common;

use common::{PRINTERS, fixture, printer};
use lazy_ipp::capabilities::*;
use lazy_ipp::formats::{self, DocumentKind};
use lazy_ipp::job::{Job, JobState, QueuedJobState, queued_jobs};
use lazy_ipp::retry::RetryPolicy;
use lazy_ipp::status::{self, status_name};
use lazy_ipp::txt::{TxtRecord, uuid_key};
use lazy_ipp::{Attribute, Group, Message, Value, Version, tag};
use std::time::Duration;

const A4: (f64, f64) = (210.0 * 72.0 / 25.4, 297.0 * 72.0 / 25.4);
const LETTER: (f64, f64) = (612.0, 792.0);
const PHOTO_4X6: (f64, f64) = (288.0, 432.0);

fn caps(name: &str) -> Capabilities {
    Capabilities::from_message(&Message::decode(&printer(name)).unwrap().0)
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| s.to_string()).collect()
}

fn message(groups: Vec<Group>) -> Message {
    Message {
        version: Version::V20,
        code: 0,
        request_id: 1,
        groups,
    }
}

fn printer_group(attributes: Vec<Attribute>) -> Group {
    Group {
        tag: tag::PRINTER_ATTRIBUTES,
        attributes,
    }
}

fn int(name: &str, n: i32) -> Attribute {
    Attribute::one(name, Value::Integer(n))
}

fn entry(margin: i32, media_type: Option<&str>) -> MediaEntry {
    MediaEntry {
        attributes: vec![],
        width: 21000,
        height: 29700,
        is_variable: false,
        margins: Some(MediaMargins {
            top: margin,
            left: margin,
            bottom: margin,
            right: margin,
        }),
        media_type: media_type.map(String::from),
        source: None,
    }
}

fn with_database(entries: Vec<MediaEntry>) -> Capabilities {
    Capabilities {
        media_col_database: entries,
        ..Default::default()
    }
}

#[test]
fn hp_laserjet_is_read_as_a_mono_duplex_laser() {
    let caps = caps("hp-laserjet");
    assert_eq!(caps.name, "HPA1B2C3");
    assert_eq!(caps.make_and_model, "HP LaserJet Pro M404dn");
    assert_eq!(
        caps.uuid.as_deref(),
        Some("4509a320-00a0-008f-00b6-9c93b9a1c2d3")
    );
    assert!(caps.speaks_20());
    assert_eq!(caps.state, PrinterState::Idle);
    assert_eq!(caps.state_reasons, ["none"]);
    assert!(caps.is_accepting_jobs);
    for format in ["application/pdf", "image/pwg-raster", "image/urf"] {
        assert!(caps.document_formats_supported.iter().any(|f| f == format));
    }
    assert_eq!(caps.print_color_modes_supported, ["monochrome"]);
    assert!(
        caps.sides_supported
            .iter()
            .any(|s| s == "two-sided-long-edge")
    );
    assert_eq!(caps.copies_supported, (1, 999));
    assert!(
        caps.multiple_document_handling_supported
            .iter()
            .any(|s| s == "separate-documents-collated-copies")
    );
    assert!(caps.media_col_supported.iter().any(|s| s == "media-size"));
    assert_eq!(caps.media_col_database.len(), 8);
    assert_eq!(caps.media_col_ready.len(), 1);
    assert_eq!(caps.media_ready, ["na_letter_8.5x11in"]);
    assert_eq!(caps.print_quality_supported, [3, 4, 5]);
    assert!(caps.print_scaling_supported.iter().any(|s| s == "fit"));
    assert_eq!(caps.output_bin_default.as_deref(), Some("face-down"));
    assert_eq!(caps.output_trays.len(), 1);
    assert!(caps.output_trays[0].starts_with("type=unRemovableBin"));
    assert_eq!(caps.pwg_raster_resolutions, [(300, 300), (600, 600)]);
    assert_eq!(caps.pwg_raster_types, ["sgray_8"]);
    assert_eq!(caps.pwg_raster_sheet_back.as_deref(), Some("rotated"));
    assert!(caps.urf_supported.iter().any(|s| s == "RS600"));
    assert_eq!(caps.more_info.as_deref(), Some("http://192.168.1.20:80"));
    assert!(caps.supply_info_uri.is_some());
    assert_eq!(
        caps.supplies,
        [MarkerSupply {
            name: "Black Cartridge HP CF259A".into(),
            color: "#000000".into(),
            supply_type: "toner-cartridge".into(),
            level: 60,
            low_level: Some(10),
            high_level: Some(100),
        }]
    );
}

#[test]
fn the_hp_letter_entry_gives_its_margins() {
    let caps = caps("hp-laserjet");
    let entry = caps.match_paper(LETTER, false, None).unwrap();
    assert_eq!((entry.width, entry.height), (21590, 27940));
    assert_eq!(
        entry.margins,
        Some(MediaMargins {
            top: 423,
            left: 423,
            bottom: 423,
            right: 423
        })
    );
    assert_eq!(entry.media_type.as_deref(), Some("stationery"));
    assert_eq!(entry.source.as_deref(), Some("tray-1"));
    assert!((points(entry.width) - 612.0).abs() < 0.5);
    assert!((points(423) - 423.0 * 72.0 / 2540.0).abs() < 1e-9);
}

#[test]
fn epson_ecotank_has_borderless_photo_entries() {
    let caps = caps("epson-ecotank");
    assert_eq!(caps.name, "EPSON ET-4850 Series");
    assert_eq!(
        caps.document_formats_supported,
        [
            "image/urf",
            "image/pwg-raster",
            "image/jpeg",
            "application/octet-stream"
        ]
    );
    assert_eq!(caps.print_color_modes_supported, ["color", "monochrome"]);
    assert_eq!(caps.media_col_database.len(), 12);
    assert_eq!(caps.pwg_raster_resolutions, [(360, 360), (720, 720)]);
    assert_eq!(caps.pwg_raster_types, ["srgb_8", "sgray_8"]);
    assert_eq!(caps.pwg_raster_sheet_back.as_deref(), Some("normal"));
    let names: Vec<&str> = caps.supplies.iter().map(|s| s.name.as_str()).collect();
    assert_eq!(names, ["Black", "Cyan", "Magenta", "Yellow"]);
    let levels: Vec<i32> = caps.supplies.iter().map(|s| s.level).collect();
    assert_eq!(levels, [80, 55, 40, 70]);
    assert_eq!(caps.supplies[2].color, "#FF00FF");

    let variable = caps.media_col_database.last().unwrap();
    assert!(variable.is_variable);
    assert_eq!((variable.width, variable.height), (21590, 129700));
}

#[test]
fn epson_match_picks_borderless_or_bordered_entries() {
    let caps = caps("epson-ecotank");
    let plain = caps.match_paper(A4, false, None).unwrap();
    assert_eq!(
        plain.margins,
        Some(MediaMargins {
            top: 300,
            left: 300,
            bottom: 300,
            right: 300
        })
    );
    assert_eq!(plain.media_type.as_deref(), Some("stationery"));

    let borderless = caps.match_paper(A4, true, None).unwrap();
    assert!(borderless.margins.unwrap().is_zero());
    assert_eq!(
        borderless.media_type.as_deref(),
        Some("photographic-glossy")
    );

    let photo = caps.match_paper(PHOTO_4X6, true, None).unwrap();
    assert_eq!((photo.width, photo.height), (10160, 15240));
    assert_eq!(photo.source.as_deref(), Some("photo"));
}

#[test]
fn an_entrys_printer_side_members_are_not_what_a_job_sends() {
    let caps = caps("epson-ecotank");
    let plain = caps.match_paper(A4, false, None).unwrap();
    let names: Vec<&str> = plain.attributes.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "media-bottom-margin",
            "media-left-margin",
            "media-right-margin",
            "media-size",
            "media-source",
            "media-top-margin",
            "media-type"
        ]
    );
    let size = plain
        .attributes
        .iter()
        .find(|a| a.name == "media-size")
        .unwrap();
    let Value::Collection(members) = &size.values[0] else {
        panic!("media-size is not a collection")
    };
    let member_names: Vec<&str> = members.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(member_names, ["x-dimension", "y-dimension"]);
}

#[test]
fn only_the_members_the_media_col_supported_list_names_are_kept() {
    let entry = Value::Collection(vec![
        int("media-top-margin", 300),
        int("media-bottom-margin", 300),
        Attribute::one("media-type", Value::Keyword("stationery".into())),
        int("media-source", 1),
        Attribute::one(
            "media-size",
            Value::Collection(vec![int("x-dimension", 21000), int("y-dimension", 29700)]),
        ),
    ]);
    let caps = Capabilities::from_message(&message(vec![printer_group(vec![
        Attribute::keywords(
            "media-col-supported",
            &["media-size", "media-top-margin", "media-type"],
        ),
        Attribute::one("media-col-database", entry),
    ])]));
    let names: Vec<&str> = caps.media_col_database[0]
        .attributes
        .iter()
        .map(|a| a.name.as_str())
        .collect();
    assert_eq!(names, ["media-top-margin", "media-type", "media-size"]);
}

#[test]
fn when_only_the_other_kind_exists_match_falls_back_to_it() {
    let caps = caps("hp-laserjet");
    assert!(
        !caps
            .match_paper(LETTER, true, None)
            .unwrap()
            .margins
            .unwrap()
            .is_zero()
    );
    assert!(caps.match_paper((100.0, 100.0), false, None).is_none());
}

#[test]
fn borderless_only_suits_a_matching_paper_type() {
    let caps = caps("epson-ecotank");
    let zero = |e: Option<&MediaEntry>| e.unwrap().margins.unwrap().is_zero();
    assert!(zero(caps.match_paper(A4, true, None)));
    assert!(zero(caps.match_paper(
        A4,
        true,
        Some("photographic-glossy")
    )));
    assert!(!zero(caps.match_paper(A4, true, Some("stationery"))));
    assert!(!zero(caps.match_paper(A4, true, Some(AUTO_MEDIA))));

    let untyped = with_database(vec![entry(300, Some("stationery")), entry(0, None)]);
    assert!(zero(untyped.match_paper(A4, true, Some("stationery"))));
    let plain = with_database(vec![
        entry(300, Some("stationery")),
        entry(0, Some("stationery")),
    ]);
    assert!(zero(plain.match_paper(A4, true, Some(AUTO_MEDIA))));
    let inkjet = with_database(vec![
        entry(300, Some("stationery")),
        entry(0, Some("stationery-inkjet")),
    ]);
    assert!(zero(inkjet.match_paper(A4, true, Some(AUTO_MEDIA))));
    let only_borderless = with_database(vec![entry(0, Some("photographic-glossy"))]);
    assert!(zero(only_borderless.match_paper(
        A4,
        false,
        Some(AUTO_MEDIA)
    )));
}

#[test]
fn a_borderless_entry_that_does_not_suit_is_the_last_resort() {
    let only = with_database(vec![entry(0, Some("photographic-glossy"))]);
    for borderless in [true, false] {
        let found = only.match_paper(A4, borderless, Some(AUTO_MEDIA)).unwrap();
        assert_eq!(found.media_type.as_deref(), Some("photographic-glossy"));
    }
}

#[test]
fn brother_laser_speaks_11_only_and_takes_pwg_and_pdf() {
    let caps = caps("brother-laser");
    assert_eq!(caps.name, "BRN30055C7A1B2C");
    assert_eq!(
        caps.uuid.as_deref(),
        Some("e3248000-80ce-11db-8000-30055c7a1b2c")
    );
    assert_eq!(
        caps.ipp_versions_supported,
        [
            Version { major: 1, minor: 0 },
            Version { major: 1, minor: 1 }
        ]
    );
    assert!(!caps.speaks_20());
    assert_eq!(
        caps.document_formats_supported,
        [
            "application/octet-stream",
            "image/pwg-raster",
            "application/pdf"
        ]
    );
    assert!(caps.print_scaling_supported.is_empty());
    assert!(caps.multiple_document_handling_supported.is_empty());
    assert!(caps.urf_supported.is_empty());
    assert_eq!(caps.pwg_raster_sheet_back.as_deref(), Some("flipped"));
    assert_eq!(caps.media_col_database.len(), 6);
    assert_eq!(caps.supplies[0].level, 75);
}

#[test]
fn canon_pixma_is_airprint_only_with_low_ink() {
    let caps = caps("canon-pixma");
    assert_eq!(caps.name, "Canon TS5350 series");
    assert_eq!(caps.make_and_model, "Canon TS5300 series");
    assert_eq!(
        caps.document_formats_supported,
        ["image/urf", "image/jpeg", "application/pdf"]
    );
    assert!(caps.pwg_raster_resolutions.is_empty());
    assert!(caps.pwg_raster_types.is_empty());
    assert!(caps.pwg_raster_sheet_back.is_none());
    assert!(caps.urf_supported.iter().any(|s| s == "RS600"));
    assert_eq!(caps.state_reasons, ["marker-supply-low-warning"]);
    assert_eq!(caps.supplies[1].level, 8);
    assert_eq!(caps.supplies[1].low_level, Some(10));
    assert_eq!(caps.media_source_supported, ["main", "photo"]);
    let borderless = caps.match_paper(PHOTO_4X6, true, None).unwrap();
    assert_eq!(
        borderless.media_type.as_deref(),
        Some("photographic-glossy")
    );
}

#[test]
fn missing_attributes_give_defaults() {
    let caps = Capabilities::from_message(&message(vec![]));
    assert_eq!(caps, Capabilities::default());
    assert_eq!(caps.name, "");
    assert!(caps.uuid.is_none());
    assert_eq!(caps.state, PrinterState::Idle);
    assert!(caps.is_accepting_jobs);
    assert_eq!(caps.copies_supported, (1, 1));
    assert!(!caps.speaks_20());
    assert!(caps.match_paper(A4, false, None).is_none());
}

#[test]
fn wrong_types_and_odd_values_are_read_leniently() {
    let message = message(vec![
        printer_group(vec![
            Attribute::one("printer-name", Value::Name(String::new())),
            Attribute::one("printer-info", Value::Text("Office".into())),
            Attribute::one("printer-state", Value::Enum(5)),
            Attribute::one("printer-is-accepting-jobs", Value::Bool(false)),
            int("copies-supported", 20),
            Attribute::new(
                "ipp-versions-supported",
                vec![
                    Value::Keyword("2.0".into()),
                    Value::Keyword("x.y".into()),
                    Value::Integer(3),
                ],
            ),
            Attribute::new(
                "sides-supported",
                vec![Value::Integer(1), Value::Keyword("one-sided".into())],
            ),
            Attribute::one(
                "pwg-raster-document-resolution-supported",
                Value::Resolution {
                    x: 118,
                    y: 118,
                    units: 4,
                },
            ),
            Attribute::new(
                "marker-names",
                vec![Value::Name("Black".into()), Value::Name("Cyan".into())],
            ),
            int("marker-levels", -3),
            Attribute::one(
                "media-col-database",
                Value::Collection(vec![Attribute::one(
                    "media-type",
                    Value::Keyword("stationery".into()),
                )]),
            ),
        ]),
        Group {
            tag: tag::UNSUPPORTED_ATTRIBUTES,
            attributes: vec![Attribute::one("printer-state", Value::Enum(3))],
        },
    ]);
    let caps = Capabilities::from_message(&message);
    assert_eq!(caps.name, "Office");
    assert_eq!(caps.state, PrinterState::Stopped);
    assert!(!caps.is_accepting_jobs);
    assert_eq!(caps.copies_supported, (1, 20));
    assert_eq!(
        caps.ipp_versions_supported,
        [Version { major: 2, minor: 0 }]
    );
    assert_eq!(caps.sides_supported, ["one-sided"]);
    assert_eq!(caps.pwg_raster_resolutions, [(300, 300)]);
    assert!(caps.media_col_database.is_empty());
    assert_eq!(caps.supplies[0].level, -3);
    assert_eq!(caps.supplies[1].level, -1);
    assert_eq!(caps.supplies[1].low_level, None);
}

#[test]
fn media_supported_and_the_custom_range_are_read() {
    let size = |x: Value, y: Value| {
        Value::Collection(vec![
            Attribute::one("x-dimension", x),
            Attribute::one("y-dimension", y),
        ])
    };
    let caps = Capabilities::from_message(&message(vec![printer_group(vec![
        Attribute::keywords(
            "media-supported",
            &["iso_a4_210x297mm", "na_ledger_11x17in"],
        ),
        Attribute::new(
            "media-size-supported",
            vec![
                size(Value::Integer(21000), Value::Integer(29700)),
                size(Value::Range(7620, 21590), Value::Range(12700, 35560)),
            ],
        ),
    ])]));
    assert_eq!(
        caps.media_supported,
        ["iso_a4_210x297mm", "na_ledger_11x17in"]
    );
    let range = PaperRange {
        min_width: 7620,
        max_width: 21590,
        min_height: 12700,
        max_height: 35560,
    };
    assert_eq!(caps.custom_paper, Some(range));
    assert!(range.accepts(LETTER));
    assert!(!range.accepts((10.0, 10.0)));
    let (w, h) = range.clamp((10.0, 2000.0));
    assert!((w - points(7620)).abs() < 1e-9 && (h - points(35560)).abs() < 1e-9);
}

#[test]
fn without_a_range_there_is_no_custom_size() {
    let caps = Capabilities::from_message(&message(vec![printer_group(vec![])]));
    assert!(caps.custom_paper.is_none());
}

#[test]
fn the_custom_range_falls_back_to_the_min_and_max_names() {
    let caps =
        Capabilities::from_message(&message(vec![printer_group(vec![Attribute::keywords(
            "media-supported",
            &[
                "iso_a4_210x297mm",
                "custom_min_3x5in",
                "custom_max_8.5x14in",
            ],
        )])]));
    let range = PaperRange {
        min_width: 7620,
        max_width: 21590,
        min_height: 12700,
        max_height: 35560,
    };
    assert_eq!(caps.custom_paper, Some(range));
    assert!(custom_range_from_names(&strings(&["custom_min_3x5in"])).is_none());
}

#[test]
fn every_fixture_chooses_the_format_the_other_platforms_do() {
    let formats_of = |name: &str| caps(name).document_formats_supported;
    for (name, can_write_pdf, expected) in [
        ("hp-laserjet", false, formats::PWG_RASTER),
        ("hp-laserjet", true, formats::PDF),
        ("epson-ecotank", false, formats::PWG_RASTER),
        ("brother-laser", false, formats::PWG_RASTER),
        ("canon-pixma", false, formats::URF),
        ("canon-pixma", true, formats::PDF),
    ] {
        assert_eq!(
            formats::choose(&formats_of(name), DocumentKind::Imposed, can_write_pdf),
            Some(expected),
            "{name} {can_write_pdf}"
        );
    }
    let photo = |name: &str| formats::choose(&formats_of(name), DocumentKind::Photo, false);
    assert_eq!(photo("hp-laserjet"), Some(formats::JPEG));
    assert_eq!(photo("epson-ecotank"), Some(formats::JPEG));
    assert_eq!(photo("brother-laser"), Some(formats::PWG_RASTER));
    assert_eq!(photo("canon-pixma"), Some(formats::JPEG));
}

#[test]
fn choose_follows_the_table() {
    use formats::{JPEG, PDF, PWG_RASTER as PWG, URF};
    let plain = DocumentKind::Pdf { encrypted: false };
    let locked = DocumentKind::Pdf { encrypted: true };
    let cases: Vec<(Vec<&str>, DocumentKind, bool, Option<&str>)> = vec![
        (vec![PDF, PWG, URF], plain, false, Some(PDF)),
        (vec![PDF, PWG, URF], plain, true, Some(PDF)),
        (vec![PWG, URF], plain, false, Some(PWG)),
        (vec![URF, JPEG], plain, true, Some(URF)),
        (vec![PDF, PWG, URF], locked, false, Some(PWG)),
        (vec![PDF, PWG, URF], locked, true, Some(PDF)),
        (vec![PDF], locked, false, None),
        (
            vec![PDF, PWG, URF, JPEG],
            DocumentKind::Photo,
            false,
            Some(JPEG),
        ),
        (
            vec![PDF, PWG, URF, JPEG],
            DocumentKind::Photo,
            true,
            Some(JPEG),
        ),
        (vec![URF, PDF], DocumentKind::Photo, false, Some(URF)),
        (vec![URF, PDF], DocumentKind::Photo, true, Some(PDF)),
        (vec![PDF, PWG, URF], DocumentKind::Imposed, true, Some(PDF)),
        (vec![PDF, PWG, URF], DocumentKind::Imposed, false, Some(PWG)),
        (vec![PDF, URF], DocumentKind::Imposed, false, Some(URF)),
        (vec![PDF, JPEG], DocumentKind::Imposed, false, None),
        (vec![URF, JPEG, PDF], DocumentKind::Imposed, true, Some(PDF)),
        (vec![URF, JPEG], DocumentKind::Imposed, true, Some(URF)),
        (
            vec!["IMAGE/PWG-RASTER"],
            DocumentKind::Imposed,
            false,
            Some(PWG),
        ),
        (vec![], plain, true, None),
        (
            vec!["application/octet-stream"],
            DocumentKind::Imposed,
            true,
            None,
        ),
    ];
    for (supported, kind, can_write_pdf, expected) in cases {
        let supported = strings(&supported);
        assert_eq!(
            formats::choose(&supported, kind, can_write_pdf),
            expected,
            "{supported:?} {kind:?} {can_write_pdf}"
        );
    }
}

#[test]
fn a_refused_format_is_retried_as_raster() {
    assert!(formats::retries_as_raster(0x040A));
    assert!(formats::retries_as_raster(0x0411));
    assert!(formats::retries_as_raster(0x041B));
    assert!(!formats::retries_as_raster(0x0400));
    assert!(!formats::retries_as_raster(0x0507));
}

#[test]
fn backoff_grows_by_half_and_caps_at_five_seconds() {
    let policy = RetryPolicy::default();
    let seconds: Vec<f64> = (0..8)
        .map(|i| policy.delay_before(i, None).as_secs_f64())
        .collect();
    assert_eq!(
        seconds,
        [0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875, 5.0, 5.0]
    );
}

#[test]
fn retry_after_is_honored_within_the_bounds() {
    let policy = RetryPolicy::default();
    assert_eq!(
        policy.delay_before(0, Some(Duration::from_secs(2))),
        Duration::from_secs(2)
    );
    assert_eq!(
        policy.delay_before(0, Some(Duration::from_secs(120))),
        Duration::from_secs(5)
    );
    assert_eq!(
        policy.delay_before(3, Some(Duration::ZERO)),
        Duration::from_millis(500)
    );
}

#[test]
fn status_names_are_the_keyword_or_the_number() {
    for (code, name) in [
        (0x0000, "successful-ok"),
        (0x0001, "successful-ok-ignored-or-substituted-attributes"),
        (0x0406, "client-error-not-found"),
        (0x040A, "client-error-document-format-not-supported"),
        (0x0411, "client-error-document-format-error"),
        (0x041B, "client-error-document-unprintable-error"),
        (0x0503, "server-error-version-not-supported"),
        (0x0506, "server-error-not-accepting-jobs"),
        (0x0507, "server-error-busy"),
        (0x0999, "0x0999"),
    ] {
        assert_eq!(status_name(code), name);
    }
    assert_eq!(status::CLIENT_ERROR_NOT_AUTHENTICATED, 0x0402);
    assert_eq!(status::CLIENT_ERROR_NOT_FETCHABLE, 0x0420);
    assert_eq!(status::SERVER_ERROR_TOO_MANY_DOCUMENTS, 0x050C);
}

fn hp_txt() -> Vec<String> {
    let text = String::from_utf8(fixture("txt-hp.txt")).unwrap();
    text.lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

#[test]
fn the_txt_record_reads_the_ipp_keys() {
    let txt = TxtRecord::parse(&hp_txt());
    assert_eq!(txt.resource_path, "ipp/print");
    assert_eq!(txt.model.as_deref(), Some("HP Color LaserJet MFP M479fdw"));
    assert_eq!(
        txt.product.as_deref(),
        Some("(HP Color LaserJet MFP M479fdw)")
    );
    assert_eq!(
        txt.uuid.as_deref(),
        Some("564e4333-4230-3538-3930-a0b3cce51a2b")
    );
    assert_eq!(
        txt.admin_url.as_deref(),
        Some("http://HPA1B2C3.local./#hId-pgAirPrint")
    );
    assert_eq!(txt.note.as_deref(), Some("Office"));
    assert_eq!((txt.color, txt.duplex), (Some(true), Some(true)));
    assert_eq!(
        txt.document_formats,
        [
            "application/octet-stream",
            "application/pdf",
            "image/jpeg",
            "image/urf",
            "image/pwg-raster"
        ]
    );
    assert_eq!(
        txt.urf,
        [
            "CP1",
            "MT1-2-8-9-10-11",
            "OB10",
            "PQ3-4-5",
            "RS300-600",
            "SRGB24",
            "W8",
            "DM1",
            "IS1-4",
            "V1.4",
            "IFU0"
        ]
    );
    assert_eq!(txt.tls.as_deref(), Some("1.2"));
    assert_eq!(txt.kind, ["document", "envelope", "photo"]);
    assert_eq!(txt.paper_max.as_deref(), Some("legal-A4"));
}

#[test]
fn the_txt_record_defaults_and_odd_entries() {
    let empty = TxtRecord::parse::<&str>(&[]);
    assert_eq!(empty.resource_path, "ipp/print");
    assert!(empty.model.is_none() && empty.uuid.is_none());
    assert!(empty.color.is_none() && empty.duplex.is_none());
    assert!(empty.document_formats.is_empty() && empty.urf.is_empty());

    let odd = TxtRecord::parse(&[
        "RP=/printers/office/",
        "ty=First",
        "ty=Second",
        "duplex=f",
        "flag",
        "=novalue",
        "kind=Document, PHOTO ,document",
        "URF=none",
    ]);
    assert_eq!(odd.resource_path, "printers/office");
    assert_eq!(odd.model.as_deref(), Some("First"));
    assert_eq!(odd.duplex, Some(false));
    assert_eq!(odd.kind, ["document", "photo"]);
    assert!(odd.urf.is_empty());

    assert_eq!(TxtRecord::parse(&["rp="]).resource_path, "");
    assert_eq!(TxtRecord::parse(&["Color=maybe"]).color, None);
}

#[test]
fn uuid_keys_compare_the_forms_printers_use() {
    let key = Some("564e4333423035383930a0b3cce51a2b".to_string());
    for uuid in [
        "564E4333-4230-3538-3930-A0B3CCE51A2B",
        "urn:uuid:564e4333-4230-3538-3930-a0b3cce51a2b",
        "{564e4333-4230-3538-3930-a0b3cce51a2b}",
    ] {
        assert_eq!(uuid_key(Some(uuid)), key);
    }
    assert_eq!(uuid_key(Some("  ")), None);
    assert_eq!(uuid_key(None), None);
}

fn job_message(attributes: Vec<Attribute>) -> Message {
    message(vec![Group {
        tag: tag::JOB_ATTRIBUTES,
        attributes,
    }])
}

#[test]
fn a_job_is_read_from_a_response() {
    let response = job_message(vec![
        int("job-id", 7),
        Attribute::one("job-state", Value::Enum(5)),
        Attribute::keywords("job-state-reasons", &["job-printing", "none"]),
        int("job-impressions-completed", 2),
    ]);
    let job = Job::from_message(&response, None).unwrap();
    assert_eq!(
        job,
        Job {
            id: 7,
            state: JobState::Processing,
            reasons: strings(&["job-printing", "none"]),
            impressions: 2
        }
    );
    assert!(!job.is_finished());
    let finished = Job::from_message(
        &job_message(vec![Attribute::one("job-state", Value::Enum(9))]),
        Some(3),
    )
    .unwrap();
    assert_eq!((finished.id, finished.is_finished()), (3, true));
    assert!(Job::from_message(&job_message(vec![]), None).is_none());
    let odd = Job::from_message(
        &job_message(vec![Attribute::one("job-state", Value::Enum(42))]),
        Some(1),
    )
    .unwrap();
    assert_eq!(odd.state, JobState::Unknown);
}

#[test]
fn queued_jobs_keep_the_unfinished_ones_and_mark_the_users_own() {
    let job = |id: i32, state: i32, owner: &str| Group {
        tag: tag::JOB_ATTRIBUTES,
        attributes: vec![
            int("job-id", id),
            Attribute::one("job-state", Value::Enum(state)),
            Attribute::one("job-name", Value::Name(format!("Job {id}"))),
            Attribute::one("job-originating-user-name", Value::Name(owner.into())),
        ],
    };
    let response = message(vec![
        job(1, 5, "Anna"),
        job(2, 3, "bob"),
        job(3, 9, "anna"),
        job(4, 4, "anna"),
    ]);
    let jobs = queued_jobs(&response, "anna");
    let summary: Vec<(i32, QueuedJobState, bool)> =
        jobs.iter().map(|j| (j.id, j.state, j.can_cancel)).collect();
    assert_eq!(
        summary,
        [
            (1, QueuedJobState::Printing, true),
            (2, QueuedJobState::Waiting, false),
            (4, QueuedJobState::Held, true)
        ]
    );
}

#[test]
fn every_printer_fixture_gives_a_name() {
    for name in PRINTERS {
        assert!(!caps(name).name.is_empty(), "{name}");
    }
}

#[test]
fn a_user_is_matched_to_their_jobs_whatever_the_case_of_their_letters() {
    let job = |owner: &str| Group {
        tag: tag::JOB_ATTRIBUTES,
        attributes: vec![
            int("job-id", 1),
            Attribute::one("job-state", Value::Enum(3)),
            Attribute::one("job-originating-user-name", Value::Name(owner.into())),
        ],
    };
    let jobs = queued_jobs(&message(vec![job("AYŞE")]), "Ayşe");
    assert!(jobs[0].can_cancel);
}

#[test]
fn a_range_the_printer_gave_upside_down_does_not_panic_when_a_sheet_is_fitted() {
    let range = PaperRange {
        min_width: 30000,
        max_width: 10000,
        min_height: 40000,
        max_height: 10000,
    };
    let (w, h) = range.clamp(LETTER);
    assert!(w.is_finite() && h.is_finite());
    assert!(!range.accepts(LETTER));
}
