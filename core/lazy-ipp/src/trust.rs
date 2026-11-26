//! Which printer certificates are trusted.
//!
//! Printers make their own certificates, so one is trusted the first time the app connects (trust
//! on first use) and pinned by the SHA-256 of its public key in ipp-trust.json; a different key for
//! a known printer is refused until the user trusts it. This holds the rules and the file; the TLS
//! stack of each platform hands the presented certificate to [`CertificateValidator`].

use crate::txt::uuid_key;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

/// Addresses remembered per certificate; the oldest are dropped beyond this.
const MAX_ADDRESSES: usize = 8;

/// What the trust store says about a certificate a printer presented.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Neither this certificate nor the printer has been trusted before.
    Unknown,
    /// The certificate is trusted (pinned, or valid for the platform).
    Trusted,
    /// The printer was trusted with a different certificate.
    Changed,
    /// The printer presented no certificate that could be pinned.
    Invalid,
}

/// One trusted printer certificate (an entry of ipp-trust.json).
#[derive(Clone, Debug, PartialEq)]
pub struct TrustedCertificate {
    /// SHA-256 of the certificate's public key (SubjectPublicKeyInfo), lowercase hex.
    pub fingerprint: String,
    /// The printer's UUID as [`uuid_key`] writes it; empty when it was not known.
    pub device_uuid: String,
    /// Where the certificate was seen ("host:port", see `PrinterAddress::authority`).
    pub addresses: Vec<String>,
    /// The printer's name when it was trusted (for people reading the file).
    pub name: String,
    /// When the user trusted it. Each platform writes the date its own way, so it is kept as it was read.
    pub trusted: Option<Value>,
}

struct Inner {
    certificates: Vec<TrustedCertificate>,
    /// Certificates trusted (and the address they were trusted at) that are not in the file yet: its last write failed.
    unsaved: Vec<(TrustedCertificate, String)>,
    /// The file could not be read, so it is left alone for the rest of the session.
    protected: bool,
}

/// The trusted printer certificates (ipp-trust.json), safe to use from any thread. The file is
/// re-read for every check and before every write, since several windows of the app may share it;
/// certificates trusted while the file could not be written stay trusted for the rest of the session.
pub struct TrustStore {
    path: PathBuf,
    inner: Mutex<Inner>,
}

enum Read {
    Missing,
    Corrupt,
    Inaccessible,
    Loaded(Vec<TrustedCertificate>),
}

