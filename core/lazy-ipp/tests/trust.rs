//! The cases of the C# and Swift IppTrustTests that do not need a TLS connection, with the printer
//! certificates and the trust files both platforms wrote (testdata/ipp).

mod common;

use base64::Engine;
use common::fixture;
use lazy_ipp::trust::*;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

const UUID: &str = "564e4333-4230-3538-3930-a0b3cce51a2b";
const OTHER_UUID: &str = "cfe92100-67c4-11d4-a45f-f8d0273e1a0b";
const UUID_KEY: &str = "564e4333423035383930a0b3cce51a2b";

struct Dir(PathBuf);

impl Dir {
    fn new() -> Dir {
        static COUNT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "lazyprint-trust-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Dir(path)
    }

    fn file(&self) -> PathBuf {
        self.0.join("ipp-trust.json")
    }

    fn store(&self) -> TrustStore {
        TrustStore::open(&self.0)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fp(n: u8) -> String {
    ((b'a' + n) as char).to_string().repeat(64)
}

fn fingerprints(store: &TrustStore) -> Vec<String> {
    store
        .certificates()
        .into_iter()
        .map(|c| c.fingerprint)
        .collect()
}

fn entry(store: &TrustStore, fingerprint: &str) -> TrustedCertificate {
    store
        .certificates()
        .into_iter()
        .find(|c| c.fingerprint == fingerprint)
        .unwrap()
}

fn verdict(store: &TrustStore, fingerprint: &str, uuid: Option<&str>, authority: &str) -> Verdict {
    store.check(fingerprint, uuid, authority).0
}

fn previous(store: &TrustStore, fingerprint: &str, uuid: Option<&str>, authority: &str) -> String {
    store
        .check(fingerprint, uuid, authority)
        .1
        .map(|p| p.fingerprint)
        .unwrap_or_default()
}

fn certificate_der(file: &str) -> Vec<u8> {
    let pem = String::from_utf8(fixture(file)).unwrap();
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
    base64::engine::general_purpose::STANDARD
        .decode(body)
        .unwrap()
}

const CERTIFICATES: [(&str, &str, &str); 3] = [
    (
        "certificate-rsa2048.pem",
        "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c",
        "CN=Lazy Scan test scanner RSA-2048",
    ),
    (
        "certificate-p256.pem",
        "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4",
        "CN=Lazy Scan test scanner P-256",
    ),
    (
        "certificate-p384.pem",
        "c287be8b8476f2aaa5d6f61eee6f4a7b062c89222ad861abc1265383e5f8d9bb",
        "CN=Lazy Scan test scanner P-384",
    ),
];

#[test]
fn first_use_is_unknown_then_trusted_everywhere() {
    let dir = Dir::new();
    let store = dir.store();
    let (v, p) = store.check(&fp(0), Some(UUID), "192.168.1.20:443");
    assert_eq!((v, p), (Verdict::Unknown, None));
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    assert_eq!(
        verdict(&store, &fp(0), Some(UUID), "192.168.1.20:443"),
        Verdict::Trusted
    );
    // The pinned key is trusted at another address too (DHCP), and that address is remembered.
    assert_eq!(
        verdict(&store, &fp(0), None, "HPA1B2C3.local:443"),
        Verdict::Trusted
    );
    let certificates = dir.store().certificates();
    assert_eq!(certificates.len(), 1);
    let entry = &certificates[0];
    assert_eq!(entry.fingerprint, fp(0));
    assert_eq!(entry.device_uuid, UUID_KEY);
    assert_eq!(entry.addresses, ["192.168.1.20:443", "hpa1b2c3.local:443"]);
    assert_eq!(entry.name, "HP M479");
    assert!(entry.trusted.is_some());
}

#[test]
fn a_new_key_for_a_trusted_printer_is_a_change() {
    let dir = Dir::new();
    let store = dir.store();
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    // Same UUID, anywhere.
    let (v, p) = store.check(&fp(1), Some(&UUID.to_uppercase()), "10.0.0.5:443");
    assert_eq!(v, Verdict::Changed);
    assert_eq!(p.unwrap().fingerprint, fp(0));
    // Same address, UUID unknown (an address added by hand).
    assert_eq!(
        verdict(&store, &fp(1), None, "192.168.1.20:443"),
        Verdict::Changed
    );
    // Same address but another printer's UUID: a different device took the address.
    assert_eq!(
        verdict(&store, &fp(1), Some(OTHER_UUID), "192.168.1.20:443"),
        Verdict::Unknown
    );
    // Another port is another endpoint.
    assert_eq!(
        verdict(&store, &fp(1), None, "192.168.1.20:8443"),
        Verdict::Unknown
    );
    assert_eq!(
        verdict(&store, "", Some(UUID), "192.168.1.20:443"),
        Verdict::Invalid
    );
}

#[test]
fn trusting_the_new_key_replaces_the_old_one() {
    let dir = Dir::new();
    let store = dir.store();
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    store
        .trust(&fp(5), None, "10.0.0.9:443", "Other printer")
        .unwrap();
    store
        .trust(&fp(1), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    let reloaded = dir.store();
    assert_eq!(fingerprints(&reloaded), [fp(5), fp(1)]);
    assert_eq!(
        verdict(&reloaded, &fp(1), Some(UUID), "192.168.1.20:443"),
        Verdict::Trusted
    );
    assert_eq!(
        verdict(&reloaded, &fp(0), Some(UUID), "192.168.1.20:443"),
        Verdict::Changed
    );
    assert!(reloaded.trust("", Some(UUID), "x:1", "x").is_err());
}

#[test]
fn learning_an_address_keeps_what_another_window_trusted() {
    const S: &str = "192.168.1.20:443";
    const Y: &str = "192.168.1.30:443";
    let dir = Dir::new();
    let setup = dir.store();
    setup.trust(&fp(0), Some(UUID), S, "S").unwrap();
    setup.trust(&fp(3), Some(OTHER_UUID), Y, "Y").unwrap();
    // Two windows of the app, each with the file as it was when it started.
    let window_a = dir.store();
    let window_b = dir.store();
    // B trusts S's new certificate, and a printer A has never seen.
    window_b.trust(&fp(1), Some(UUID), S, "S").unwrap();
    window_b.trust(&fp(4), None, "10.0.0.7:443", "X").unwrap();
    // A reaches Y at a new address (DHCP): the address is learned without undoing B's changes.
    assert_eq!(
        verdict(&window_a, &fp(3), Some(OTHER_UUID), "192.168.1.31:443"),
        Verdict::Trusted
    );
    let reloaded = dir.store();
    assert_eq!(fingerprints(&reloaded), [fp(3), fp(1), fp(4)]);
    assert_eq!(
        entry(&reloaded, &fp(3)).addresses,
        ["192.168.1.30:443", "192.168.1.31:443"]
    );
    // A also sees B's pins: S's new key is trusted, the old one is a change.
    let window_a2 = dir.store();
    let stale = dir.store();
    window_b.trust(&fp(2), Some(UUID), S, "S").unwrap();
    assert_eq!(verdict(&stale, &fp(2), Some(UUID), S), Verdict::Trusted);
    assert_eq!(previous(&window_a2, &fp(1), Some(UUID), S), fp(2));
    assert_eq!(
        verdict(&window_a, &fp(4), None, "10.0.0.7:443"),
        Verdict::Trusted
    );
}

#[test]
fn a_pinned_key_does_not_vouch_for_another_printers_uuid() {
    let dir = Dir::new();
    let store = dir.store();
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    // Pinned for an address added by hand, the printer's UUID not known yet.
    store
        .trust(&fp(1), None, "hp.local:443", "hp.local")
        .unwrap();
    store
        .trust(&fp(2), Some(OTHER_UUID), "10.0.0.9:443", "Other")
        .unwrap();
    // The key pinned by address claims the trusted printer's UUID: a change, nothing learned.
    assert_eq!(previous(&store, &fp(1), Some(UUID), "hp.local:443"), fp(0));
    assert_eq!(
        verdict(&store, &fp(1), Some(UUID), "hp.local:443"),
        Verdict::Changed
    );
    assert_eq!(entry(&dir.store(), &fp(1)).device_uuid, "");
    // Another printer's key claiming it, at the trusted printer's own address too.
    assert_eq!(
        previous(&store, &fp(2), Some(UUID), "192.168.1.20:443"),
        fp(0)
    );
    // Without a UUID, or with its own, a pinned key is still trusted anywhere.
    assert_eq!(
        verdict(&store, &fp(1), None, "hp.local:443"),
        Verdict::Trusted
    );
    assert_eq!(
        verdict(&store, &fp(2), Some(OTHER_UUID), "10.0.0.10:443"),
        Verdict::Trusted
    );
    assert_eq!(
        verdict(&store, &fp(0), Some(UUID), "10.0.0.11:443"),
        Verdict::Trusted
    );
    // A UUID nobody holds is learned.
    let third = "e3248000-80ce-11db-8000-30055c773bcf";
    assert_eq!(
        verdict(&store, &fp(1), Some(third), "hp.local:443"),
        Verdict::Trusted
    );
    assert_eq!(
        entry(&dir.store(), &fp(1)).device_uuid,
        "e324800080ce11db800030055c773bcf"
    );
    // Trusting the key for the printer it claims replaces that printer's pin.
    store
        .trust(&fp(2), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    assert_eq!(fingerprints(&dir.store()), [fp(1), fp(2)]);
}

#[test]
fn trusted_certificates_stay_trusted_when_the_file_cannot_be_written() {
    let dir = Dir::new();
    let tmp = PathBuf::from(format!("{}.tmp", dir.file().display()));
    let store = dir.store();
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "S")
        .unwrap();
    // Writes fail from here on (the temporary file cannot be created); the file still reads.
    std::fs::create_dir(&tmp).unwrap();
    store
        .trust(&fp(1), Some(OTHER_UUID), "192.168.1.30:443", "Y")
        .unwrap();
    assert_eq!(fingerprints(&dir.store()), [fp(0)]);
    assert_eq!(
        verdict(&store, &fp(1), Some(OTHER_UUID), "192.168.1.30:443"),
        Verdict::Trusted
    );
    assert_eq!(
        verdict(&store, &fp(1), None, "192.168.1.31:443"),
        Verdict::Trusted
    );
    assert_eq!(
        previous(&store, &fp(5), Some(OTHER_UUID), "10.0.0.5:443"),
        fp(1)
    );
    // Another window changes the file meanwhile: its pins count, and the unsaved one is kept.
    let other_window = format!(
        r#"{{"certificates": [
          {{"fingerprint": "{}", "deviceUuid": "{UUID_KEY}", "addresses": ["192.168.1.20:443"], "name": "S"}},
          {{"fingerprint": "{}", "deviceUuid": "", "addresses": ["10.0.0.7:443"], "name": "X"}}
        ]}}"#,
        fp(0),
        fp(4)
    );
    std::fs::write(dir.file(), other_window).unwrap();
    assert_eq!(
        verdict(&store, &fp(4), None, "10.0.0.7:443"),
        Verdict::Trusted
    );
    assert_eq!(
        verdict(&store, &fp(1), Some(OTHER_UUID), "192.168.1.30:443"),
        Verdict::Trusted
    );
    // A later trust for the same printer replaces the unsaved one, which does not come back.
    store
        .trust(&fp(2), Some(OTHER_UUID), "192.168.1.30:443", "Y")
        .unwrap();
    assert_eq!(
        previous(&store, &fp(1), Some(OTHER_UUID), "192.168.1.30:443"),
        fp(2)
    );
    // Once the file can be written, the next write saves what was not saved.
    std::fs::remove_dir(&tmp).unwrap();
    assert_eq!(
        verdict(&store, &fp(2), Some(OTHER_UUID), "192.168.1.32:443"),
        Verdict::Trusted
    );
    let reloaded = dir.store();
    assert_eq!(fingerprints(&reloaded), [fp(0), fp(4), fp(2)]);
    assert_eq!(
        entry(&reloaded, &fp(2)).addresses,
        ["192.168.1.30:443", "192.168.1.32:443"]
    );
}

