use lazyprint_layout::LayoutSize;
use lazyprint_paper::*;
use serde_json::Value;

fn data() -> Value {
    testdata_check::json("paper/paper.json")
}

fn size(v: &Value) -> LayoutSize {
    let n = v.as_array().unwrap();
    LayoutSize {
        width: n[0].as_f64().unwrap(),
        height: n[1].as_f64().unwrap(),
    }
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

fn entries(v: &Value) -> Vec<MediaEntry> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|e| MediaEntry {
            width: e["width"].as_i64().unwrap() as i32,
            height: e["height"].as_i64().unwrap() as i32,
            is_variable: e["isVariable"].as_bool().unwrap(),
            margins: e["margins"].as_array().map(|m| {
                let n: Vec<i32> = m.iter().map(|x| x.as_i64().unwrap() as i32).collect();
                MediaMargins {
                    top: n[0],
                    left: n[1],
                    bottom: n[2],
                    right: n[3],
                }
            }),
            media_type: e["type"].as_str().map(str::to_string),
            source: e["source"].as_str().map(str::to_string),
        })
        .collect()
}

fn media(v: &Value) -> PrinterMedia {
    PrinterMedia {
        media_col_database: entries(&v["mediaColDatabase"]),
        media_col_ready: entries(&v["mediaColReady"]),
        media_ready: strings(&v["mediaReady"]),
        media_supported: strings(&v["mediaSupported"]),
        custom_paper: v["customPaper"].as_array().map(|r| {
            let n: Vec<i32> = r.iter().map(|x| x.as_i64().unwrap() as i32).collect();
            PaperRange {
                min_width: n[0],
                max_width: n[1],
                min_height: n[2],
                max_height: n[3],
            }
        }),
    }
}

fn sheets_close(got: LayoutSize, want: LayoutSize) -> bool {
    (got.width - want.width).abs() < 1e-9 && (got.height - want.height).abs() < 1e-9
}

#[test]
fn printers_list_their_sizes() {
    for (i, p) in data()["printers"].as_array().unwrap().iter().enumerate() {
        let printer = media(&p["media"]);
        let want: Vec<LayoutSize> = p["listed"].as_array().unwrap().iter().map(size).collect();
        let got = printer.listed();
        assert_eq!(got.len(), want.len(), "printer {i}");
        assert!(
            got.iter().zip(&want).all(|(g, w)| sheets_close(*g, *w)),
            "printer {i}: {got:?}"
        );
        for s in p["supports"].as_array().unwrap() {
            let paper = size(&s["paper"]);
            assert_eq!(
                printer.supports(paper),
                s["supports"].as_bool().unwrap(),
                "printer {i}: {s}"
            );
            assert_eq!(
                printer.listed_name(paper),
                s["listedName"].as_str(),
                "printer {i}: {s}"
            );
        }
    }
}

#[test]
fn database_entries_match_a_paper_the_way_the_reference_does() {
    for (i, p) in data()["printers"].as_array().unwrap().iter().enumerate() {
        let printer = media(&p["media"]);
        for m in p["match"].as_array().unwrap() {
            let got = printer.match_entry(
                size(&m["paper"]),
                m["borderless"].as_bool().unwrap(),
                m["type"].as_str(),
            );
            match (got, &m["entry"]) {
                (None, Value::Null) => {}
                (Some(e), want) if !want.is_null() => {
                    assert_eq!(
                        i64::from(e.width),
                        want["width"].as_i64().unwrap(),
                        "printer {i}: {m}"
                    );
                    assert_eq!(
                        i64::from(e.height),
                        want["height"].as_i64().unwrap(),
                        "printer {i}: {m}"
                    );
                    assert_eq!(
                        e.media_type.as_deref(),
                        want["type"].as_str(),
                        "printer {i}: {m}"
                    );
                    assert_eq!(e.is_variable, want["variable"].as_bool().unwrap());
                    let area = e.printable_area();
                    assert_eq!(area.is_some(), !m["area"].is_null(), "printer {i}: {m}");
                    if let Some(a) = area {
                        let w = &m["area"];
                        assert!(sheets_close(a.paper, size(&w["paper"])));
                        let n: Vec<f64> = w["margins"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|x| x.as_f64().unwrap())
                            .collect();
                        let g = a.margins;
                        assert_eq!(
                            [g.top, g.left, g.bottom, g.right],
                            [n[0], n[1], n[2], n[3]],
                            "printer {i}"
                        );
                    }
                }
                (g, w) => panic!("printer {i}: {g:?} is not {w}"),
            }
        }
    }
}

#[test]
fn pickers_list_the_same_choices() {
    for (i, p) in data()["printers"].as_array().unwrap().iter().enumerate() {
        let printer = media(&p["media"]);
        for c in p["choices"].as_array().unwrap() {
            let (chosen, region) = (c["chosen"].as_str(), c["region"].as_str());
            let got = paper_choices(Some(&printer), chosen, region);
            assert_eq!(
                got.selected,
                c["selected"].as_str().unwrap(),
                "printer {i}: {chosen:?} {region:?}"
            );
            let want = c["options"].as_array().unwrap();
            assert_eq!(
                got.options.len(),
                want.len(),
                "printer {i}: {chosen:?} {region:?}"
            );
            for (g, w) in got.options.iter().zip(want) {
                assert_eq!(g.id, w["id"].as_str().unwrap());
                assert_eq!(g.label, w["label"].as_str().unwrap());
                assert_eq!(g.detail, w["detail"].as_str().unwrap());
                assert_eq!(g.group, w["group"].as_str().unwrap());
            }
            assert_eq!(
                start_custom(Some(&printer), chosen, region),
                c["startCustom"].as_str().unwrap(),
                "printer {i}: {chosen:?}"
            );
        }
        for c in p["customIds"].as_array().unwrap() {
            let id = custom_size_id(
                c["width"].as_f64().unwrap(),
                c["height"].as_f64().unwrap(),
                c["region"].as_str(),
                Some(&printer),
            );
            assert_eq!(id, c["id"].as_str().unwrap(), "printer {i}: {c}");
        }
    }
}

#[test]
fn no_printer_gives_the_catalogue_alone() {
    let got = paper_choices(None, Some("a4"), Some("US"));
    assert_eq!(got.selected, "a4");
    assert!(
        got.options.iter().all(|o| o.group != PRINTER_GROUP)
            && got.options.last().unwrap().id != CUSTOM_ID
    );
}
