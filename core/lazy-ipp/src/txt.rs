//! The TXT record a printer advertises with its _ipp._tcp / _ipps._tcp DNS-SD service (AirPrint,
//! PWG 5100.14): where the IPP resource lives, what the printer is and roughly what it can do,
//! known before connecting to it.

use std::collections::HashMap;

pub const DEFAULT_PATH: &str = "ipp/print";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TxtRecord {
    /// The IPP resource path below the host, without slashes ("ipp/print" unless the printer says otherwise; "" for the root).
    pub resource_path: String,
    /// Make and model (ty).
    pub model: Option<String>,
    /// The PostScript-style product string (product).
    pub product: Option<String>,
    /// Document formats (pdl).
    pub document_formats: Vec<String>,
    /// The printer prints in color (Color=T); `None` when not advertised.
    pub color: Option<bool>,
    /// The printer prints both sides (Duplex=T); `None` when not advertised.
    pub duplex: Option<bool>,
    /// The printer UUID (UUID), the same value its printer-uuid reports.
    pub uuid: Option<String>,
    pub admin_url: Option<String>,
    /// The user-assigned location (note).
    pub note: Option<String>,
    /// The Apple raster capabilities (URF), e.g. "W8", "SRGB24", "RS300-600"; empty when none or "none".
    pub urf: Vec<String>,
    pub tls: Option<String>,
    /// What the printer prints (kind), lowercased.
    pub kind: Vec<String>,
    pub paper_max: Option<String>,
}

impl TxtRecord {
    /// Reads "key=value" strings (the form Windows reports TXT attributes in). Keys are matched
    /// without regard to ASCII case and only the first occurrence of a key counts (RFC 6763, 6.4);
    /// entries without '=' and unknown keys are ignored.
    pub fn parse<S: AsRef<str>>(attributes: &[S]) -> TxtRecord {
        let mut values: HashMap<String, String> = HashMap::new();
        for attribute in attributes {
            let attribute = attribute.as_ref();
            let Some(equals) = attribute.find('=').filter(|e| *e > 0) else {
                continue;
            };
            let key = attribute[..equals].trim().to_lowercase();
            if !key.is_empty() {
                values
                    .entry(key)
                    .or_insert_with(|| attribute[equals + 1..].trim().to_string());
            }
        }

        let value = |key: &str| {
            values
                .get(&key.to_lowercase())
                .filter(|v| !v.is_empty())
                .cloned()
        };
        let flag = |key: &str| match value(key)?.to_uppercase().as_str() {
            "T" | "TRUE" => Some(true),
            "F" | "FALSE" => Some(false),
            _ => None,
        };
        let list = |key: &str, lowercase: bool| -> Vec<String> {
            let mut items: Vec<String> = vec![];
            for item in value(key).iter().flat_map(|t| t.split(',')) {
                let item = item.trim();
                if item.is_empty() {
                    continue;
                }
                let item = if lowercase {
                    item.to_lowercase()
                } else {
                    item.to_string()
                };
                if !items.iter().any(|i| i.eq_ignore_ascii_case(&item)) {
                    items.push(item);
                }
            }
            items
        };

        TxtRecord {
            // A present but empty rp means the resource is at the root.
            resource_path: values
                .get("rp")
                .map(|rp| rp.trim_matches('/').to_string())
                .unwrap_or_else(|| DEFAULT_PATH.to_string()),
            model: value("ty"),
            product: value("product"),
            document_formats: list("pdl", false),
            color: flag("Color"),
            duplex: flag("Duplex"),
            uuid: value("UUID"),
            admin_url: value("adminurl"),
            note: value("note"),
            urf: if value("URF").is_some_and(|u| u.eq_ignore_ascii_case("none")) {
                vec![]
            } else {
                list("URF", false)
            },
            tls: value("TLS"),
            kind: list("kind", true),
            paper_max: value("PaperMax"),
        }
    }
}

/// A UUID reduced to its lowercase letters and digits ("urn:uuid:" and braces dropped), so the
/// forms printers use in TXT records and in printer-uuid compare equal; `None` when empty.
pub fn uuid_key(uuid: Option<&str>) -> Option<String> {
    let text = uuid?.trim().to_lowercase();
    let text = text.strip_prefix("urn:uuid:").unwrap_or(&text);
    let key: String = text.chars().filter(char::is_ascii_alphanumeric).collect();
    (!key.is_empty()).then_some(key)
}