#[test]
fn an_undecodable_trust_file_is_kept_aside() {
    let dir = Dir::new();
    std::fs::write(dir.file(), "{ not json").unwrap();
    let store = dir.store();
    assert!(store.certificates().is_empty());
    let aside = std::fs::read_dir(&dir.0)
        .unwrap()
        .filter(|e| {
            let name = e
                .as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .into_owned();
            name.starts_with("ipp-trust.unreadable-") && name.ends_with(".json")
        })
        .count();
    assert_eq!(aside, 1);
    // A field of the wrong type resets only that field.
    let text = format!(
        r#"{{"certificates": [{{"fingerprint": "{}", "deviceUuid": 42, "addresses": ["a:1"], "name": "Kept"}}]}}"#,
        fp(2)
    );
    std::fs::write(dir.file(), text).unwrap();
    let certificates = dir.store().certificates();
    assert_eq!(certificates.len(), 1);
    assert_eq!(certificates[0].fingerprint, fp(2));
    assert_eq!(certificates[0].device_uuid, "");
    assert_eq!(certificates[0].name, "Kept");
}

#[test]
fn trust_files_from_either_platform_load() {
    let p256 = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4";
    let rsa = "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c";
    for name in ["ipp-trust-windows.json", "ipp-trust-apple.json"] {
        let dir = Dir::new();
        std::fs::write(dir.file(), fixture(name)).unwrap();
        let store = dir.store();
        assert_eq!(fingerprints(&store), [p256, rsa], "{name}");
        let certificates = store.certificates();
        let printer = &certificates[0];
        assert_eq!(printer.device_uuid, UUID_KEY);
        assert_eq!(
            printer.addresses,
            ["192.168.1.20:443", "hpa1b2c3.local:443"]
        );
        assert_eq!(printer.name, "HP Color LaserJet MFP M479fdw");
        let by_address = &certificates[1];
        assert_eq!(by_address.device_uuid, "");
        assert_eq!(by_address.addresses, ["[fe80::1%12]:443"]);
        assert_eq!(by_address.name, "fe80::1%12");
        // Each platform writes the date its own way; it is kept as it was read.
        let expected = if name == "ipp-trust-windows.json" {
            Value::String("2026-10-21T14:26:48.7107503-04:00".into())
        } else {
            serde_json::json!(814300008.71075)
        };
        assert_eq!(printer.trusted, Some(expected), "{name}");
        assert_eq!(
            verdict(&store, p256, Some(&UUID.to_uppercase()), "10.0.0.20:443"),
            Verdict::Trusted
        );
        assert_eq!(previous(&store, &fp(1), None, "[fe80::1%12]:443"), rsa);
    }
}

