//! The cases of the C# and Swift IppClientTests that run over plain ipp, against a loopback
//! printer; retry waits run on a fake clock, timeouts on short real ones. The TLS cases are in
//! client_tls.rs.

mod common;

use common::loopback::{Answer, Loopback, job_response, response};
use common::{fixture, printer};
use lazy_ipp::client::{Client, Clock, Options, PrintError};
use lazy_ipp::http::TcpTransport;
use lazy_ipp::job::{Job, JobState, QueuedJobState};
use lazy_ipp::requests::{self, JobTicket, MediaChoice};
use lazy_ipp::retry::RetryPolicy;
use lazy_ipp::{Attribute, Message, Value, status, tag};
use lazyprint_paper::MediaMember;
use std::cell::{Cell, RefCell};
use std::io::Write;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const USER: &str = "tester";

#[derive(Clone, Default)]
struct FakeClock {
    now: Rc<Cell<Duration>>,
    delays: Rc<RefCell<Vec<Duration>>>,
}

impl Clock for FakeClock {
    fn elapsed(&self) -> Duration {
        self.now.get()
    }

    fn sleep(&self, wait: Duration, _cancel: &AtomicBool) {
        self.delays.borrow_mut().push(wait);
        self.now.set(self.now.get() + wait);
    }

    fn start(&mut self) {
        self.now.set(Duration::ZERO);
    }
}

fn client(printer: &Loopback, clock: &FakeClock) -> Client<TcpTransport> {
    Client::new(
        TcpTransport,
        printer.address(),
        "Fake MFP",
        USER,
        None,
        Options {
            clock: Box::new(clock.clone()),
            ..Default::default()
        },
    )
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

struct Document(PathBuf);

impl Document {
    fn new(length: usize) -> Document {
        use std::sync::atomic::{AtomicU32, Ordering};
        static COUNT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "lazyprint-client-{}-{}.spool",
            std::process::id(),
            COUNT.fetch_add(1, Ordering::Relaxed)
        ));
        let bytes: Vec<u8> = (0..length).map(|i| (i * 31 % 251) as u8).collect();
        std::fs::File::create(&path)
            .unwrap()
            .write_all(&bytes)
            .unwrap();
        Document(path)
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn capabilities_answer(versions: &[&str]) -> Answer {
    let (mut message, _) = Message::decode(&printer("hp-laserjet")).unwrap();
    for group in &mut message.groups {
        for attribute in &mut group.attributes {
            if attribute.name == "ipp-versions-supported" {
                *attribute = Attribute::keywords("ipp-versions-supported", versions);
            }
        }
    }
    Answer::Ipp(message)
}

fn error_answer(code: u16) -> Answer {
    Answer::Ipp(response(code, vec![]))
}

fn version_of(received: &common::loopback::Received) -> u8 {
    received.body[0] * 10 + received.body[1]
}

#[test]
fn reads_the_capabilities() {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Ipp(
        Message::decode(&printer("hp-laserjet")).unwrap().0,
    )]);
    let mut client = client(&printer_, &FakeClock::default());
    let capabilities = client.capabilities().unwrap();
    assert_eq!(capabilities.make_and_model, "HP LaserJet Pro M404dn");
    let requests = printer_.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "/ipp/print");
    assert_eq!(requests[0].header("Content-Type"), Some("application/ipp"));
    let expected =
        requests::get_printer_attributes(&printer_.address().printer_uri(), USER, 1).encode();
    assert_eq!(requests[0].body, expected);
}

