use lazyprint_layout::PageSelection;
use lazyprint_settings::*;
use serde_json::{Number, Value};

fn data() -> Value {
    testdata_check::json("settings/settings.json")
}

/// Every number as a float, so 10 and 10.0 are the same.
fn norm(v: &Value) -> Value {
    match v {
        Value::Number(n) => Value::Number(Number::from_f64(n.as_f64().unwrap()).unwrap()),
        Value::Array(a) => Value::Array(a.iter().map(norm).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), norm(v))).collect()),
        other => other.clone(),
    }
}

fn written(s: &PrintSettings) -> Value {
    norm(&serde_json::to_value(s).unwrap())
}

fn selection(name: &str) -> PageSelection {
    serde_json::from_value(Value::String(name.into())).unwrap()
}

/// Settings from a persisted object plus the options a job sets and a file never keeps.
fn with_runtime(persisted: &Value, runtime: &Value) -> PrintSettings {
    let mut s = PrintSettings::from_value(persisted).unwrap();
    s.copies = runtime["copies"].as_i64().unwrap() as i32;
    s.page_selection = selection(runtime["pageSelection"].as_str().unwrap());
    s.reverse_order = runtime["reverseOrder"].as_bool().unwrap();
    s
}

#[test]
fn files_load_and_save_as_the_reference_does() {
    for case in data()["load"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        match PrintSettings::from_json(input) {
            Ok(s) => assert_eq!(written(&s), norm(&case["output"]), "{input}"),
            Err(_) => assert!(case["output"].is_null(), "{input}"),
        }
    }
}

#[test]
fn defaults_are_the_stored_defaults() {
    let s = PrintSettings::from_json("{}").unwrap();
    assert_eq!(s, PrintSettings::default());
    assert_eq!(s.copies, 1);
}

#[test]
fn a_whole_margin_is_written_without_a_decimal_point() {
    let text = serde_json::to_string(&PrintSettings::default()).unwrap();
    assert!(text.contains("\"marginMm\":10,"), "{text}");
    let mut s = PrintSettings::default();
    s.set_margin_mm(3.5);
    assert!(
        serde_json::to_string(&s)
            .unwrap()
            .contains("\"marginMm\":3.5,")
    );
}

#[test]
fn presets_match_while_the_options_they_set_hold() {
    let cases = data()["sameInUse"].clone();
    let cases = cases.as_array().unwrap();
    assert!(
        cases.iter().any(|c| c["same"].as_bool().unwrap())
            && cases.iter().any(|c| !c["same"].as_bool().unwrap())
    );
    for case in cases {
        let preset = with_runtime(&case["preset"], &case["presetRuntime"]);
        let settings = with_runtime(&case["settings"], &case["settingsRuntime"]);
        assert_eq!(
            PrintSettings::same_in_use(&preset, &settings),
            case["same"].as_bool().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn a_printer_that_cannot_takes_the_value_it_uses() {
    for case in data()["used"].as_array().unwrap() {
        let s = PrintSettings::from_value(&case["settings"]).unwrap();
        let used = s.used(
            case["noQuality"].as_bool().unwrap(),
            case["grayOnly"].as_bool().unwrap(),
        );
        let name = |v: Value| v.as_str().unwrap().to_string();
        assert_eq!(
            name(serde_json::to_value(used.quality).unwrap()),
            case["quality"].as_str().unwrap()
        );
        assert_eq!(
            name(serde_json::to_value(used.color).unwrap()),
            case["color"].as_str().unwrap()
        );
    }
}

#[test]
fn printers_file_loads_each_field_on_its_own() {
    for case in data()["printers"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        match PrinterPrefs::map_from_json(input) {
            Ok(map) => assert_eq!(
                norm(&serde_json::to_value(&map).unwrap()),
                norm(&case["output"]),
                "{input}"
            ),
            Err(_) => assert_eq!(case["output"], serde_json::json!({}), "{input}"),
        }
    }
}

#[test]
fn a_printer_remembers_and_brings_back_four_choices_and_two_more() {
    for case in data()["prefs"].as_array().unwrap() {
        let prefs =
            &PrinterPrefs::map_from_json(&serde_json::json!({ "p": case["prefs"] }).to_string())
                .unwrap()["p"];
        let settings = PrintSettings::from_value(&case["settings"]).unwrap();
        let mut applied = settings.clone();
        prefs.apply_to(&mut applied);
        assert_eq!(written(&applied), norm(&case["applied"]), "{case}");
        assert_eq!(
            norm(&serde_json::to_value(prefs.remembering(&settings)).unwrap()),
            norm(&case["remembered"]),
            "{case}"
        );
    }
}

#[test]
fn the_margin_stays_at_a_hundredth_whatever_is_set() {
    let mut s = PrintSettings::default();
    s.set_margin_mm(0.05);
    s.set_margin_mm(s.margin_mm() + 0.1);
    assert_eq!(s.margin_mm(), 0.15);
    s.set_margin_mm(1.23456);
    assert_eq!(s.margin_mm(), 1.23);
    s.set_margin_mm(80.0);
    assert_eq!(s.margin_mm(), 50.0);
}

#[test]
fn a_number_out_of_range_resets_only_its_own_field() {
    let s = PrintSettings::from_json(r#"{"marginMm": 1e400, "scale": 50}"#).unwrap();
    assert_eq!(s.margin_mm(), 10.0);
    assert_eq!(s.scale, 50);
    let s = PrintSettings::from_json(r#"{"scale": 1e400, "marginMm": 1.23456}"#).unwrap();
    assert_eq!(s.scale, 100);
    assert_eq!(s.margin_mm(), 1.23);
}