#[test]
fn fingerprints_are_public_key_hashes_formatted_for_people() {
    for (file, expected, _) in CERTIFICATES {
        assert_eq!(
            spki_fingerprint(&certificate_der(file)).as_deref(),
            Some(expected),
            "{file}"
        );
    }
    assert_eq!(spki_fingerprint(b"not a certificate"), None);
    assert_eq!(format_fingerprint("abcd01", 0), "AB:CD:01");
    assert_eq!(format_fingerprint("aabbcc", 2), "AA:BB\nCC");
}

fn validator(
    dir: &Dir,
    uuid: Option<&str>,
    first_use: Option<&str>,
) -> (Arc<TrustStore>, CertificateValidator) {
    let store = Arc::new(dir.store());
    let v = CertificateValidator::new(store.clone(), uuid, "Fake MFP", first_use);
    (store, v)
}

#[test]
fn the_validator_trusts_platform_valid_certificates_and_pinned_ones() {
    let dir = Dir::new();
    let (store, validator) = validator(&dir, Some(UUID), None);
    let (file, fingerprint, subject) = CERTIFICATES[1];
    let der = certificate_der(file);
    assert!(validator.validate("192.168.1.20:443", Some(&der), true));
    assert!(validator.take_rejection().is_none());
    assert!(!validator.validate("192.168.1.20:443", Some(&der), false));
    let rejection = validator.take_rejection().unwrap();
    assert_eq!(rejection.verdict, Verdict::Unknown);
    assert!(rejection.can_trust());
    assert_eq!(rejection.authority, "192.168.1.20:443");
    assert_eq!(rejection.subject, subject);
    assert_eq!(rejection.fingerprint, fingerprint);
    assert!(validator.take_rejection().is_none()); // taken once
    store
        .trust(
            &rejection.fingerprint,
            rejection.device_uuid.as_deref(),
            &rejection.authority,
            "Fake MFP",
        )
        .unwrap();
    assert!(validator.validate("192.168.1.20:443", Some(&der), false));
    assert!(!validator.validate("192.168.1.20:443", None, false));
    let missing = validator.take_rejection().unwrap();
    assert_eq!(missing.verdict, Verdict::Invalid);
    assert!(!missing.can_trust());
    assert!(!validator.validate("192.168.1.20:443", Some(b"junk"), false));
    assert_eq!(
        validator.take_rejection().unwrap().verdict,
        Verdict::Invalid
    );
}