impl TrustStore {
    /// Keeps ipp-trust.json in `directory`.
    pub fn open(directory: &Path) -> TrustStore {
        let store = TrustStore {
            path: directory.join("ipp-trust.json"),
            inner: Mutex::new(Inner {
                certificates: vec![],
                unsaved: vec![],
                protected: false,
            }),
        };
        {
            let mut inner = store.lock();
            store.reload(&mut inner);
        }
        store
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Whether `fingerprint` may be trusted for the printer with `device_uuid` (`None` when
    /// unknown) at `authority`. A pinned public key is trusted wherever it shows up (only the
    /// printer holds its private key); the address it was reached at, and the printer's UUID when
    /// the pin did not have one, are remembered. Otherwise, a printer trusted before with another
    /// key (the same UUID, or, when either UUID is unknown, the same address) is
    /// [`Verdict::Changed`], with that entry as the second part of the answer. A pinned key that
    /// claims the UUID of a printer trusted with another key is Changed too: a key vouches only for
    /// the printer it was trusted for.
    pub fn check(
        &self,
        fingerprint: &str,
        device_uuid: Option<&str>,
        authority: &str,
    ) -> (Verdict, Option<TrustedCertificate>) {
        if fingerprint.is_empty() {
            return (Verdict::Invalid, None);
        }
        let uuid = uuid_key(device_uuid).unwrap_or_default();
        let address = authority.to_lowercase();
        let mut inner = self.lock();
        self.reload(&mut inner);
        if let Some(i) = inner
            .certificates
            .iter()
            .position(|c| c.fingerprint == fingerprint)
        {
            if !uuid.is_empty()
                && inner.certificates[i].device_uuid != uuid
                && let Some(other) = inner.certificates.iter().find(|c| c.device_uuid == uuid)
            {
                return (Verdict::Changed, Some(other.clone()));
            }
            let mut learned = false;
            let pinned = &mut inner.certificates[i];
            if pinned.device_uuid.is_empty() && !uuid.is_empty() {
                pinned.device_uuid = uuid;
                learned = true;
            }
            if !pinned.addresses.contains(&address) {
                pinned.addresses.push(address);
                if pinned.addresses.len() > MAX_ADDRESSES {
                    pinned.addresses.remove(0);
                }
                learned = true;
            }
            if learned {
                self.save(&mut inner);
            }
            return (Verdict::Trusted, None);
        }
        let previous = inner
            .certificates
            .iter()
            .find(|c| same_printer(c, &uuid, &address))
            .cloned();
        match previous {
            Some(p) => (Verdict::Changed, Some(p)),
            None => (Verdict::Unknown, None),
        }
    }

    /// Trusts `fingerprint` for a printer, replacing whatever was trusted for that printer before
    /// (see [`TrustStore::check`]), and saves the file. An empty fingerprint is refused.
    pub fn trust(
        &self,
        fingerprint: &str,
        device_uuid: Option<&str>,
        authority: &str,
        name: &str,
    ) -> Result<(), EmptyFingerprint> {
        if fingerprint.is_empty() {
            return Err(EmptyFingerprint);
        }
        let uuid = uuid_key(device_uuid).unwrap_or_default();
        let address = authority.to_lowercase();
        let mut inner = self.lock();
        self.reload(&mut inner);
        inner
            .unsaved
            .retain(|(pin, _)| !replaces(pin, fingerprint, &uuid, &address));
        inner
            .certificates
            .retain(|c| !replaces(c, fingerprint, &uuid, &address));
        let pin = TrustedCertificate {
            fingerprint: fingerprint.to_string(),
            device_uuid: uuid,
            addresses: vec![address.clone()],
            name: name.to_string(),
            trusted: Some(Value::String(utc_now())),
        };
        inner.certificates.push(pin.clone());
        if !self.save(&mut inner) {
            inner.unsaved.push((pin, address));
        }
        Ok(())
    }

    /// Whether a certificate is trusted for this printer already (same UUID or address, see
    /// [`TrustStore::check`]).
    pub fn knows(&self, device_uuid: Option<&str>, authority: &str) -> bool {
        let uuid = uuid_key(device_uuid).unwrap_or_default();
        let address = authority.to_lowercase();
        let mut inner = self.lock();
        self.reload(&mut inner);
        inner
            .certificates
            .iter()
            .any(|c| same_printer(c, &uuid, &address))
    }

    /// The trusted certificates (copies).
    pub fn certificates(&self) -> Vec<TrustedCertificate> {
        self.lock().certificates.clone()
    }

    /// Re-reads the file: another window of the app may have trusted or replaced a certificate
    /// meanwhile, and writing the copy loaded earlier would undo that. Certificates trusted here
    /// that could not be saved are applied to it again.
    fn reload(&self, inner: &mut Inner) {
        let mut file = match read_file(&self.path) {
            Read::Loaded(certificates) => certificates,
            Read::Missing => return,
            Read::Corrupt => {
                keep_unreadable(&self.path);
                return;
            }
            Read::Inaccessible => {
                inner.protected = true;
                return;
            }
        };
        inner.protected = false;
        for (pin, address) in &inner.unsaved {
            file.retain(|c| !replaces(c, &pin.fingerprint, &pin.device_uuid, address));
            file.push(pin.clone());
        }
        inner.certificates = file;
    }

    /// Writes the file; false when it could not be written.
    fn save(&self, inner: &mut Inner) -> bool {
        if inner.protected {
            return false;
        }
        let entries: Vec<Value> = inner.certificates.iter().map(to_json).collect();
        let mut root = Map::new();
        root.insert("certificates".into(), Value::Array(entries));
        let Ok(text) = serde_json::to_string_pretty(&Value::Object(root)) else {
            return false;
        };
        let temporary = {
            let mut name = self.path.clone().into_os_string();
            name.push(".tmp");
            PathBuf::from(name)
        };
        if let Some(directory) = self.path.parent()
            && std::fs::create_dir_all(directory).is_err()
        {
            return false;
        }
        if std::fs::write(&temporary, text).is_err() {
            return false;
        }
        if std::fs::rename(&temporary, &self.path).is_err() {
            let _ = std::fs::remove_file(&temporary);
            return false;
        }
        inner.unsaved.clear();
        true
    }
}

/// An empty fingerprint cannot be trusted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EmptyFingerprint;

impl fmt::Display for EmptyFingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("no certificate to trust")
    }
}

