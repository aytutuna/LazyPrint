use lazyprint_jobs::*;
use lazyprint_layout::SheetSide;
use lazyprint_layout::{
    LayoutInsets, LayoutOptions, LayoutRect, LayoutSize, PageSelection, PaperPath, PlanWarning,
    PrintableArea,
};
use lazyprint_paper::{
    MediaEntry, MediaMargins, MediaMember, MemberValue, PaperRange, PrinterMedia,
};
use lazyprint_settings::PrintSettings;
use serde_json::Value;

const TOLERANCE: f64 = 1e-9;

fn data() -> Value {
    testdata_check::json("jobs/jobs.json")
}

fn nums(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

fn size(v: &Value) -> LayoutSize {
    let n = nums(v);
    LayoutSize {
        width: n[0],
        height: n[1],
    }
}

fn rect(v: &Value) -> LayoutRect {
    let n = nums(v);
    LayoutRect {
        x: n[0],
        y: n[1],
        width: n[2],
        height: n[3],
    }
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

fn close(a: f64, b: f64, what: &str) {
    assert!((a - b).abs() <= TOLERANCE, "{what}: {a} is not {b}");
}

fn same_rect(a: LayoutRect, b: LayoutRect, what: &str) {
    close(a.x, b.x, what);
    close(a.y, b.y, what);
    close(a.width, b.width, what);
    close(a.height, b.height, what);
}

fn members(v: &Value) -> Vec<MediaMember> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|m| MediaMember {
            name: m["name"].as_str().unwrap().to_string(),
            values: m["values"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| {
                    if let Some(n) = x.get("integer") {
                        MemberValue::Integer(n.as_i64().unwrap() as i32)
                    } else if let Some(k) = x.get("keyword") {
                        MemberValue::Keyword(k.as_str().unwrap().to_string())
                    } else if let Some(c) = x.get("collection") {
                        MemberValue::Collection(members(c))
                    } else {
                        MemberValue::Other(x["other"].as_str().unwrap().to_string())
                    }
                })
                .collect(),
        })
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
            attributes: members(&e["attributes"]),
        })
        .collect()
}

fn printer(v: &Value) -> JobPrinter {
    JobPrinter {
        documents_borderless: true,
        media: PrinterMedia {
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
        },
        sides_supported: strings(&v["sidesSupported"]),
        copies_upper: v["copiesUpper"].as_i64().unwrap() as i32,
        multiple_document_handling: strings(&v["multipleDocumentHandling"]),
        media_types: strings(&v["mediaTypes"]),
        media_sources: strings(&v["mediaSources"]),
        color_modes: strings(&v["colorModes"]),
        media_col_supported: strings(&v["mediaColSupported"]),
        print_scaling_supported: strings(&v["printScalingSupported"]),
        print_quality_supported: nums(&v["printQualitySupported"])
            .into_iter()
            .map(|q| q as i32)
            .collect(),
    }
}

fn area(v: &Value) -> PrintableArea {
    let m = nums(&v["margins"]);
    PrintableArea {
        paper: size(&v["paper"]),
        margins: LayoutInsets {
            top: m[0],
            left: m[1],
            bottom: m[2],
            right: m[3],
        },
    }
}

fn same_side(got: &SheetSide, want: &Value, what: &str) {
    assert_eq!(
        got.borders,
        want["borders"].as_bool().unwrap(),
        "{what}: borders"
    );
    let placements = want["placements"].as_array().unwrap();
    assert_eq!(got.placements.len(), placements.len(), "{what}: placements");
    for (g, w) in got.placements.iter().zip(placements) {
        let p = nums(&w["page"]);
        assert_eq!(
            (g.page.document, g.page.index),
            (p[0] as usize, p[1] as usize),
            "{what}"
        );
        same_rect(g.frame, rect(&w["frame"]), what);
        assert_eq!(
            u64::from(g.turns),
            w["turns"].as_u64().unwrap(),
            "{what}: turns"
        );
        match (&g.crop, &w["crop"]) {
            (None, Value::Null) => {}
            (Some(c), w) if !w.is_null() => same_rect(*c, rect(w), what),
            _ => panic!("{what}: crop"),
        }
    }
    let cuts = want["cutCells"].as_array().unwrap();
    assert_eq!(got.cut_cells.len(), cuts.len(), "{what}: cuts");
    for (g, w) in got.cut_cells.iter().zip(cuts) {
        same_rect(*g, rect(w), what);
    }
}