#[test]
fn a_device_claiming_a_trusted_uuid_is_a_change_not_a_first_use() {
    let dir = Dir::new();
    let (store, first) = validator(&dir, Some(UUID), None);
    let real = certificate_der(CERTIFICATES[0].0);
    let spoof = certificate_der(CERTIFICATES[1].0);
    // Seeing a certificate pins nothing; the user trusts it.
    assert!(!first.validate("hp.local:443", Some(&real), false));
    assert_eq!(first.take_rejection().unwrap().verdict, Verdict::Unknown);
    assert!(store.certificates().is_empty());
    store
        .trust(CERTIFICATES[0].1, Some(UUID), "hp.local:443", "HP M479")
        .unwrap();
    let (_, other) = validator(&dir, Some(UUID), None);
    assert!(!other.validate("evil.local:443", Some(&spoof), false));
    let rejection = other.take_rejection().unwrap();
    assert_eq!(rejection.verdict, Verdict::Changed);
    assert_eq!(rejection.previous.unwrap().fingerprint, CERTIFICATES[0].1);
    assert_eq!(store.certificates().len(), 1);
}

#[test]
fn a_pin_made_by_address_learns_the_printers_uuid() {
    let dir = Dir::new();
    let (store, validator) = validator(&dir, None, None);
    let (file, fingerprint, _) = CERTIFICATES[1];
    let der = certificate_der(file);
    store
        .trust(fingerprint, None, "10.0.0.7:443", "10.0.0.7")
        .unwrap();
    validator.remember_device(Some(UUID)).unwrap(); // nothing accepted yet: nothing to learn
    assert_eq!(store.certificates()[0].device_uuid, "");
    assert!(validator.validate("10.0.0.7:443", Some(&der), false));
    validator.remember_device(Some(UUID)).unwrap();
    assert_eq!(dir.store().certificates()[0].device_uuid, UUID_KEY);
    // Discovery later finds the printer by its UUID at another address, with another key.
    assert_eq!(
        verdict(&store, &fp(3), Some(UUID), "192.168.1.20:443"),
        Verdict::Changed
    );
}