impl std::error::Error for EmptyFingerprint {}

/// Whether trusting `fingerprint` for that printer replaces `entry`.
fn replaces(entry: &TrustedCertificate, fingerprint: &str, uuid: &str, address: &str) -> bool {
    entry.fingerprint == fingerprint || same_printer(entry, uuid, address)
}

/// Whether a certificate is trusted for this printer already: the same UUID when both are known,
/// else the same address.
fn same_printer(entry: &TrustedCertificate, uuid: &str, address: &str) -> bool {
    if !uuid.is_empty() && !entry.device_uuid.is_empty() {
        entry.device_uuid == uuid
    } else {
        entry.addresses.iter().any(|a| a == address)
    }
}

fn to_json(c: &TrustedCertificate) -> Value {
    let mut entry = Map::new();
    entry.insert("fingerprint".into(), c.fingerprint.clone().into());
    entry.insert("deviceUuid".into(), c.device_uuid.clone().into());
    entry.insert(
        "addresses".into(),
        Value::Array(c.addresses.iter().cloned().map(Value::String).collect()),
    );
    entry.insert("name".into(), c.name.clone().into());
    if let Some(trusted) = &c.trusted {
        entry.insert("trusted".into(), trusted.clone());
    }
    Value::Object(entry)
}

// A field of the wrong type resets only that field, as the other platforms read their settings.
fn from_json(entry: &Map<String, Value>) -> TrustedCertificate {
    let text = |key: &str| match entry.get(key) {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    };
    TrustedCertificate {
        fingerprint: text("fingerprint"),
        device_uuid: text("deviceUuid"),
        addresses: match entry.get("addresses") {
            Some(Value::Array(a)) => a
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect(),
            _ => vec![],
        },
        name: text("name"),
        trusted: match entry.get("trusted") {
            Some(v @ (Value::String(_) | Value::Number(_))) => Some(v.clone()),
            _ => None,
        },
    }
}

fn read_file(path: &Path) -> Read {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Read::Missing,
        Err(_) => return Read::Inaccessible,
    };
    match serde_json::from_slice::<Value>(&data) {
        Ok(Value::Object(root)) => Read::Loaded(match root.get("certificates") {
            Some(Value::Array(entries)) => entries
                .iter()
                .filter_map(Value::as_object)
                .map(from_json)
                .collect(),
            _ => vec![],
        }),
        _ => Read::Corrupt,
    }
}

// A file that does not decode is moved aside, so the next write does not destroy it.
fn keep_unreadable(path: &Path) {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let _ = std::fs::rename(
        path,
        path.with_file_name(format!("ipp-trust.unreadable-{stamp}.json")),
    );
}

/// The current time as an RFC 3339 UTC string.
fn utc_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let (days, rest) = (seconds.div_euclid(86_400), seconds.rem_euclid(86_400));
    // Civil date from a day count (H. Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

/// SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex (the key, not the whole
/// certificate, is pinned). `None` when `der` is not an X.509 certificate.
pub fn spki_fingerprint(der: &[u8]) -> Option<String> {
    let spki = Certificate::parse(der)?.spki;
    Some(
        Sha256::digest(spki)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
    )
}

/// "AB:CD:..." for people to compare; groups of `bytes_per_line` bytes per line when positive.
pub fn format_fingerprint(fingerprint: &str, bytes_per_line: usize) -> String {
    let pairs: Vec<String> = fingerprint
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|p| String::from_utf8_lossy(p.as_slice()).to_uppercase())
        .collect();
    if bytes_per_line == 0 {
        return pairs.join(":");
    }
    pairs
        .chunks(bytes_per_line)
        .map(|line| line.join(":"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A certificate was refused: not trusted yet, changed, or unusable.
#[derive(Clone, Debug, PartialEq)]
pub struct CertificateError {
    pub verdict: Verdict,
    pub device_name: String,
    /// The printer's UUID as known when connecting; `None` when unknown.
    pub device_uuid: Option<String>,
    /// "host:port" the certificate was presented at.
    pub authority: String,
    /// SPKI SHA-256 of the presented certificate, lowercase hex ("" when there was none).
    pub fingerprint: String,
    /// The previously trusted certificate, for [`Verdict::Changed`].
    pub previous: Option<TrustedCertificate>,
    /// The certificate's subject, e.g. "CN=HPA1B2C3"; "" when there was none.
    pub subject: String,
}

impl CertificateError {
    /// The certificate can be trusted by the user (it exists and can be pinned).
    pub fn can_trust(&self) -> bool {
        matches!(self.verdict, Verdict::Unknown | Verdict::Changed) && !self.fingerprint.is_empty()
    }
}

impl fmt::Display for CertificateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let what = match self.verdict {
            Verdict::Changed => "has a changed certificate",
            Verdict::Invalid => "did not present a usable certificate",
            _ => "uses a certificate that is not trusted yet",
        };
        write!(f, "{} {what}", self.device_name)
    }
}

impl std::error::Error for CertificateError {}

#[derive(Clone)]
struct Accepted {
    fingerprint: String,
    authority: String,
    subject: String,
    pinned: bool,
}

struct State {
    rejection: Option<CertificateError>,
    /// The certificate accepted last.
    accepted: Option<Accepted>,
    first_use: Option<String>,
}

/// Checks the certificates one printer presents, against a [`TrustStore`]. A certificate the
/// platform accepts (valid chain, matching name) is trusted as is; any other is trusted only when
/// pinned, or, for `first_use`, provisionally until [`CertificateValidator::remember_device`]. A
/// refusal is kept for [`CertificateValidator::take_rejection`], since TLS stacks report it only as
/// a failed connection.
pub struct CertificateValidator {
    store: Arc<TrustStore>,
    device_uuid: Option<String>,
    device_name: String,
    state: Mutex<State>,
}