#[test]
fn print_job_sends_the_file_in_one_body_with_a_content_length() {
    let printer_ = Loopback::new();
    let mut client = client(&printer_, &FakeClock::default());
    let document = Document::new(300_000);
    let job = client.print(&document.0, &ticket()).unwrap();
    assert_eq!(
        job,
        Job {
            id: 42,
            state: JobState::Pending,
            reasons: vec!["none".into()],
            impressions: 0
        }
    );
    let requests = printer_.requests();
    assert_eq!(requests.len(), 1);
    let head = requests::print_job(&printer_.address().printer_uri(), USER, &ticket(), 1).encode();
    assert_eq!(&requests[0].body[..head.len()], head.as_slice());
    assert_eq!(requests[0].document, std::fs::read(&document.0).unwrap());
    assert_eq!(
        requests[0].header("Content-Length"),
        Some(requests[0].body.len().to_string().as_str())
    );
    assert!(requests[0].header("Transfer-Encoding").is_none());
    assert!(requests[0].header("Expect").is_none());
    assert!(document.0.exists()); // the spool is the caller's to delete
}

#[test]
fn a_printer_that_refuses_media_col_is_asked_once_more_with_the_media_name() {
    let printer_ = Loopback::new();
    printer_.script(vec![error_answer(
        status::CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED,
    )]);
    let mut client = client(&printer_, &FakeClock::default());
    let mut rich = ticket();
    rich.media.entry = Some(vec![MediaMember::keyword("media-type", "stationery")]);
    let job = client.print(&Document::new(1000).0, &rich).unwrap();
    assert_eq!(job.id, 42);
    let requests = printer_.requests();
    assert_eq!(requests.len(), 2);
    let uri = printer_.address().printer_uri();
    let first = requests::print_job(&uri, USER, &rich, 1).encode();
    let second = requests::print_job(&uri, USER, &ticket(), 2).encode();
    assert_eq!(&requests[0].body[..first.len()], first.as_slice());
    assert_eq!(&requests[1].body[..second.len()], second.as_slice());
}

#[test]
fn a_refused_print_job_without_media_col_is_not_asked_again() {
    let printer_ = Loopback::new();
    printer_.script(vec![error_answer(
        status::CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED,
    )]);
    let mut client = client(&printer_, &FakeClock::default());
    assert!(client.print(&Document::new(1000).0, &ticket()).is_err());
    assert_eq!(printer_.requests().len(), 1);
}

#[test]
fn reads_a_jobs_state_reasons_and_impressions() {
    let printer_ = Loopback::new();
    let mut answer = job_response(0, 7, 5, &["job-printing", "none"]);
    answer.groups[1].attributes.push(Attribute::one(
        "job-impressions-completed",
        Value::Integer(3),
    ));
    printer_.script(vec![Answer::Ipp(answer)]);
    let mut client = client(&printer_, &FakeClock::default());
    let job = client.job(7).unwrap();
    assert_eq!(job.state, JobState::Processing);
    assert_eq!(job.reasons, ["job-printing", "none"]);
    assert_eq!(job.impressions, 3);
    let request = printer_.requests()[0].message();
    assert_eq!(request.first("job-id"), Some(&Value::Integer(7)));
}

