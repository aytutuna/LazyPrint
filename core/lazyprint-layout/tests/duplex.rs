mod common;

use common::*;
use lazyprint_layout::*;
use serde_json::Value;

fn misc() -> Value {
    testdata_check::json("layout/misc.json")
}

fn strs(v: &Value) -> Vec<usize> {
    v.as_array().unwrap().iter().map(|n| n.as_u64().unwrap() as usize).collect()
}

fn path(v: &Value) -> PaperPath {
    PaperPath {
        turn_stack_over: v["turnStackOver"].as_bool().unwrap(),
        turn_backs: v["turnBacks"].as_bool().unwrap(),
        checked: v["checked"].as_bool().unwrap(),
    }
}

#[test]
fn manual_two_sided_passes() {
    let cases = misc()["manualDuplex"].clone();
    for (n, case) in cases.as_array().unwrap().iter().enumerate() {
        let (area, path) = (area(&case["area"]), path(&case["path"]));
        let plan = plan_sheets(&pages(&case["pages"]), &options(&case["options"]), area);
        let (fronts, backs) = manual_passes(&plan, &path);
        for (pass, want) in [(fronts, &case["fronts"]), (backs, &case["backs"])] {
            let sides = want["sides"].as_array().unwrap();
            assert_eq!(pass.sides.len(), sides.len(), "case {n}");
            for (g, w) in pass.sides.iter().zip(sides) {
                same_side(g, w, &format!("case {n}"));
            }
            assert_eq!(pass.marked, strs(&want["marked"]), "case {n}");
        }
    }
}

#[test]
fn the_check_answer_is_learnt() {
    for case in misc()["learn"].as_array().unwrap() {
        let answer = match case["answer"].as_str().unwrap() {
            "sameEdge" => DuplexCheckAnswer::SameEdge,
            "oppositeEdges" => DuplexCheckAnswer::OppositeEdges,
            _ => DuplexCheckAnswer::BothOnOneSide,
        };
        assert_eq!(
            learn_paper_path(answer, path(&case["from"])),
            path(&case["to"]),
            "{case}"
        );
    }
}

#[test]
fn reload_words() {
    for case in misc()["reload"].as_array().unwrap() {
        let p = PaperPath {
            turn_stack_over: case["turnStackOver"].as_bool().unwrap(),
            ..PaperPath::default()
        };
        assert_eq!(
            reload_instruction(case["sheets"].as_u64().unwrap() as usize, &p),
            case["text"].as_str().unwrap()
        );
    }
}