impl CertificateValidator {
    /// `first_use` is the fingerprint of a certificate the store does not know
    /// ([`Verdict::Unknown`]) that may be used to ask the printer who it is: it is accepted
    /// without being pinned, and `remember_device` pins it once the printer's UUID shows it is not
    /// another key for a printer trusted before (trust on first use).
    pub fn new(
        store: Arc<TrustStore>,
        device_uuid: Option<&str>,
        device_name: &str,
        first_use: Option<&str>,
    ) -> CertificateValidator {
        CertificateValidator {
            store,
            device_uuid: device_uuid.map(String::from),
            device_name: device_name.to_string(),
            state: Mutex::new(State {
                rejection: None,
                accepted: None,
                first_use: first_use.map(String::from),
            }),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn error(
        &self,
        verdict: Verdict,
        authority: &str,
        fingerprint: &str,
        subject: &str,
        previous: Option<TrustedCertificate>,
    ) -> CertificateError {
        CertificateError {
            verdict,
            device_name: self.device_name.clone(),
            device_uuid: self.device_uuid.clone(),
            authority: authority.to_string(),
            fingerprint: fingerprint.to_string(),
            previous,
            subject: subject.to_string(),
        }
    }

    /// The TLS check for a connection to `authority`: `certificate` is the DER of the certificate
    /// the printer presented, `platform_trusts` whether the platform's own check passed.
    pub fn validate(
        &self,
        authority: &str,
        certificate: Option<&[u8]>,
        platform_trusts: bool,
    ) -> bool {
        if platform_trusts && certificate.is_some() {
            return true;
        }
        let parsed = certificate.and_then(Certificate::parse);
        let Some(parsed) = parsed else {
            let rejection = self.error(Verdict::Invalid, authority, "", "", None);
            self.state().rejection = Some(rejection);
            return false;
        };
        let fingerprint: String = Sha256::digest(parsed.spki)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let (verdict, previous) =
            self.store
                .check(&fingerprint, self.device_uuid.as_deref(), authority);
        let mut state = self.state();
        if verdict == Verdict::Trusted
            || (verdict == Verdict::Unknown && state.first_use.as_deref() == Some(&fingerprint))
        {
            state.accepted = Some(Accepted {
                fingerprint,
                authority: authority.to_string(),
                subject: parsed.subject(),
                pinned: verdict == Verdict::Trusted,
            });
            return true;
        }
        state.rejection = Some(self.error(
            verdict,
            authority,
            &fingerprint,
            &parsed.subject(),
            previous,
        ));
        false
    }

    /// Checks the certificate the printer was reached through against the UUID it reported (its
    /// capabilities). A pinned certificate learns the UUID when it did not have it yet: a
    /// certificate trusted for an address added by hand then also identifies the printer when
    /// discovery finds it. A first-use certificate is pinned now, with the UUID. Fails with
    /// [`Verdict::Changed`] (nothing pinned or learned) when another certificate is trusted for
    /// that printer.
    pub fn remember_device(&self, device_uuid: Option<&str>) -> Result<(), Box<CertificateError>> {
        let Some(accepted) = self.state().accepted.clone() else {
            return Ok(());
        };
        if accepted.pinned && device_uuid.is_none() {
            return Ok(());
        }
        let uuid = device_uuid.or(self.device_uuid.as_deref());
        let (verdict, previous) =
            self.store
                .check(&accepted.fingerprint, uuid, &accepted.authority);
        if verdict == Verdict::Changed {
            let mut error = self.error(
                Verdict::Changed,
                &accepted.authority,
                &accepted.fingerprint,
                &accepted.subject,
                previous,
            );
            error.device_uuid = uuid.map(String::from);
            return Err(Box::new(error));
        }
        if accepted.pinned {
            return Ok(());
        }
        if verdict == Verdict::Unknown {
            let _ = self.store.trust(
                &accepted.fingerprint,
                uuid,
                &accepted.authority,
                &self.device_name,
            );
        }
        let mut state = self.state();
        state.first_use = None;
        state.accepted = Some(Accepted {
            pinned: true,
            ..accepted
        });
        Ok(())
    }

    /// The last refusal, cleared by reading it; `None` when nothing was refused since.
    pub fn take_rejection(&self) -> Option<CertificateError> {
        self.state().rejection.take()
    }

    /// The printer is trusted for this address or UUID already: it must not be reached without TLS.
    pub fn knows(&self, authority: &str) -> bool {
        self.store.knows(self.device_uuid.as_deref(), authority)
    }

    /// A first-use certificate is waiting for `remember_device` to pin it.
    pub fn has_pending_first_use(&self) -> bool {
        self.state().first_use.is_some()
    }
}

/// The parts of an X.509 certificate the trust rules read.
struct Certificate<'a> {
    spki: &'a [u8],
    subject_name: &'a [u8],
}

impl<'a> Certificate<'a> {
    fn parse(der: &'a [u8]) -> Option<Certificate<'a>> {
        let (certificate, _) = der_element(der, 0x30)?;
        let (tbs, _) = der_element(certificate.content, 0x30)?;
        let mut rest = tbs.content;
        // The optional [0] version, then the serial number, signature, issuer and validity.
        if rest.first() == Some(&0xA0) {
            rest = der_any(rest)?.1;
        }
        for _ in 0..4 {
            rest = der_any(rest)?.1;
        }
        let (subject, rest) = der_element(rest, 0x30)?;
        let (spki, _) = der_element(rest, 0x30)?;
        Some(Certificate {
            spki: spki.whole,
            subject_name: subject.content,
        })
    }

    /// The subject as ".NET" and other platforms write it: the attributes from the most specific
    /// one, "CN=HPA1B2C3, O=HP".
    fn subject(&self) -> String {
        let mut parts = vec![];
        let mut sets = self.subject_name;
        while !sets.is_empty() {
            let Some((set, rest)) = der_element(sets, 0x31) else {
                break;
            };
            sets = rest;
            let Some((pair, _)) = der_element(set.content, 0x30) else {
                continue;
            };
            let Some((oid, value)) = der_element(pair.content, 0x06) else {
                continue;
            };
            let Some((text, _)) = der_any(value) else {
                continue;
            };
            let value = match text.tag {
                0x1E => String::from_utf16_lossy(
                    &text
                        .content
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|c| u16::from_be_bytes(*c))
                        .collect::<Vec<_>>(),
                ),
                _ => String::from_utf8_lossy(text.content).into_owned(),
            };
            parts.push(format!("{}={value}", attribute_name(oid.content)));
        }
        parts.reverse();
        parts.join(", ")
    }
}

struct Element<'a> {
    tag: u8,
    content: &'a [u8],
    whole: &'a [u8],
}