#[test]
fn a_job_the_printer_forgot_after_accepting_it_is_lost_contact() {
    let printer_ = Loopback::new();
    printer_.script(vec![error_answer(status::CLIENT_ERROR_NOT_FOUND)]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(
        client.job(7).unwrap_err(),
        PrintError::LostContact("Fake MFP".into())
    );
}

#[test]
fn cancel_sends_cancel_job_and_an_over_job_is_fine() {
    let printer_ = Loopback::new();
    printer_.script(vec![
        Answer::Ipp(response(0, vec![])),
        error_answer(status::CLIENT_ERROR_NOT_FOUND),
        error_answer(status::CLIENT_ERROR_NOT_POSSIBLE),
        error_answer(status::CLIENT_ERROR_FORBIDDEN),
    ]);
    let mut client = client(&printer_, &FakeClock::default());
    client.cancel_job(9).unwrap();
    client.cancel_job(9).unwrap();
    client.cancel_job(9).unwrap();
    assert!(matches!(
        client.cancel_job(9),
        Err(PrintError::Refused { .. })
    ));
    let request = printer_.requests()[0].message();
    assert_eq!(request.code, 0x0008);
    assert_eq!(request.first("job-id"), Some(&Value::Integer(9)));
    assert_eq!(
        request.first("requesting-user-name"),
        Some(&Value::Name(USER.into()))
    );
}

#[test]
fn jobs_lists_the_jobs_still_to_print_and_marks_the_users_own() {
    let printer_ = Loopback::new();
    let job = |id: i32, state: i32, owner: &str| {
        vec![
            Attribute::one("job-id", Value::Integer(id)),
            Attribute::one("job-state", Value::Enum(state)),
            Attribute::one("job-name", Value::Name(format!("Job {id}"))),
            Attribute::one("job-originating-user-name", Value::Name(owner.into())),
        ]
    };
    let mut answer = response(0, vec![]);
    answer.groups.truncate(1);
    for (id, state, owner) in [(1, 5, USER), (2, 3, "bob"), (3, 9, USER)] {
        answer.groups.push(lazy_ipp::Group {
            tag: tag::JOB_ATTRIBUTES,
            attributes: job(id, state, owner),
        });
    }
    printer_.script(vec![
        Answer::Ipp(answer),
        error_answer(status::SERVER_ERROR_OPERATION_NOT_SUPPORTED),
    ]);
    let mut client = client(&printer_, &FakeClock::default());
    let jobs = client.jobs().unwrap();
    let summary: Vec<_> = jobs.iter().map(|j| (j.id, j.state, j.can_cancel)).collect();
    assert_eq!(
        summary,
        [
            (1, QueuedJobState::Printing, true),
            (2, QueuedJobState::Waiting, false)
        ]
    );
    assert!(client.jobs().unwrap().is_empty());
}

#[test]
fn a_busy_printer_is_asked_again_with_the_file_sent_again() {
    let printer_ = Loopback::new();
    printer_.script(vec![
        Answer::BusyAfter(0),
        error_answer(status::SERVER_ERROR_BUSY),
    ]);
    let clock = FakeClock::default();
    let mut client = client(&printer_, &clock);
    let document = Document::new(50_000);
    assert_eq!(client.print(&document.0, &ticket()).unwrap().id, 42);
    let requests = printer_.requests();
    assert_eq!(requests.len(), 3);
    for request in &requests {
        assert_eq!(request.document, std::fs::read(&document.0).unwrap());
    }
    assert_eq!(
        *clock.delays.borrow(),
        [Duration::from_millis(500), Duration::from_millis(750)]
    );
}

#[test]
fn a_printer_that_stays_busy_is_busy() {
    for in_the_ipp_status in [false, true] {
        let printer_ = Loopback::new();
        printer_.handle(move |_| {
            Some(if in_the_ipp_status {
                error_answer(status::SERVER_ERROR_BUSY)
            } else {
                Answer::Http(503, vec![])
            })
        });
        let clock = FakeClock::default();
        let mut client = client(&printer_, &clock);
        assert_eq!(client.job(1).unwrap_err(), PrintError::Busy);
        let waited: Duration = clock.delays.borrow().iter().sum();
        assert!(waited <= RetryPolicy::default().give_up_after);
        assert!(printer_.requests().len() > 5);
    }
}

#[test]
fn a_printer_not_accepting_jobs_is_its_own_problem_and_not_retried() {
    let printer_ = Loopback::new();
    printer_.script(vec![error_answer(status::SERVER_ERROR_NOT_ACCEPTING_JOBS)]);
    let mut client = client(&printer_, &FakeClock::default());
    let error = client.print(&Document::new(10).0, &ticket()).unwrap_err();
    assert_eq!(
        error,
        PrintError::Refused {
            status: status::SERVER_ERROR_NOT_ACCEPTING_JOBS,
            detail: "The printer is not accepting jobs".into()
        }
    );
    assert_eq!(printer_.requests().len(), 1);
}

#[test]
fn a_version_refused_means_ipp_11_for_the_rest_of_the_session() {
    let printer_ = Loopback::new();
    printer_.script(vec![error_answer(
        status::SERVER_ERROR_VERSION_NOT_SUPPORTED,
    )]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(client.job(1).unwrap().id, 42);
    client.job(2).unwrap();
    let versions: Vec<u8> = printer_.requests().iter().map(version_of).collect();
    assert_eq!(versions, [20, 11, 11]);
}

#[test]
fn a_printer_without_ipp_20_in_its_versions_is_spoken_to_as_11() {
    let printer_ = Loopback::new();
    printer_.script(vec![capabilities_answer(&["1.0", "1.1"])]);
    let mut client = client(&printer_, &FakeClock::default());
    client.capabilities().unwrap();
    client.job(1).unwrap();
    let versions: Vec<u8> = printer_.requests().iter().map(version_of).collect();
    assert_eq!(versions, [20, 11]);

    let modern = Loopback::new();
    modern.script(vec![capabilities_answer(&["1.1", "2.0"])]);
    let mut client = self::client(&modern, &FakeClock::default());
    client.capabilities().unwrap();
    client.job(1).unwrap();
    let versions: Vec<u8> = modern.requests().iter().map(version_of).collect();
    assert_eq!(versions, [20, 20]);
}

#[test]
fn a_sign_in_is_needed_on_http_401_and_when_the_printer_wants_authentication() {
    for answer in [
        Answer::Http(401, vec![]),
        error_answer(status::CLIENT_ERROR_NOT_AUTHENTICATED),
        error_answer(status::CLIENT_ERROR_NOT_AUTHORIZED),
    ] {
        let printer_ = Loopback::new();
        printer_.script(vec![answer]);
        let mut client = client(&printer_, &FakeClock::default());
        assert_eq!(client.job(1).unwrap_err(), PrintError::NeedsSignIn);
    }
}

#[test]
fn a_sign_in_is_needed_when_the_job_waits_for_a_password() {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Ipp(job_response(
        0,
        5,
        4,
        &["job-password-wait"],
    ))]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(
        client.print(&Document::new(10).0, &ticket()).unwrap_err(),
        PrintError::NeedsSignIn
    );
    let requests = printer_.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].message().code, 0x0008); // the held job was cancelled
}