#[test]
fn the_validator_pins_a_first_use_certificate_only_once_its_uuid_is_checked() {
    let (file, presented, _) = CERTIFICATES[1];
    let der = certificate_der(file);
    let authority = "10.0.0.30:443";
    let dir = Dir::new();
    let store = Arc::new(dir.store());
    store
        .trust(&fp(0), Some(UUID), "192.168.1.20:443", "HP M479")
        .unwrap();
    // Not the certificate allowed for first use: refused.
    let other = CertificateValidator::new(store.clone(), None, "10.0.0.30", Some(&fp(7)));
    assert!(!other.validate(authority, Some(&der), false));
    assert_eq!(other.take_rejection().unwrap().verdict, Verdict::Unknown);
    // The first-use certificate is accepted without being pinned; it claims the trusted printer's
    // UUID, so it is a change and stays unpinned.
    let claims = CertificateValidator::new(store.clone(), None, "10.0.0.30", Some(presented));
    assert!(claims.validate(authority, Some(&der), false));
    assert_eq!(fingerprints(&store), [fp(0)]);
    let changed = claims.remember_device(Some(UUID)).unwrap_err();
    assert_eq!(changed.verdict, Verdict::Changed);
    assert_eq!(changed.previous.as_ref().unwrap().fingerprint, fp(0));
    assert_eq!(changed.fingerprint, presented);
    assert_eq!(changed.authority, authority);
    assert!(changed.can_trust());
    assert!(claims.has_pending_first_use());

    // A UUID nobody holds pins it, and the validator is done with first use.
    let fresh = CertificateValidator::new(store.clone(), None, "10.0.0.30", Some(presented));
    assert!(fresh.validate(authority, Some(&der), false));
    fresh.remember_device(Some(OTHER_UUID)).unwrap();
    assert!(!fresh.has_pending_first_use());
    assert_eq!(fingerprints(&store), [fp(0), presented.to_string()]);
    assert_eq!(
        entry(&store, presented).device_uuid,
        "cfe9210067c411d4a45ff8d0273e1a0b"
    );
    assert!(fresh.knows(authority));
}
