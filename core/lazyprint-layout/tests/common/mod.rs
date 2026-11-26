#![allow(dead_code)]

use lazyprint_layout::*;
use serde_json::Value;

pub const TOLERANCE: f64 = 1e-9;

pub fn num(v: &Value) -> f64 {
    v.as_f64().unwrap()
}

pub fn nums(v: &Value) -> Vec<f64> {
    v.as_array().unwrap().iter().map(num).collect()
}

pub fn size(v: &Value) -> LayoutSize {
    let n = nums(v);
    LayoutSize {
        width: n[0],
        height: n[1],
    }
}

pub fn rect(v: &Value) -> LayoutRect {
    let n = nums(v);
    LayoutRect {
        x: n[0],
        y: n[1],
        width: n[2],
        height: n[3],
    }
}

pub fn insets(v: &Value) -> LayoutInsets {
    let n = nums(v);
    LayoutInsets {
        top: n[0],
        left: n[1],
        bottom: n[2],
        right: n[3],
    }
}

pub fn area(v: &Value) -> PrintableArea {
    PrintableArea {
        paper: size(&v["paper"]),
        margins: insets(&v["margins"]),
    }
}

pub fn pages(v: &Value) -> Vec<SourcePage> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|p| {
            let n = nums(p);
            SourcePage {
                document: n[0] as usize,
                index: n[1] as usize,
                size: LayoutSize {
                    width: n[2],
                    height: n[3],
                },
            }
        })
        .collect()
}

pub fn enum_of<T: serde::de::DeserializeOwned>(v: &Value) -> T {
    serde_json::from_value(v.clone()).unwrap()
}

pub fn options(v: &Value) -> LayoutOptions {
    LayoutOptions {
        pages_per_sheet: v["pagesPerSheet"].as_u64().unwrap() as u32,
        booklet: v["booklet"].as_bool().unwrap(),
        right_to_left: v["rightToLeft"].as_bool().unwrap(),
        scaling: enum_of(&v["scaling"]),
        sides: enum_of(&v["sides"]),
        page_borders: v["pageBorders"].as_bool().unwrap(),
        scale: v["scale"].as_i64().unwrap() as i32,
        orientation: enum_of(&v["orientation"]),
        margin: num(&v["margin"]),
        margins: (!v["margins"].is_null()).then(|| insets(&v["margins"])),
        backs_turned_after: v["backsTurnedAfter"].as_bool().unwrap(),
        poster: v["poster"].as_u64().unwrap() as u32,
        cell_size: (!v["cellSize"].is_null()).then(|| size(&v["cellSize"])),
        cut_marks: v["cutMarks"].as_bool().unwrap(),
    }
}

pub fn close(a: f64, b: f64, what: &str) {
    assert!((a - b).abs() <= TOLERANCE, "{what}: {a} is not {b}");
}

pub fn same_rect(a: LayoutRect, b: LayoutRect, what: &str) {
    close(a.x, b.x, what);
    close(a.y, b.y, what);
    close(a.width, b.width, what);
    close(a.height, b.height, what);
}

pub fn same_side(got: &SheetSide, want: &Value, what: &str) {
    assert_eq!(
        got.borders,
        want["borders"].as_bool().unwrap(),
        "{what}: borders"
    );
    let placements = want["placements"].as_array().unwrap();
    assert_eq!(got.placements.len(), placements.len(), "{what}: placements");
    for (g, w) in got.placements.iter().zip(placements) {
        let page = nums(&w["page"]);
        assert_eq!(
            (g.page.document, g.page.index),
            (page[0] as usize, page[1] as usize),
            "{what}: page"
        );
        same_rect(g.frame, rect(&w["frame"]), &format!("{what}: frame"));
        assert_eq!(
            u64::from(g.turns),
            w["turns"].as_u64().unwrap(),
            "{what}: turns"
        );
        match (&g.crop, &w["crop"]) {
            (None, Value::Null) => {}
            (Some(c), w) if !w.is_null() => same_rect(*c, rect(w), &format!("{what}: crop")),
            (g, w) => panic!("{what}: crop {g:?} is not {w}"),
        }
    }
    let cuts = want["cutCells"].as_array().unwrap();
    assert_eq!(got.cut_cells.len(), cuts.len(), "{what}: cut cells");
    for (g, w) in got.cut_cells.iter().zip(cuts) {
        same_rect(*g, rect(w), &format!("{what}: cut cell"));
    }
}

pub fn same_plan(got: &SheetPlan, want: &Value, what: &str) {
    assert_eq!(
        got.duplex,
        want["duplex"].as_bool().unwrap(),
        "{what}: duplex"
    );
    assert_eq!(
        i64::from(got.printed_scale),
        want["printedScale"].as_i64().unwrap(),
        "{what}: printed scale"
    );
    let warnings = want["warnings"].as_array().unwrap();
    assert_eq!(got.warnings.len(), warnings.len(), "{what}: warnings");
    for (g, w) in got.warnings.iter().zip(warnings) {
        match (g, w["kind"].as_str().unwrap()) {
            (PlanWarning::Clipped(p), "clipped") => close(*p, num(&w["points"]), what),
            (PlanWarning::PaddedWithBlanks(c), "padded") => {
                assert_eq!(*c as u64, w["count"].as_u64().unwrap(), "{what}")
            }
            (g, k) => panic!("{what}: warning {g:?} is not {k}"),
        }
    }
    let sheets = want["sheets"].as_array().unwrap();
    assert_eq!(got.sheets.len(), sheets.len(), "{what}: sheets");
    for (i, (g, w)) in got.sheets.iter().zip(sheets).enumerate() {
        same_side(&g.front, &w["front"], &format!("{what} sheet {i} front"));
        match (&g.back, &w["back"]) {
            (None, Value::Null) => {}
            (Some(b), w) if !w.is_null() => same_side(b, w, &format!("{what} sheet {i} back")),
            _ => panic!("{what}: sheet {i} back differs"),
        }
    }
}