#[test]
fn an_ipp_error_is_refused_with_the_status_and_the_printers_words() {
    let printer_ = Loopback::new();
    let mut answer = response(status::CLIENT_ERROR_DOCUMENT_FORMAT_NOT_SUPPORTED, vec![]);
    answer.groups[0].attributes.push(Attribute::one(
        "status-message",
        Value::Text("No such format".into()),
    ));
    printer_.script(vec![
        Answer::Ipp(answer),
        error_answer(status::CLIENT_ERROR_BAD_REQUEST),
    ]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(
        client.job(1).unwrap_err(),
        PrintError::Refused {
            status: 0x040A,
            detail: "No such format".into()
        }
    );
    assert_eq!(
        client.job(1).unwrap_err(),
        PrintError::Refused {
            status: 0x0400,
            detail: String::new()
        }
    );
}

#[test]
fn answers_that_are_not_ipp_are_reported_for_what_they_are() {
    let printer_ = Loopback::new();
    printer_.script(vec![
        Answer::Http(404, vec![]),
        Answer::Http(200, b"<html>hello</html>".to_vec()),
        Answer::Raw(b"garbage that is not HTTP\r\n\r\n".to_vec()),
    ]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable {
            printer: "Fake MFP".into(),
            reason: "it answered HTTP 404".into()
        }
    );
    assert_eq!(client.job(1).unwrap_err(), PrintError::BadResponse);
    assert!(matches!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
}

#[test]
fn an_answer_over_eight_mebibytes_is_a_bad_response() {
    let printer_ = Loopback::new();
    let mut big = job_response(0, 1, 3, &["none"]).encode();
    big.resize(8 * 1024 * 1024 + 1, 0);
    printer_.script(vec![Answer::Http(200, big)]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(client.job(1).unwrap_err(), PrintError::BadResponse);

    // The same without a length: the body runs to the end of the connection.
    let long = Loopback::new();
    let mut raw = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_vec();
    raw.resize(raw.len() + 8 * 1024 * 1024 + 1, 0);
    long.script(vec![Answer::Raw(raw)]);
    let mut client = self::client(&long, &FakeClock::default());
    assert_eq!(client.job(1).unwrap_err(), PrintError::BadResponse);
}

#[test]
fn a_chunked_answer_is_read() {
    let printer_ = Loopback::new();
    let body = job_response(0, 11, 9, &["none"]).encode();
    let (first, second) = body.split_at(10);
    let mut raw =
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".to_vec();
    for chunk in [first, second] {
        raw.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
        raw.extend_from_slice(chunk);
        raw.extend_from_slice(b"\r\n");
    }
    raw.extend_from_slice(b"0\r\n\r\n");
    printer_.script(vec![Answer::Raw(raw)]);
    let mut client = client(&printer_, &FakeClock::default());
    let job = client.job(11).unwrap();
    assert!(job.is_finished());
}

#[test]
fn an_answer_cut_before_its_promised_length_is_unreachable() {
    let printer_ = Loopback::new();
    let body = job_response(0, 1, 3, &["none"]).encode();
    let mut raw = format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len() + 100
    )
    .into_bytes();
    raw.extend_from_slice(&body);
    printer_.script(vec![Answer::Raw(raw)]);
    let mut client = client(&printer_, &FakeClock::default());
    assert!(matches!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
}

#[test]
fn a_printer_that_is_not_there_is_unreachable() {
    let gone = Loopback::new();
    let address = gone.address();
    drop(gone);
    let mut client = Client::new(
        TcpTransport,
        address,
        "Fake MFP",
        USER,
        None,
        Options::default(),
    );
    assert_eq!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable {
            printer: "Fake MFP".into(),
            reason: "it did not answer".into()
        }
    );
}

#[test]
fn a_printer_that_stays_silent_times_out_after_the_request_timeout() {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Silent(Duration::from_millis(1500))]);
    let options = Options {
        request_timeout: Duration::from_millis(300),
        ..Default::default()
    };
    let mut client = Client::new(
        TcpTransport,
        printer_.address(),
        "Fake MFP",
        USER,
        None,
        options,
    );
    let started = Instant::now();
    assert_eq!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable {
            printer: "Fake MFP".into(),
            reason: "it did not answer in time".into()
        }
    );
    assert!(started.elapsed() < Duration::from_millis(1400));
}

