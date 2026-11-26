use crate::{DecodeError, PrintSettings, lenient, parse_document};
use lazyprint_layout::PageSelection;
use serde_json::Value;

/// A name and the option values it sets: everything in the settings but the printer, the task, copies, the page
/// selection and the order.
#[derive(Clone, Debug, PartialEq)]
pub struct UserPreset {
    pub name: String,
    pub settings: PrintSettings,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PresetNameCheck {
    Ok,
    Empty,
    /// The name is a built-in preset's.
    BuiltIn,
    /// The name is another user preset's.
    Exists,
}

/// The names compare without regard to case.
pub fn same_name(a: &str, b: &str) -> bool {
    a.to_uppercase() == b.to_uppercase()
}

/// Whether `name` can name a preset: not empty once trimmed, not a built-in preset's, and not another user preset's.
/// `renaming` is the preset being renamed, which may keep its own name.
pub fn check_preset_name(
    name: Option<&str>,
    presets: &[UserPreset],
    built_in_names: &[&str],
    renaming: Option<&str>,
) -> PresetNameCheck {
    let clean = name.unwrap_or("").trim();
    if clean.is_empty() {
        return PresetNameCheck::Empty;
    }
    if built_in_names.iter().any(|n| same_name(n, clean)) {
        return PresetNameCheck::BuiltIn;
    }
    let taken = presets
        .iter()
        .any(|p| same_name(&p.name, clean) && !renaming.is_some_and(|r| same_name(&p.name, r)));
    if taken {
        PresetNameCheck::Exists
    } else {
        PresetNameCheck::Ok
    }
}

pub fn find_preset<'a>(presets: &'a [UserPreset], name: &str) -> Option<&'a UserPreset> {
    presets.iter().find(|p| same_name(&p.name, name))
}

/// The options of `settings` under `name` (trimmed).
pub fn make_preset(name: &str, settings: &PrintSettings) -> UserPreset {
    UserPreset {
        name: name.trim().to_string(),
        settings: PrintSettings {
            printer_id: None,
            task_id: None,
            copies: 1,
            page_selection: PageSelection::All,
            reverse_order: false,
            ..settings.clone()
        },
    }
}

/// The settings with the preset's options over them; the printer, copies, page selection and order stay, and no task
/// is current.
pub fn apply_preset(preset: &UserPreset, settings: &PrintSettings) -> PrintSettings {
    PrintSettings {
        printer_id: settings.printer_id.clone(),
        task_id: None,
        copies: settings.copies,
        page_selection: settings.page_selection,
        reverse_order: settings.reverse_order,
        ..preset.settings.clone()
    }
}

/// The settings still have every option the preset sets.
pub fn preset_matches(preset: &UserPreset, settings: &PrintSettings) -> bool {
    PrintSettings::same_in_use(&apply_preset(preset, settings), settings)
}

/// Reads presets.json: a list of presets, each field read on its own. A preset with no name is dropped. A document
/// that is not a list of objects does not decode.
pub fn presets_from_json(text: &str) -> Result<Vec<UserPreset>, DecodeError> {
    let document = parse_document(text)?;
    let items = document
        .as_array()
        .ok_or_else(|| DecodeError("The file does not contain presets.".into()))?;
    let mut presets = Vec::new();
    for item in items {
        let object = item
            .as_object()
            .ok_or_else(|| DecodeError("A preset is not an object.".into()))?;
        let name: String = lenient(object, "name", String::new());
        let settings = match object.get("settings") {
            Some(v @ Value::Object(_)) => PrintSettings::from_value(v)?,
            _ => PrintSettings::default(),
        };
        if !name.trim().is_empty() {
            presets.push(UserPreset { name, settings });
        }
    }
    Ok(presets)
}
