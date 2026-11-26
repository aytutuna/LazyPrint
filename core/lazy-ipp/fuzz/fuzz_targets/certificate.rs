#![no_main]

use lazy_ipp::trust::{CertificateValidator, TrustStore, spki_fingerprint};
use libfuzzer_sys::fuzz_target;
use std::sync::{Arc, OnceLock};

fuzz_target!(|data: &[u8]| {
    // A folder that does not exist: the store reads nothing and the validator never writes.
    static STORE: OnceLock<Arc<TrustStore>> = OnceLock::new();
    let store = STORE.get_or_init(|| {
        Arc::new(TrustStore::open(
            &std::env::temp_dir().join("lazy-ipp-fuzz-no-such-folder"),
        ))
    });
    let fingerprint = spki_fingerprint(data);
    let validator = CertificateValidator::new(store.clone(), None, "Printer", None);
    // Nothing is trusted, so every certificate is refused: one with a fingerprint can be offered for trust.
    assert!(!validator.validate("printer.local:443", Some(data), false));
    let refusal = validator.take_rejection().expect("a refusal is kept");
    assert_eq!(fingerprint.is_some(), refusal.can_trust());
});