#[test]
fn a_hostile_header_flood_is_refused() {
    let printer_ = Loopback::new();
    let mut raw = b"HTTP/1.1 200 OK\r\n".to_vec();
    for i in 0..200 {
        raw.extend_from_slice(format!("X-{i}: y\r\n").as_bytes());
    }
    raw.extend_from_slice(b"\r\n");
    let long_line = format!("HTTP/1.1 200 OK\r\nX: {}\r\n\r\n", "y".repeat(20_000));
    printer_.script(vec![Answer::Raw(raw), Answer::Raw(long_line.into_bytes())]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(client.job(1).unwrap_err(), PrintError::BadResponse);
    assert_eq!(client.job(1).unwrap_err(), PrintError::BadResponse);
}

#[test]
fn the_cancel_flag_stops_the_next_request() {
    let printer_ = Loopback::new();
    let mut client = client(&printer_, &FakeClock::default());
    client
        .cancel_flag()
        .store(true, std::sync::atomic::Ordering::Relaxed);
    assert_eq!(client.job(1).unwrap_err(), PrintError::Cancelled);
    assert!(printer_.requests().is_empty());
}

#[test]
fn a_cancelled_print_can_still_cancel_its_job() {
    let printer_ = Loopback::new();
    printer_.script(vec![
        Answer::Silent(Duration::from_secs(4)),
        Answer::Ipp(response(status::SUCCESSFUL_OK, vec![])),
    ]);
    let mut client = client(&printer_, &FakeClock::default());
    let flag = client.cancel_flag();
    let stopper = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        flag.store(true, std::sync::atomic::Ordering::Relaxed);
    });
    assert_eq!(client.job(1).unwrap_err(), PrintError::Cancelled);
    stopper.join().unwrap();
    client.cancel_job(7).unwrap();
    let requests = printer_.requests();
    assert_eq!(requests.last().unwrap().message().code, 0x0008);
}

