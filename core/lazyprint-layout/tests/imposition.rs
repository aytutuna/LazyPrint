mod common;

use common::*;
use lazyprint_layout::*;

#[test]
fn plans_match_the_reference() {
    let cases = testdata_check::json_lines("layout/imposition.jsonl");
    assert!(cases.len() > 300);
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let (pages, options, area) = (
            pages(&case["pages"]),
            options(&case["options"]),
            area(&case["area"]),
        );
        let plan = plan_sheets(&pages, &options, area);
        assert_eq!(plan.area, area, "{name}");
        same_plan(&plan, &case["plan"], name);
        close(printer_edge(area), num(&case["edge"]), name);
        for (id, fits) in case["sizeFits"].as_object().unwrap() {
            let size = photo_size(id).size.unwrap();
            assert_eq!(
                size_fits(&options, area, size),
                fits.as_bool().unwrap(),
                "{name}: {id}"
            );
        }
    }
}

#[test]
fn a_two_sided_plan_has_an_even_side_count() {
    let cases = testdata_check::json_lines("layout/imposition.jsonl");
    for case in &cases {
        let plan = plan_sheets(
            &pages(&case["pages"]),
            &options(&case["options"]),
            area(&case["area"]),
        );
        if plan.duplex {
            assert_eq!(plan.side_count() % 2, 0, "{}", case["name"]);
        }
    }
}