fn der_any(data: &[u8]) -> Option<(Element<'_>, &[u8])> {
    let tag = *data.first()?;
    let first = *data.get(1)?;
    let (length, header) = if first < 0x80 {
        (first as usize, 2)
    } else {
        let count = (first & 0x7F) as usize;
        if count == 0 || count > 4 {
            return None;
        }
        let bytes = data.get(2..2 + count)?;
        (
            bytes.iter().fold(0usize, |n, b| (n << 8) | *b as usize),
            2 + count,
        )
    };
    let end = header.checked_add(length)?;
    let whole = data.get(..end)?;
    Some((
        Element {
            tag,
            content: &whole[header..],
            whole,
        },
        &data[end..],
    ))
}

fn der_element(data: &[u8], tag: u8) -> Option<(Element<'_>, &[u8])> {
    der_any(data).filter(|(e, _)| e.tag == tag)
}

fn attribute_name(oid: &[u8]) -> String {
    match oid {
        [0x55, 0x04, 0x03] => "CN".into(),
        [0x55, 0x04, 0x06] => "C".into(),
        [0x55, 0x04, 0x07] => "L".into(),
        [0x55, 0x04, 0x08] => "S".into(),
        [0x55, 0x04, 0x0A] => "O".into(),
        [0x55, 0x04, 0x0B] => "OU".into(),
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x01] => "E".into(),
        _ => {
            let Some((first, rest)) = oid.split_first() else {
                return String::new();
            };
            let mut text = format!("{}.{}", first / 40, first % 40);
            let mut n: u64 = 0;
            for b in rest {
                n = (n << 7) | (*b & 0x7F) as u64;
                if b & 0x80 == 0 {
                    text.push_str(&format!(".{n}"));
                    n = 0;
                }
            }
            text
        }
    }
}