fn same_options(got: &LayoutOptions, want: &Value, what: &str) {
    assert_eq!(
        u64::from(got.pages_per_sheet),
        want["pagesPerSheet"].as_u64().unwrap(),
        "{what}"
    );
    assert_eq!(got.booklet, want["booklet"].as_bool().unwrap(), "{what}");
    assert_eq!(
        got.right_to_left,
        want["rightToLeft"].as_bool().unwrap(),
        "{what}"
    );
    assert_eq!(
        serde_json::to_value(got.scaling).unwrap(),
        want["scaling"],
        "{what}"
    );
    assert_eq!(
        serde_json::to_value(got.sides).unwrap(),
        want["sides"],
        "{what}"
    );
    assert_eq!(
        got.page_borders,
        want["pageBorders"].as_bool().unwrap(),
        "{what}"
    );
    assert_eq!(
        i64::from(got.scale),
        want["scale"].as_i64().unwrap(),
        "{what}"
    );
    assert_eq!(
        serde_json::to_value(got.orientation).unwrap(),
        want["orientation"],
        "{what}"
    );
    close(got.margin, want["margin"].as_f64().unwrap(), what);
    match (&got.margins, &want["margins"]) {
        (None, Value::Null) => {}
        (Some(m), w) if !w.is_null() => {
            let n = nums(w);
            assert_eq!(
                [m.top, m.left, m.bottom, m.right],
                [n[0], n[1], n[2], n[3]],
                "{what}"
            );
        }
        _ => panic!("{what}: margins"),
    }
    assert_eq!(
        u64::from(got.poster),
        want["poster"].as_u64().unwrap(),
        "{what}"
    );
    match (got.cell_size, &want["cellSize"]) {
        (None, Value::Null) => {}
        (Some(c), w) if !w.is_null() => {
            close(c.width, size(w).width, what);
            close(c.height, size(w).height, what);
        }
        _ => panic!("{what}: cell size"),
    }
    assert_eq!(got.cut_marks, want["cutMarks"].as_bool().unwrap(), "{what}");
}

