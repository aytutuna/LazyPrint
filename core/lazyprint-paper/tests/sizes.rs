use lazyprint_layout::LayoutSize;
use lazyprint_paper::*;
use serde_json::Value;

const TOLERANCE: f64 = 1e-9;

fn data() -> Value {
    testdata_check::json("paper/paper.json")
}

fn size(v: &Value) -> Option<LayoutSize> {
    let n = v.as_array()?;
    Some(LayoutSize {
        width: n[0].as_f64()?,
        height: n[1].as_f64()?,
    })
}

fn close(got: Option<LayoutSize>, want: Option<LayoutSize>, what: &str) {
    match (got, want) {
        (None, None) => {}
        (Some(g), Some(w)) => {
            assert!(
                (g.width - w.width).abs() <= TOLERANCE,
                "{what}: {g:?} is not {w:?}"
            );
            assert!(
                (g.height - w.height).abs() <= TOLERANCE,
                "{what}: {g:?} is not {w:?}"
            );
        }
        (g, w) => panic!("{what}: {g:?} is not {w:?}"),
    }
}

fn group(name: &str) -> PaperGroup {
    match name {
        "auto" => PaperGroup::Auto,
        "us" => PaperGroup::Us,
        "isoA" => PaperGroup::IsoA,
        "isoB" => PaperGroup::IsoB,
        "jisB" => PaperGroup::JisB,
        "photo" => PaperGroup::Photo,
        "card" => PaperGroup::Card,
        "envelope" => PaperGroup::Envelope,
        other => panic!("{other}"),
    }
}

#[test]
fn the_catalogue_is_the_references() {
    let data = data();
    let want = data["catalogue"].as_array().unwrap();
    assert_eq!(ALL.len(), want.len());
    for (got, w) in ALL.iter().zip(want) {
        assert_eq!(got.raw_value, w["raw"].as_str().unwrap());
        assert_eq!(got.pwg, w["pwg"].as_str().unwrap());
        assert_eq!(got.label, w["label"].as_str().unwrap());
        assert_eq!(got.group, group(w["group"].as_str().unwrap()));
        assert_eq!(got.psk, w["psk"].as_str());
        assert_eq!(got.detail(), w["detail"].as_str().unwrap());
        close(points(got), size(&w["points"]), got.raw_value);
    }
    let regions: Vec<&str> = data["letterRegions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r.as_str().unwrap())
        .collect();
    assert_eq!(regions, LETTER_REGIONS);
    for g in data["groupLabels"].as_array().unwrap() {
        assert_eq!(
            group_label(group(g["group"].as_str().unwrap())),
            g["label"].as_str().unwrap()
        );
    }
}

#[test]
fn stored_ids_are_read_without_regard_to_case_or_spaces() {
    for case in data()["parse"].as_array().unwrap() {
        assert_eq!(
            parse_paper_size(case["in"].as_str()).raw_value,
            case["raw"].as_str().unwrap(),
            "{case}"
        );
    }
    assert_eq!(parse_paper_size(None).raw_value, "auto");
}

#[test]
fn regions_choose_the_usual_paper_and_the_list_order() {
    for case in data()["regions"].as_array().unwrap() {
        let region = case["region"].as_str();
        assert_eq!(
            default_for_region(region).raw_value,
            case["default"].as_str().unwrap(),
            "{case}"
        );
        assert_eq!(
            uses_inches(region),
            case["usesInches"].as_bool().unwrap(),
            "{case}"
        );
        let raws = |sizes: Vec<&PaperSize>| {
            sizes
                .iter()
                .map(|s| s.raw_value.to_string())
                .collect::<Vec<_>>()
        };
        let list = |v: &Value| {
            v.as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap().to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(raws(common_for(region)), list(&case["common"]), "{case}");
        assert_eq!(raws(display_order(region)), list(&case["order"]), "{case}");
    }
}

#[test]
fn sheets_match_a_named_size_within_a_twentieth_of_an_inch() {
    for case in data()["match"].as_array().unwrap() {
        let sheet = size(&case["points"]).unwrap();
        assert_eq!(
            match_size(sheet).map(|s| s.raw_value),
            case["match"].as_str(),
            "{case}"
        );
        assert_eq!(name_of(sheet), case["name"].as_str(), "{case}");
        let portrait = LayoutSize {
            width: sheet.width.min(sheet.height),
            height: sheet.width.max(sheet.height),
        };
        assert_eq!(id_for(portrait), case["id"].as_str().unwrap(), "{case}");
    }
}

#[test]
fn sizes_fit_an_area() {
    for case in data()["fits"].as_array().unwrap() {
        let size_of = size_by_raw_value(case["size"].as_str().unwrap());
        assert_eq!(
            fits(size_of, size(&case["area"])),
            case["fits"].as_bool().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn media_names_are_read_like_the_reference() {
    for case in data()["names"].as_array().unwrap() {
        let name = case["in"].as_str().unwrap();
        close(
            pwg_size(name),
            size(&case["size"]),
            &format!("pwg {name:?}"),
        );
        close(
            media_size(name),
            size(&case["media"]),
            &format!("media {name:?}"),
        );
    }
}

#[test]
fn custom_ranges_come_from_the_min_and_max_names() {
    for case in data()["customRange"].as_array().unwrap() {
        let names: Vec<&str> = case["names"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n.as_str().unwrap())
            .collect();
        let want = case["range"].as_array().map(|r| {
            let n: Vec<i32> = r.iter().map(|v| v.as_i64().unwrap() as i32).collect();
            PaperRange {
                min_width: n[0],
                max_width: n[1],
                min_height: n[2],
                max_height: n[3],
            }
        });
        assert_eq!(custom_range(names.iter().copied()), want, "{case}");
    }
}

#[test]
fn ids_stand_for_sizes_and_labels() {
    for case in data()["ids"].as_array().unwrap() {
        let id = case["id"].as_str();
        close(points_of(id), size(&case["points"]), &format!("{id:?}"));
        assert_eq!(
            label_of(id, Some("CA")).as_deref(),
            case["label"].as_str(),
            "{case}"
        );
        assert_eq!(
            label_of(id, Some("GB")).as_deref(),
            case["labelMetric"].as_str(),
            "{case}"
        );
    }
}

#[test]
fn dimensions_in_the_regions_unit() {
    for case in data()["dimensions"].as_array().unwrap() {
        let sheet = size(&case["points"]).unwrap();
        let region = case["region"].as_str();
        let want = size(&case["dimensions"]).unwrap();
        let (w, h) = dimensions(sheet, region);
        assert_eq!((w, h), (want.width, want.height), "{case}");
        assert_eq!(
            dimension_text(sheet, region),
            case["text"].as_str().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn a_range_is_made_only_from_a_sane_span() {
    assert!(PaperRange::new(7620, 21590, 12700, 35560).is_some());
    assert!(PaperRange::new(21590, 7620, 12700, 35560).is_none());
    assert!(PaperRange::new(0, 21590, 12700, 35560).is_none());
    assert!(PaperRange::new(-1, 21590, 12700, 35560).is_none());
    assert!(PaperRange::new(1_000_001, 2_000_000, 1, 5).is_none());
    assert!(PaperRange::new(21000, 21000, 29700, 29700).is_none());
    assert_eq!(
        PaperRange::new(7620, i32::MAX, 12700, 35560)
            .unwrap()
            .max_width,
        1_000_000
    );
}
