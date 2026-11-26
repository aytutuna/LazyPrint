use lazyprint_layout::PageSelection;
use lazyprint_settings::*;
use serde_json::{Number, Value, json};

fn settings_data() -> Value {
    testdata_check::json("settings/settings.json")
}

fn tasks_data() -> Value {
    testdata_check::json("settings/tasks.json")
}

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

#[test]
fn the_preset_file_drops_nameless_presets_and_reads_each_field() {
    for case in settings_data()["loadPresets"].as_array().unwrap() {
        let input = case["input"].as_str().unwrap();
        let got = presets_from_json(input).unwrap_or_default();
        let got: Vec<Value> = got
            .iter()
            .map(|p| json!({ "name": p.name, "settings": written(&p.settings) }))
            .collect();
        let want: Vec<Value> = case["output"]
            .as_array()
            .unwrap()
            .iter()
            .map(norm)
            .collect();
        assert_eq!(got, want, "{input}");
    }
}

#[test]
fn names_are_checked_against_the_built_in_and_the_saved_presets() {
    let data = settings_data();
    let built_in: Vec<&str> = TASKS.iter().map(|d| d.title).collect();
    let want: Vec<&str> = data["builtInNames"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    assert_eq!(built_in, want);
    let existing: Vec<UserPreset> = data["names"]["existing"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| UserPreset {
            name: n.as_str().unwrap().into(),
            settings: PrintSettings::default(),
        })
        .collect();
    for case in data["names"]["checks"].as_array().unwrap() {
        let got = check_preset_name(case["name"].as_str(), &existing, case["renaming"].as_str());
        let name = match got {
            PresetNameCheck::Ok => "ok",
            PresetNameCheck::Empty => "empty",
            PresetNameCheck::BuiltIn => "builtIn",
            PresetNameCheck::Exists => "exists",
        };
        assert_eq!(name, case["result"].as_str().unwrap(), "{case}");
    }
    assert_eq!(
        find_preset(&existing, "OTHER thing").unwrap().name,
        "Other Thing"
    );
    assert!(find_preset(&existing, "nothing").is_none());
}

#[test]
fn making_and_applying_a_preset() {
    for case in settings_data()["presets"].as_array().unwrap() {
        let mut settings = PrintSettings::from_value(&case["settings"]).unwrap();
        settings.copies = 5;
        settings.reverse_order = true;
        settings.page_selection = PageSelection::Odd;
        let mut current = PrintSettings::from_value(&case["current"]).unwrap();
        current.copies = 7;
        current.page_selection = PageSelection::Even;

        let preset = make_preset(case["name"].as_str().unwrap(), &settings);
        assert_eq!(preset.name, case["madeName"].as_str().unwrap());
        assert_eq!(written(&preset.settings), norm(&case["made"]));
        let r = &case["madeRuntime"];
        assert_eq!(
            i64::from(preset.settings.copies),
            r["copies"].as_i64().unwrap()
        );
        assert_eq!(
            preset.settings.reverse_order,
            r["reverseOrder"].as_bool().unwrap()
        );
        assert_eq!(
            preset.settings.page_selection,
            selection(r["pageSelection"].as_str().unwrap())
        );

        let applied = apply_preset(&preset, &current);
        assert_eq!(written(&applied), norm(&case["applied"]));
        let r = &case["appliedRuntime"];
        assert_eq!(i64::from(applied.copies), r["copies"].as_i64().unwrap());
        assert_eq!(applied.reverse_order, r["reverseOrder"].as_bool().unwrap());
        assert_eq!(
            applied.page_selection,
            selection(r["pageSelection"].as_str().unwrap())
        );

        assert_eq!(
            preset_matches(&preset, &current),
            case["matches"].as_bool().unwrap(),
            "{case}"
        );
        assert_eq!(
            preset_matches(&preset, &applied),
            case["matchesSelf"].as_bool().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn the_task_catalogue_is_the_references() {
    let data = tasks_data();
    let defs = data["definitions"].as_array().unwrap();
    assert_eq!(TASKS.len(), defs.len());
    for (got, w) in TASKS.iter().zip(defs) {
        assert_eq!(got.task.raw_value(), w["task"].as_str().unwrap());
        assert_eq!(got.title, w["title"].as_str().unwrap());
        assert_eq!(got.subtitle, w["subtitle"].as_str().unwrap());
        assert_eq!(got.icon_key, w["iconKey"].as_str().unwrap());
        assert_eq!(got.group.title(), w["groupTitle"].as_str().unwrap());
        assert_eq!(got.opens_files, w["opensFiles"].as_bool().unwrap());
    }
    for p in data["platformTasks"].as_array().unwrap() {
        let platform = match p["platform"].as_str().unwrap() {
            "windows" => AppPlatform::Windows,
            "mac" => AppPlatform::Mac,
            _ => AppPlatform::Ios,
        };
        let got: Vec<&str> = tasks_for(platform)
            .iter()
            .map(|d| d.task.raw_value())
            .collect();
        let want: Vec<&str> = p["tasks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_str().unwrap())
            .collect();
        assert_eq!(got, want);
    }
    for case in data["parse"].as_array().unwrap() {
        assert_eq!(
            PrintTask::parse(case["in"].as_str()).map(PrintTask::raw_value),
            case["task"].as_str()
        );
    }
    for case in data["availability"].as_array().unwrap() {
        let task = PrintTask::parse(case["task"].as_str()).unwrap();
        let context = TaskContext {
            has_printer: case["hasPrinter"].as_bool().unwrap(),
            lazy_scan_installed: case["lazyScan"].as_bool().unwrap(),
        };
        let got = task_availability(task, context);
        assert_eq!(got.is_ok(), case["available"].as_bool().unwrap(), "{case}");
        assert_eq!(got.err(), case["reason"].as_str(), "{case}");
    }
}

#[test]
fn built_in_presets_start_from_the_defaults() {
    for case in tasks_data()["apply"].as_array().unwrap() {
        let task = PrintTask::parse(case["task"].as_str()).unwrap();
        let mut settings = PrintSettings::from_value(&case["settings"]).unwrap();
        settings.copies = case["copies"].as_i64().unwrap() as i32;
        let types: Vec<String> = case["mediaTypes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t.as_str().unwrap().into())
            .collect();
        let printer = TaskPrinter {
            two_sided_long_edge: case["twoSided"].as_bool().unwrap(),
            media_types: &types,
        };
        let got = apply_task(task, &settings, printer);
        assert_eq!(written(&got), norm(&case["result"]), "{case}");
        assert_eq!(
            i64::from(got.copies),
            case["resultCopies"].as_i64().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn case_folds_one_character_at_a_time() {
    assert!(!same_name("Straße", "STRASSE"));
    assert!(same_name("Ärger", "äRGER"));
    let saved = vec![UserPreset {
        name: "Strasse".into(),
        settings: PrintSettings::default(),
    }];
    assert_eq!(
        check_preset_name(Some("Straße"), &saved, None),
        PresetNameCheck::Ok
    );
    assert!(find_preset(&saved, "Straße").is_none());
}

#[test]
fn presets_are_written_as_they_are_read() {
    let mut settings = PrintSettings::default();
    settings.set_margin_mm(3.5);
    let presets = vec![make_preset(" Sheet ", &settings)];
    let text = serde_json::to_string(&presets).unwrap();
    assert!(
        text.starts_with(r#"[{"name":"Sheet","settings":{"#),
        "{text}"
    );
    assert_eq!(presets_from_json(&text).unwrap(), presets);
}