#[test]
fn jobs_are_planned_like_the_reference() {
    let data = data();
    let printers: Vec<Option<JobPrinter>> = data["printers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| (!p.is_null()).then(|| printer(p)))
        .collect();
    for (n, case) in data["cases"].as_array().unwrap().iter().enumerate() {
        let what = format!("case {n}");
        let mut settings = PrintSettings::from_value(&case["settings"]).unwrap();
        settings.copies = case["runtime"]["copies"].as_i64().unwrap() as i32;
        settings.page_selection =
            serde_json::from_value::<PageSelection>(case["runtime"]["pageSelection"].clone())
                .unwrap();
        settings.reverse_order = case["runtime"]["reverseOrder"].as_bool().unwrap();
        let documents: Vec<LoadedDocument> = case["documents"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
            .map(|(i, d)| LoadedDocument {
                name: format!("Doc{i}"),
                kind: DocumentKind::Pdf { encrypted: false },
                pages: d["pages"].as_array().unwrap().iter().map(size).collect(),
                turns: d["turns"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|t| t.as_u64().unwrap() as u8)
                    .collect(),
            })
            .collect();
        let range: Option<Vec<usize>> = case["pageRange"]
            .as_array()
            .map(|r| r.iter().map(|i| i.as_u64().unwrap() as usize).collect());
        let path = PaperPath {
            turn_stack_over: case["paperPath"]["turnStackOver"].as_bool().unwrap(),
            turn_backs: case["paperPath"]["turnBacks"].as_bool().unwrap(),
            checked: false,
        };
        let context = JobContext {
            printer: printers[case["printer"].as_u64().unwrap() as usize].as_ref(),
            region: case["region"].as_str(),
        };

        same_options(&context.layout_options(&settings), &case["options"], &what);
        let a = context.area(&settings, false);
        let want = area(&case["area"]);
        close(a.paper.width, want.paper.width, &what);
        close(a.paper.height, want.paper.height, &what);
        for (g, w) in [
            (a.margins.top, want.margins.top),
            (a.margins.left, want.margins.left),
            (a.margins.bottom, want.margins.bottom),
            (a.margins.right, want.margins.right),
        ] {
            close(g, w, &what);
        }
        match (
            context.printer_edge(&settings, false),
            case["printerEdge"].as_f64(),
        ) {
            (None, None) => {}
            (Some(g), Some(w)) => close(g, w, &what),
            (g, w) => panic!("{what}: edge {g:?} is not {w:?}"),
        }
        close(
            context.printer_margin(&settings),
            case["printerMargin"].as_f64().unwrap(),
            &what,
        );
        let sizes: Vec<&str> = context
            .photo_sizes(&settings)
            .iter()
            .map(|p| p.id)
            .collect();
        assert_eq!(sizes, strings(&case["photoSizes"]), "{what}");
        let sheet = context.sheet(&settings.paper_id);
        close(sheet.width, size(&case["sheet"]).width, &what);
        close(sheet.height, size(&case["sheet"]).height, &what);

        let job = context.plan(&documents, range.as_deref(), &settings, &path);
        let ticket = context.ticket(
            &job,
            &settings,
            case["format"].as_str().unwrap(),
            &format!("Job {n}"),
            case["asIs"].as_bool().unwrap(),
        );
        let want = &case["ticket"];
        assert_eq!(ticket.job_name, want["jobName"].as_str().unwrap(), "{what}");
        assert_eq!(
            ticket.document_format,
            want["documentFormat"].as_str().unwrap(),
            "{what}"
        );
        assert_eq!(
            i64::from(ticket.copies),
            want["copies"].as_i64().unwrap(),
            "{what}"
        );
        assert_eq!(ticket.sides, want["sides"].as_str().unwrap(), "{what}");
        assert_eq!(
            ticket.color_mode,
            want["colorMode"].as_str().unwrap(),
            "{what}"
        );
        assert_eq!(
            ticket.media.name,
            want["media"]["name"].as_str().unwrap(),
            "{what}"
        );
        assert_eq!(
            ticket.media.entry,
            want["media"]["entry"]
                .is_array()
                .then(|| members(&want["media"]["entry"])),
            "{what}"
        );
        assert_eq!(
            ticket.quality.map(i64::from),
            want["quality"].as_i64(),
            "{what}"
        );
        assert_eq!(
            ticket.scaling.as_deref(),
            want["scaling"].as_str(),
            "{what}"
        );
        assert_eq!(
            ticket.collated_copies,
            want["collatedCopies"].as_bool().unwrap(),
            "{what}"
        );
        assert_eq!(
            job.manual_duplex,
            case["manualDuplex"].as_bool().unwrap(),
            "{what}"
        );
        assert_eq!(
            i64::from(job.copies_in_job),
            case["copiesInJob"].as_i64().unwrap(),
            "{what}"
        );
        assert_eq!(job.notes, strings(&case["notes"]), "{what}");
        let plan = &case["plan"];
        assert_eq!(job.plan.duplex, plan["duplex"].as_bool().unwrap(), "{what}");
        assert_eq!(
            i64::from(job.plan.printed_scale),
            plan["printedScale"].as_i64().unwrap(),
            "{what}"
        );
        let warnings = plan["warnings"].as_array().unwrap();
        assert_eq!(job.plan.warnings.len(), warnings.len(), "{what}");
        for (g, w) in job.plan.warnings.iter().zip(warnings) {
            match g {
                PlanWarning::Clipped(p) => close(*p, w["points"].as_f64().unwrap(), &what),
                PlanWarning::PaddedWithBlanks(c) => {
                    assert_eq!(*c as u64, w["count"].as_u64().unwrap(), "{what}")
                }
            }
        }
        let sheets = plan["sheets"].as_array().unwrap();
        assert_eq!(job.plan.sheets.len(), sheets.len(), "{what}");
        for (g, w) in job.plan.sheets.iter().zip(sheets) {
            same_side(&g.front, &w["front"], &what);
            match (&g.back, &w["back"]) {
                (None, Value::Null) => {}
                (Some(b), w) if !w.is_null() => same_side(b, w, &what),
                _ => panic!("{what}: back"),
            }
        }
        let passes = case["passes"].as_array().unwrap();
        assert_eq!(job.passes.len(), passes.len(), "{what}");
        for (g, w) in job.passes.iter().zip(passes) {
            let sides = w["sides"].as_array().unwrap();
            assert_eq!(g.sides.len(), sides.len(), "{what}");
            for (gs, ws) in g.sides.iter().zip(sides) {
                same_side(gs, ws, &what);
            }
            let marked: Vec<usize> = w["marked"]
                .as_array()
                .unwrap()
                .iter()
                .map(|m| m.as_u64().unwrap() as usize)
                .collect();
            assert_eq!(g.marked, marked, "{what}");
        }
    }
}

#[test]
fn turning_pages_wraps_and_swaps_sizes() {
    for case in data()["turned"].as_array().unwrap() {
        let mut doc = LoadedDocument::new(
            "D",
            DocumentKind::Photo,
            vec![
                LayoutSize {
                    width: 432.0,
                    height: 288.0,
                },
                LayoutSize {
                    width: 288.0,
                    height: 432.0,
                },
                LayoutSize {
                    width: 100.0,
                    height: 200.0,
                },
            ],
        );
        for op in case["ops"].as_array().unwrap() {
            doc = doc.turned(
                op["page"].as_u64().map(|p| p as usize),
                op["quarter"].as_i64().unwrap() as i32,
            );
        }
        let turns: Vec<u8> = case["turns"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_u64().unwrap() as u8)
            .collect();
        assert_eq!(doc.turns, turns, "{case}");
        assert_eq!(
            doc.is_turned(),
            case["isTurned"].as_bool().unwrap(),
            "{case}"
        );
        for (i, s) in case["sizes"].as_array().unwrap().iter().enumerate() {
            assert_eq!(doc.size(i), size(s), "{case}");
        }
    }
}

#[test]
fn job_states_are_named_as_the_contract() {
    let states = [
        JobState::Preparing,
        JobState::Sending,
        JobState::Waiting,
        JobState::Printing,
        JobState::Done,
        JobState::Failed,
        JobState::Canceled,
        JobState::NeedsUser,
    ];
    let names: Vec<&str> = states.iter().map(|s| s.name()).collect();
    assert_eq!(names, strings(&data()["jobStates"]));
}
