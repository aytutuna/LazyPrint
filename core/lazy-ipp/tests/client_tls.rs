//! The TLS cases of the C# and Swift IppClientTests. A scripted transport stands in for the
//! platform's TLS stack: it hands the printer's certificate to the validator the way a TLS
//! callback does, and answers or fails as the test says.

mod common;

use base64::Engine;
use common::{fixture, printer};
use lazy_ipp::address::PrinterAddress;
use lazy_ipp::client::{Client, HttpResponse, Options, PrintError, Transport, TransportError};
use lazy_ipp::requests::{JobTicket, MediaChoice};
use lazy_ipp::trust::{CertificateValidator, TrustStore, Verdict, spki_fingerprint};
use lazy_ipp::{Message, Value};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

const HP_UUID: &str = "4509a320-00a0-008f-00b6-9c93b9a1c2d3";

struct Dir(PathBuf);

impl Dir {
    fn new() -> Dir {
        static COUNT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "lazyprint-tls-{}-{}",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Dir(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn certificate(file: &str) -> (Vec<u8>, String) {
    let pem = String::from_utf8(fixture(file)).unwrap();
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
    let der = base64::engine::general_purpose::STANDARD
        .decode(body)
        .unwrap();
    let fingerprint = spki_fingerprint(&der).unwrap();
    (der, fingerprint)
}

type Call = (bool, bool); // secure, with a document
type Handler = Box<dyn FnMut(&PrinterAddress, bool) -> Result<HttpResponse, TransportError>>;

struct Scripted {
    calls: Rc<RefCell<Vec<Call>>>,
    handler: Handler,
}

impl Transport for Scripted {
    fn post(
        &mut self,
        address: &PrinterAddress,
        _head: &[u8],
        document: Option<&Path>,
        _timeout: Duration,
    ) -> Result<HttpResponse, TransportError> {
        self.calls
            .borrow_mut()
            .push((address.secure, document.is_some()));
        (self.handler)(address, document.is_some())
    }
}

fn ok(message: Message) -> Result<HttpResponse, TransportError> {
    Ok(HttpResponse {
        status: 200,
        retry_after: None,
        body: message.encode(),
    })
}

fn capabilities_message() -> Message {
    Message::decode(&printer("hp-laserjet")).unwrap().0
}

fn job_message() -> Message {
    let mut message = capabilities_message();
    message.groups.truncate(1);
    message.groups.push(lazy_ipp::Group {
        tag: lazy_ipp::tag::JOB_ATTRIBUTES,
        attributes: vec![
            lazy_ipp::Attribute::one("job-id", Value::Integer(42)),
            lazy_ipp::Attribute::one("job-state", Value::Enum(3)),
        ],
    });
    message.code = 0;
    message
}

fn client(
    address: &str,
    validator: Option<Arc<CertificateValidator>>,
    handler: Handler,
) -> (Client<Scripted>, Rc<RefCell<Vec<Call>>>) {
    let calls = Rc::new(RefCell::new(vec![]));
    let transport = Scripted {
        calls: calls.clone(),
        handler,
    };
    let client = Client::new(
        transport,
        PrinterAddress::parse(address).unwrap(),
        "Fake MFP",
        "tester",
        validator,
        Options::default(),
    );
    (client, calls)
}

fn ticket() -> JobTicket {
    JobTicket {
        job_name: "Report".into(),
        document_format: "application/pdf".into(),
        copies: 1,
        sides: "one-sided".into(),
        color_mode: "color".into(),
        media: MediaChoice {
            entry: None,
            name: "na_letter_8.5x11in".into(),
        },
        quality: None,
        scaling: None,
        collated_copies: false,
        page_range: None,
    }
}

fn validator(
    store: &Arc<TrustStore>,
    uuid: Option<&str>,
    first_use: Option<&str>,
) -> Arc<CertificateValidator> {
    Arc::new(CertificateValidator::new(
        store.clone(),
        uuid,
        "Fake MFP",
        first_use,
    ))
}

#[test]
fn http_upgrade_required_moves_the_printer_to_ipps() {
    let (mut client, calls) = client(
        "http-426.local",
        None,
        Box::new(|address, _| {
            if address.secure {
                ok(job_message())
            } else {
                Ok(HttpResponse {
                    status: 426,
                    retry_after: None,
                    body: vec![],
                })
            }
        }),
    );
    assert_eq!(client.job(42).unwrap().id, 42);
    assert!(client.address().secure);
    assert_eq!(*calls.borrow(), [(false, false), (true, false)]);
    // Asked once: a printer that keeps answering 426 over ipps is not followed back and forth.
    client.job(42).unwrap();
    assert_eq!(calls.borrow().len(), 3);
}

#[test]
fn a_failed_tls_handshake_falls_back_to_ipp_marked_not_encrypted() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (mut client, calls) = client(
        "ipps://fallback.local",
        Some(validator(&store, None, None)),
        Box::new(|address, _| {
            if address.secure {
                Err(TransportError::Handshake {
                    certificate_seen: false,
                })
            } else {
                ok(job_message())
            }
        }),
    );
    assert_eq!(client.job(42).unwrap().id, 42);
    assert!(client.not_encrypted());
    assert!(!client.address().secure);
    assert_eq!(*calls.borrow(), [(true, false), (false, false)]);

    // A printer without TLS is not tried over TLS again.
    let (mut again, calls) = client_for_same_printer(&store);
    again.job(42).unwrap();
    assert_eq!(*calls.borrow(), [(false, false)]);
    assert!(again.not_encrypted());
}

fn client_for_same_printer(store: &Arc<TrustStore>) -> (Client<Scripted>, Rc<RefCell<Vec<Call>>>) {
    client(
        "ipps://fallback.local",
        Some(validator(store, None, None)),
        Box::new(|_, _| ok(job_message())),
    )
}

#[test]
fn a_refused_certificate_is_never_followed_by_plain_ipp() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (der, fingerprint) = certificate("certificate-p256.pem");
    let v = validator(&store, None, None);
    let seen = v.clone();
    let (mut client, calls) = client(
        "ipps://refused.local",
        Some(v),
        Box::new(move |address, _| {
            if address.secure {
                // What the TLS stack does: the validator says no, the connection fails.
                assert!(!seen.validate(&address.authority(), Some(&der), false));
                Err(TransportError::Handshake {
                    certificate_seen: true,
                })
            } else {
                ok(job_message())
            }
        }),
    );
    let PrintError::Certificate(error) = client.job(42).unwrap_err() else {
        panic!("not a certificate error")
    };
    assert_eq!(error.verdict, Verdict::Unknown);
    assert_eq!(error.fingerprint, fingerprint);
    assert!(error.can_trust());
    assert_eq!(*calls.borrow(), [(true, false)]);
}

#[test]
fn without_a_validator_a_failed_handshake_is_never_followed_by_plain_ipp() {
    let (mut client, calls) = client(
        "ipps://novalidator.local",
        None,
        Box::new(|_, _| {
            Err(TransportError::Handshake {
                certificate_seen: false,
            })
        }),
    );
    assert!(matches!(
        client.job(42).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
    assert_eq!(*calls.borrow(), [(true, false)]);
}

#[test]
fn a_handshake_that_saw_a_certificate_is_not_a_printer_without_tls() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (mut client, calls) = client(
        "ipps://cut.local",
        Some(validator(&store, None, None)),
        Box::new(|_, _| {
            Err(TransportError::Handshake {
                certificate_seen: true,
            })
        }),
    );
    assert!(matches!(
        client.job(42).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
    assert_eq!(*calls.borrow(), [(true, false)]);
}

#[test]
fn a_printer_trusted_before_is_never_downgraded_to_plain_ipp() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    store
        .trust(&"a".repeat(64), None, "ipps-known.local:631", "Fake MFP")
        .unwrap();
    let (mut client, calls) = client(
        "ipps://ipps-known.local",
        Some(validator(&store, None, None)),
        Box::new(|_, _| {
            Err(TransportError::Handshake {
                certificate_seen: false,
            })
        }),
    );
    assert!(matches!(
        client.job(42).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
    assert_eq!(*calls.borrow(), [(true, false)]);
    assert!(!client.not_encrypted());
}

#[test]
fn a_changed_certificate_is_refused_and_never_falls_back_to_plain_ipp() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (der, fingerprint) = certificate("certificate-p256.pem");
    store
        .trust(
            &"b".repeat(64),
            Some(HP_UUID),
            "changed.local:631",
            "Fake MFP",
        )
        .unwrap();
    let v = validator(&store, Some(HP_UUID), None);
    let seen = v.clone();
    let (mut client, calls) = client(
        "ipps://changed.local",
        Some(v),
        Box::new(move |address, _| {
            if address.secure {
                assert!(!seen.validate(&address.authority(), Some(&der), false));
                Err(TransportError::Connection("handshake failed".into()))
            } else {
                ok(job_message())
            }
        }),
    );
    let PrintError::Certificate(error) = client.job(42).unwrap_err() else {
        panic!("not a certificate error")
    };
    assert_eq!(error.verdict, Verdict::Changed);
    assert_eq!(error.fingerprint, fingerprint);
    assert_eq!(error.previous.unwrap().fingerprint, "b".repeat(64));
    assert_eq!(*calls.borrow(), [(true, false)]);
}

#[test]
fn a_refusal_nobody_collected_is_not_reported_for_a_later_failure() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (der, _) = certificate("certificate-p256.pem");
    let v = validator(&store, None, None);
    let seen = v.clone();
    // The first request leaves a refusal behind and then succeeds over plain ipp; the second fails
    // for another reason and must not be blamed on the old certificate.
    let mut round = 0;
    let (mut client, _) = client(
        "ipp://stale.local",
        Some(v),
        Box::new(move |address, _| {
            round += 1;
            if round == 1 {
                seen.validate(&address.authority(), Some(&der), false);
                ok(job_message())
            } else {
                Err(TransportError::Connection("it did not answer".into()))
            }
        }),
    );
    client.job(42).unwrap();
    assert!(matches!(
        client.job(42).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
}

#[test]
fn a_first_use_certificate_is_pinned_before_the_document_goes_out() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (der, fingerprint) = certificate("certificate-p256.pem");
    let v = validator(&store, None, Some(&fingerprint));
    let seen = v.clone();
    let (mut client, calls) = client(
        "ipps://firstuse.local",
        Some(v.clone()),
        Box::new(move |address, has_document| {
            assert!(seen.validate(&address.authority(), Some(&der), false));
            ok(if has_document {
                job_message()
            } else {
                capabilities_message()
            })
        }),
    );
    let document = dir.0.join("doc.pdf");
    std::fs::write(&document, b"%PDF-1.4").unwrap();
    assert_eq!(client.print(&document, &ticket()).unwrap().id, 42);
    // Capabilities first, so the UUID can be checked, then the document.
    assert_eq!(*calls.borrow(), [(true, false), (true, true)]);
    assert!(!v.has_pending_first_use());
    let pinned = store.certificates();
    assert_eq!(pinned.len(), 1);
    assert_eq!(pinned[0].fingerprint, fingerprint);
    assert_eq!(pinned[0].device_uuid, "4509a32000a0008f00b69c93b9a1c2d3");
}

#[test]
fn a_first_use_certificate_of_a_known_printers_key_is_refused_before_the_document_goes_out() {
    let dir = Dir::new();
    let store = Arc::new(TrustStore::open(&dir.0));
    let (der, fingerprint) = certificate("certificate-p256.pem");
    store
        .trust(&"c".repeat(64), Some(HP_UUID), "192.168.1.20:443", "HP")
        .unwrap();
    let v = validator(&store, None, Some(&fingerprint));
    let seen = v.clone();
    let (mut client, calls) = client(
        "ipps://spoof.local",
        Some(v),
        Box::new(move |address, has_document| {
            assert!(!has_document, "the document must not go out");
            assert!(seen.validate(&address.authority(), Some(&der), false));
            ok(capabilities_message())
        }),
    );
    let document = dir.0.join("doc.pdf");
    std::fs::write(&document, b"%PDF-1.4").unwrap();
    let PrintError::Certificate(error) = client.print(&document, &ticket()).unwrap_err() else {
        panic!("not a certificate error")
    };
    assert_eq!(error.verdict, Verdict::Changed);
    assert_eq!(*calls.borrow(), [(true, false)]);
    assert_eq!(store.certificates().len(), 1);
}