#[test]
fn the_fixtures_decode_through_the_client_too() {
    let printer_ = Loopback::new();
    let data = fixture("printers/epson-ecotank.bin");
    printer_.script(vec![Answer::Http(200, data)]);
    let mut client = client(&printer_, &FakeClock::default());
    assert_eq!(client.capabilities().unwrap().name, "EPSON ET-4850 Series");
}

fn answer_of(raw: Vec<u8>) -> PrintError {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Raw(raw)]);
    client(&printer_, &FakeClock::default()).job(1).unwrap_err()
}

#[test]
fn a_chunk_size_that_overflows_the_total_is_a_bad_response() {
    for size in ["ffffffffffffffff", "7fffffffffffffff", "ffffffff"] {
        let raw = format!(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\nA\r\n{size}\r\n"
        );
        assert_eq!(answer_of(raw.into_bytes()), PrintError::BadResponse);
    }
}

#[test]
fn endless_interim_answers_are_refused() {
    let raw = "HTTP/1.1 100 Continue\r\n\r\n".repeat(10);
    assert_eq!(answer_of(raw.into_bytes()), PrintError::BadResponse);
}

#[test]
fn a_printer_trickling_its_answer_is_given_up_on() {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Trickle(Duration::from_secs(5))]);
    let options = Options {
        request_timeout: Duration::from_millis(300),
        ..Default::default()
    };
    let mut client = Client::new(
        TcpTransport,
        printer_.address(),
        "Fake MFP",
        USER,
        None,
        options,
    );
    let started = Instant::now();
    assert!(matches!(
        client.job(1).unwrap_err(),
        PrintError::Unreachable { .. }
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn the_cancel_flag_ends_a_request_that_is_waiting_for_the_printer() {
    let printer_ = Loopback::new();
    printer_.script(vec![Answer::Silent(Duration::from_secs(4))]);
    let options = Options {
        request_timeout: Duration::from_secs(30),
        ..Default::default()
    };
    let mut client = Client::new(
        TcpTransport,
        printer_.address(),
        "Fake MFP",
        USER,
        None,
        options,
    );
    let flag = client.cancel_flag();
    let stopper = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        flag.store(true, std::sync::atomic::Ordering::Relaxed);
    });
    let started = Instant::now();
    assert_eq!(client.job(1).unwrap_err(), PrintError::Cancelled);
    assert!(started.elapsed() < Duration::from_secs(2));
    stopper.join().unwrap();
}

struct CancelsWhileWaiting;

impl Clock for CancelsWhileWaiting {
    fn elapsed(&self) -> Duration {
        Duration::ZERO
    }

    fn sleep(&self, _wait: Duration, cancel: &AtomicBool) {
        assert!(!cancel.load(Ordering::Relaxed));
        cancel.store(true, Ordering::Relaxed);
    }

    fn start(&mut self) {}
}

