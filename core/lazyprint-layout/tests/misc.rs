mod common;

use common::*;
use lazyprint_layout::*;
use serde_json::Value;

fn misc() -> Value {
    testdata_check::json("layout/misc.json")
}

fn strs(v: &Value) -> Vec<usize> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_u64().unwrap() as usize)
        .collect()
}

#[test]
fn margins_in_millimetres_and_points() {
    for case in misc()["margins"].as_array().unwrap() {
        let choice: MarginChoice = enum_of(&case["choice"]);
        let custom = case["custom"].as_f64().unwrap_or(0.0);
        let edge = num(&case["printerEdge"]);
        close(
            choice.millimetres(custom, edge),
            num(&case["millimetres"]),
            "mm",
        );
        close(choice.points(custom, edge), num(&case["points"]), "points");
    }
    for case in misc()["marginRound"].as_array().unwrap() {
        close(round_margin(num(&case["in"])), num(&case["out"]), "round");
    }
    assert_eq!(round_margin(f64::NAN), 0.0);
}

#[test]
fn the_old_small_margin_is_the_printers() {
    let choice: MarginChoice = serde_json::from_str("\"small\"").unwrap();
    assert_eq!(choice, MarginChoice::Printer);
    assert_eq!(
        serde_json::to_string(&MarginChoice::Printer).unwrap(),
        "\"printer\""
    );
}

#[test]
fn typed_page_ranges() {
    for case in misc()["pageRange"].as_array().unwrap() {
        let text = case["text"].as_str().unwrap();
        let got = parse_page_range(text, case["pageCount"].as_u64().unwrap() as usize);
        match case["error"].as_str() {
            Some(message) => assert_eq!(got, Err(message.to_string()), "{text:?}"),
            None => assert_eq!(got, Ok(strs(&case["pages"])), "{text:?}"),
        }
    }
}

#[test]
fn page_captions() {
    for case in misc()["pageLabel"].as_array().unwrap() {
        let placements: Vec<Placement> = case["placements"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                let p = strs(p);
                Placement {
                    page: SourcePage {
                        document: p[0],
                        index: p[1],
                        size: LayoutSize {
                            width: 1.0,
                            height: 1.0,
                        },
                    },
                    frame: LayoutRect::default(),
                    turns: 0,
                    crop: None,
                }
            })
            .collect();
        assert_eq!(
            page_label(&placements, &strs(&case["pageCounts"])),
            case["text"].as_str().unwrap()
        );
    }
}

#[test]
fn odd_even_and_reverse() {
    for case in misc()["pagePicker"].as_array().unwrap() {
        let got = pick_pages(
            &strs(&case["pages"]),
            enum_of(&case["selection"]),
            case["reverse"].as_bool().unwrap(),
        );
        assert_eq!(got, strs(&case["out"]), "{case}");
    }
}

#[test]
fn copies() {
    for case in misc()["copies"].as_array().unwrap() {
        let max = case["max"].as_i64().map(|m| m as i32);
        let got = plan_copies(
            case["requested"].as_i64().unwrap() as i32,
            max,
            case["pageCount"].as_u64().unwrap() as usize,
            case["canCollate"].as_bool().unwrap(),
        );
        assert_eq!(
            i64::from(got.ticket_copies),
            case["ticketCopies"].as_i64().unwrap(),
            "{case}"
        );
        assert_eq!(
            i64::from(got.document_repeats),
            case["documentRepeats"].as_i64().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn photo_sizes() {
    let want = &misc()["photoSizes"];
    let want = want.as_array().unwrap();
    assert_eq!(PHOTO_SIZES.len(), want.len());
    for (got, w) in PHOTO_SIZES.iter().zip(want) {
        assert_eq!(got.id, w["id"].as_str().unwrap());
        assert_eq!(got.title, w["title"].as_str().unwrap());
        match (got.size, &w["size"]) {
            (None, Value::Null) => {}
            (Some(s), w) if !w.is_null() => {
                close(s.width, size(w).width, got.id);
                close(s.height, size(w).height, got.id);
            }
            _ => panic!("{}", got.id),
        }
    }
    assert_eq!(photo_size("nonsense").id, "page");
}