#[test]
fn a_cancel_during_the_wait_for_a_busy_printer_ends_the_request() {
    let printer_ = Loopback::new();
    printer_.handle(|_| Some(Answer::Http(503, vec![])));
    let options = Options {
        clock: Box::new(CancelsWhileWaiting),
        ..Default::default()
    };
    let mut client = Client::new(
        TcpTransport,
        printer_.address(),
        "Fake MFP",
        USER,
        None,
        options,
    );
    assert_eq!(client.job(1).unwrap_err(), PrintError::Cancelled);
    assert_eq!(printer_.requests().len(), 1);
}

#[test]
fn the_system_clock_wait_ends_when_cancelled() {
    let cancel = Arc::new(AtomicBool::new(false));
    let setter = cancel.clone();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        setter.store(true, Ordering::Relaxed);
    });
    let started = Instant::now();
    lazy_ipp::client::SystemClock::default().sleep(Duration::from_secs(10), &cancel);
    thread.join().unwrap();
    assert!(started.elapsed() < Duration::from_secs(2));
}

struct Timeouts(Rc<RefCell<Vec<Duration>>>);

impl lazy_ipp::client::Transport for Timeouts {
    fn post(
        &mut self,
        _address: &lazy_ipp::address::PrinterAddress,
        _head: &[u8],
        _document: Option<&std::path::Path>,
        timeout: Duration,
        _cancel: &AtomicBool,
    ) -> Result<lazy_ipp::client::HttpResponse, lazy_ipp::client::TransportError> {
        self.0.borrow_mut().push(timeout);
        Err(lazy_ipp::client::TransportError::Timeout)
    }
}

#[test]
fn print_job_has_its_own_longer_timeout() {
    let seen = Rc::new(RefCell::new(vec![]));
    let options = Options {
        request_timeout: Duration::from_secs(7),
        print_timeout: Duration::from_secs(70),
        ..Default::default()
    };
    let mut client = Client::new(
        Timeouts(seen.clone()),
        lazy_ipp::address::PrinterAddress::parse("ipp://127.0.0.1:631").unwrap(),
        "Fake MFP",
        USER,
        None,
        options,
    );
    let document = Document::new(10);
    let _ = client.job(1);
    let _ = client.print(&document.0, &ticket());
    assert_eq!(
        *seen.borrow(),
        [Duration::from_secs(7), Duration::from_secs(70)]
    );
}

// Answers a Print-Job with job 5 and sets the cancel flag as it does, as a press of Cancel that
// comes in while the answer is being read.
struct CancelsAsItAnswers(Rc<RefCell<Vec<u16>>>);

impl lazy_ipp::client::Transport for CancelsAsItAnswers {
    fn post(
        &mut self,
        _address: &lazy_ipp::address::PrinterAddress,
        head: &[u8],
        _document: Option<&std::path::Path>,
        _timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<lazy_ipp::client::HttpResponse, lazy_ipp::client::TransportError> {
        let (request, _) = Message::decode(head).unwrap();
        self.0.borrow_mut().push(request.code);
        if request.code == 0x0002 {
            cancel.store(true, Ordering::Relaxed);
        }
        Ok(lazy_ipp::client::HttpResponse {
            status: 200,
            retry_after: None,
            body: job_response(status::SUCCESSFUL_OK, 5, 3, &[]).encode(),
        })
    }
}

#[test]
fn a_cancel_that_comes_with_the_answer_is_not_lost() {
    let seen = Rc::new(RefCell::new(vec![]));
    let mut client = Client::new(
        CancelsAsItAnswers(seen.clone()),
        lazy_ipp::address::PrinterAddress::parse("ipp://127.0.0.1:631").unwrap(),
        "Fake MFP",
        USER,
        None,
        Options::default(),
    );
    let error = client.print(&Document::new(10).0, &ticket()).unwrap_err();
    assert_eq!(error, PrintError::Cancelled);
    // The job the printer made is cancelled, and the flag is clear for the next request.
    assert_eq!(*seen.borrow(), [0x0002, 0x0008]);
    client.job(5).unwrap();
}
