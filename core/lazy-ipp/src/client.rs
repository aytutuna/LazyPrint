//! The conversation with one printer: its capabilities, Print-Job, Get-Job-Attributes, Get-Jobs and
//! Cancel-Job, over a [`Transport`] that carries one HTTP POST.
//!
//! A busy printer is asked again with the file sent again. HTTP 426 moves to ipps, a failed
//! handshake to ipp, and IPP 0x0503 to version 1.1, each once. A refused certificate is never
//! followed by plain ipp.

use crate::address::PrinterAddress;
use crate::capabilities::Capabilities;
use crate::codec::{Message, Value};
use crate::job::{Job, QueuedJob, queued_jobs};
use crate::requests::{self, JobTicket};
use crate::retry::{RetryPolicy, is_retryable_http, is_retryable_ipp};
use crate::status;
use crate::trust::{CertificateError, CertificateValidator};
use std::fmt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// A printer's answer is a few hundred KB at most; a bigger one is refused before it is all read.
pub const MAX_RESPONSE: usize = 8 * 1024 * 1024;

/// What a [`Transport`] got back: the HTTP status, the Retry-After of a busy printer, and the body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub retry_after: Option<Duration>,
    pub body: Vec<u8>,
}

/// Why a request got no HTTP answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransportError {
    /// Nothing answered, or the connection dropped; the text says how.
    Connection(String),
    /// The printer was silent for longer than the timeout.
    Timeout,
    /// The TLS handshake failed; `certificate_seen` is set once it got as far as the printer's certificate.
    Handshake { certificate_seen: bool },
    /// The answer is bigger than [`MAX_RESPONSE`].
    TooLarge,
    /// The transport cannot make this kind of connection (TLS, for one without it); that says nothing about the printer.
    Unsupported,
    /// The request was stopped by [`Client::cancel_flag`].
    Cancelled,
}

/// One HTTP POST of an IPP request to a printer: `head` is the encoded operation, `document` a file
/// sent after it in the same body. The body has a Content-Length and is never chunked. `timeout` is an
/// idle one, re-armed with every chunk written and every chunk of the answer read. The request
/// ends with [`TransportError::Cancelled`] soon after `cancel` is set. A secure
/// transport checks the printer's certificate with the [`CertificateValidator`] and refuses the
/// connection when it says no.
pub trait Transport {
    fn post(
        &mut self,
        address: &PrinterAddress,
        head: &[u8],
        document: Option<&Path>,
        timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<HttpResponse, TransportError>;
}

/// Why a conversation with a printer failed.
#[derive(Clone, Debug, PartialEq)]
pub enum PrintError {
    /// An answer that is not IPP, or is cut short.
    BadResponse,
    Unreachable {
        printer: String,
        reason: String,
    },
    /// The printer stopped answering after it had the job, which it may still print.
    LostContact(String),
    /// The printer answered with an IPP status that is an error.
    Refused {
        status: u16,
        detail: String,
    },
    Busy,
    NeedsSignIn,
    Certificate(Box<CertificateError>),
    Cancelled,
}

impl fmt::Display for PrintError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PrintError::BadResponse => f.write_str("the printer's answer could not be read"),
            PrintError::Unreachable { printer, reason } => {
                write!(f, "can't reach {printer}: {reason}")
            }
            PrintError::LostContact(printer) => write!(f, "lost contact with {printer}"),
            PrintError::Refused { status, detail } if detail.is_empty() => {
                write!(f, "the printer refused the job (0x{status:04X})")
            }
            PrintError::Refused { detail, .. } => f.write_str(detail),
            PrintError::Busy => f.write_str("the printer is busy"),
            PrintError::NeedsSignIn => f.write_str("this printer asks for a sign-in"),
            PrintError::Certificate(e) => e.fmt(f),
            PrintError::Cancelled => f.write_str("cancelled"),
        }
    }
}

impl std::error::Error for PrintError {}

/// Time for the retry waits; tests pass a fake one.
pub trait Clock {
    /// Time since the first attempt of a request.
    fn elapsed(&self) -> Duration;
    /// Waits, ending early once `cancel` is set.
    fn sleep(&self, wait: Duration, cancel: &AtomicBool);
    /// Starts counting for the next request.
    fn start(&mut self);
}

#[derive(Default)]
pub struct SystemClock(Option<Instant>);

impl Clock for SystemClock {
    fn elapsed(&self) -> Duration {
        self.0.map_or(Duration::ZERO, |t| t.elapsed())
    }

    fn sleep(&self, wait: Duration, cancel: &AtomicBool) {
        let end = Instant::now() + wait;
        while !cancel.load(Ordering::Relaxed) {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            std::thread::sleep(left.min(Duration::from_millis(20)));
        }
    }

    fn start(&mut self) {
        self.0 = Some(Instant::now());
    }
}

/// Timeouts and retry timing of a [`Client`].
pub struct Options {
    /// Every request but Print-Job: a printer that is silent this long, before or while it answers, is treated as gone.
    pub request_timeout: Duration,
    /// Print-Job: counted from the last byte sent, since printers answer only once they have taken the whole document.
    pub print_timeout: Duration,
    pub retry: RetryPolicy,
    pub clock: Box<dyn Clock>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            request_timeout: Duration::from_secs(10),
            print_timeout: Duration::from_secs(120),
            retry: RetryPolicy::default(),
            clock: Box::new(SystemClock::default()),
        }
    }
}

// host:port of printers that never completed a TLS handshake and were never trusted, for the session.
static NO_TLS: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn no_tls() -> std::sync::MutexGuard<'static, Vec<String>> {
    NO_TLS.lock().unwrap_or_else(|e| e.into_inner())
}

/// IPP over HTTP for one printer. Failures are [`PrintError`]s, a refused certificate among them.
///
/// `user_name` is requesting-user-name: the account name, "iPhone" on the iPhone. The same for every
/// request, or Cancel-Job is refused.
pub struct Client<T: Transport> {
    transport: T,
    address: PrinterAddress,
    printer_name: String,
    user_name: String,
    validator: Option<Arc<CertificateValidator>>,
    options: Options,
    request_id: i32,
    speaks_11: bool,
    not_encrypted: bool,
    cancel: Arc<AtomicBool>,
}

impl<T: Transport> Client<T> {
    pub fn new(
        transport: T,
        address: PrinterAddress,
        printer_name: &str,
        user_name: &str,
        validator: Option<Arc<CertificateValidator>>,
        options: Options,
    ) -> Client<T> {
        Client {
            transport,
            address,
            printer_name: printer_name.to_string(),
            user_name: user_name.to_string(),
            validator,
            options,
            request_id: 0,
            speaks_11: false,
            not_encrypted: false,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Where requests go now: moved to ipps by an HTTP 426, or back to ipp when the TLS handshake failed.
    pub fn address(&self) -> &PrinterAddress {
        &self.address
    }

    /// The printer is reached over plain ipp because its ipps would not complete a handshake.
    pub fn not_encrypted(&self) -> bool {
        self.not_encrypted
    }

    /// Set it to stop the request in progress, or the next one if none is; the answer is
    /// [`PrintError::Cancelled`] and the flag is cleared when a request ends.
    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.cancel.clone()
    }

    /// Get-Printer-Attributes. Remembers a printer without IPP 2.0 as 1.1 for the session, and pins
    /// a certificate accepted for first use once the printer's UUID shows it is not another key for
    /// a printer trusted before.
    pub fn capabilities(&mut self) -> Result<Capabilities, PrintError> {
        let response = self.round_trip(requests::get_printer_attributes, None)?;
        succeeded(&response)?;
        let capabilities = Capabilities::from_message(&response);
        if !capabilities.ipp_versions_supported.is_empty() && !capabilities.speaks_20() {
            self.speaks_11 = true;
        }
        if let Some(validator) = &self.validator {
            validator
                .remember_device(capabilities.uuid.as_deref())
                .map_err(PrintError::Certificate)?;
        }
        Ok(capabilities)
    }

    /// Print-Job: the encoded request, then the file at `document`, in one body. A busy printer is
    /// asked again with the file sent again. The file is the caller's to delete.
    pub fn print(&mut self, document: &Path, ticket: &JobTicket) -> Result<Job, PrintError> {
        // A first-use certificate is pinned (or refused) before the document goes out over it.
        if self.address.secure
            && self
                .validator
                .as_ref()
                .is_some_and(|v| v.has_pending_first_use())
        {
            self.capabilities()?;
        }
        let (mut response, late) = self.round_trip_noting_cancel(
            |uri, user, id| requests::print_job(uri, user, ticket, id),
            Some(document),
        )?;
        if late {
            return Err(self.cancelled_after(&response));
        }
        // A printer that refuses media-col is asked once more for the paper by its name.
        if response.code == status::CLIENT_ERROR_ATTRIBUTES_OR_VALUES_NOT_SUPPORTED
            && ticket.media.entry.is_some()
        {
            let mut plain = ticket.clone();
            plain.media.entry = None;
            let late;
            (response, late) = self.round_trip_noting_cancel(
                |uri, user, id| requests::print_job(uri, user, &plain, id),
                Some(document),
            )?;
            if late {
                return Err(self.cancelled_after(&response));
            }
        }
        succeeded(&response)?;
        let job = Job::from_message(&response, None).ok_or(PrintError::BadResponse)?;
        if job.reasons.iter().any(|r| r == "job-password-wait") {
            let _ = self.cancel_job(job.id);
            return Err(PrintError::NeedsSignIn);
        }
        Ok(job)
    }

    /// Get-Job-Attributes. A printer that no longer knows an accepted job may have finished it or
    /// lost it: that is [`PrintError::LostContact`], since nothing says it was printed.
    pub fn job(&mut self, id: i32) -> Result<Job, PrintError> {
        let response = self.round_trip(
            |uri, user, rid| requests::get_job_attributes(uri, user, id, rid),
            None,
        )?;
        if response.code == status::CLIENT_ERROR_NOT_FOUND {
            return Err(PrintError::LostContact(self.printer_name.clone()));
        }
        succeeded(&response)?;
        Job::from_message(&response, Some(id)).ok_or(PrintError::BadResponse)
    }

    /// The printer's printer-state-reasons, for saying why a job waits.
    pub fn printer_reasons(&mut self) -> Result<Vec<String>, PrintError> {
        let response = self.round_trip(requests::get_printer_reasons, None)?;
        succeeded(&response)?;
        Ok(response
            .get("printer-state-reasons")
            .map(|a| {
                a.values
                    .iter()
                    .filter_map(|v| match v {
                        Value::Keyword(k) => Some(k.clone()),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Get-Jobs: what the printer still has to print, with who sent it. A printer that does not
    /// list jobs has none.
    pub fn jobs(&mut self) -> Result<Vec<QueuedJob>, PrintError> {
        let response = self.round_trip(requests::get_jobs, None)?;
        if response.code == status::SERVER_ERROR_OPERATION_NOT_SUPPORTED {
            return Ok(vec![]);
        }
        succeeded(&response)?;
        Ok(queued_jobs(&response, &self.user_name))
    }

    /// Cancel-Job. A job the printer does not know, or can no longer cancel, is already over.
    pub fn cancel_job(&mut self, id: i32) -> Result<(), PrintError> {
        let response = self.round_trip(
            |uri, user, rid| requests::cancel_job(uri, user, id, rid),
            None,
        )?;
        if response.code == status::CLIENT_ERROR_NOT_FOUND
            || response.code == status::CLIENT_ERROR_NOT_POSSIBLE
        {
            return Ok(());
        }
        succeeded(&response)
    }

    /// Sends one request and returns the printer's answer, whatever its IPP status. The cancel
    /// flag is for this request only, so the Cancel-Job that follows a stopped print still goes out.
    fn round_trip(
        &mut self,
        build: impl Fn(&str, &str, i32) -> Message,
        document: Option<&Path>,
    ) -> Result<Message, PrintError> {
        let (answer, late) = self.round_trip_noting_cancel(build, document)?;
        if late {
            return Err(PrintError::Cancelled);
        }
        Ok(answer)
    }

    /// As `round_trip`, but a cancel that came in as the answer arrived is reported beside the
    /// answer, so a caller holding a new job can cancel it.
    fn round_trip_noting_cancel(
        &mut self,
        build: impl Fn(&str, &str, i32) -> Message,
        document: Option<&Path>,
    ) -> Result<(Message, bool), PrintError> {
        let answer = self.exchange(build, document);
        let late = self.cancel.swap(false, Ordering::AcqRel);
        Ok((answer?, late))
    }

    // A cancel that arrived with a Print-Job answer: the job it made is cancelled too.
    fn cancelled_after(&mut self, response: &Message) -> PrintError {
        if succeeded(response).is_ok()
            && let Some(job) = Job::from_message(response, None)
        {
            let _ = self.cancel_job(job.id);
        }
        PrintError::Cancelled
    }

    fn exchange(
        &mut self,
        build: impl Fn(&str, &str, i32) -> Message,
        document: Option<&Path>,
    ) -> Result<Message, PrintError> {
        let mut switched = false;
        let known = |validator: &CertificateValidator, authority: &str| validator.knows(authority);
        if self.address.secure
            && let Some(validator) = &self.validator
            && no_tls().contains(&self.address.authority())
            && !known(validator, &self.address.authority())
        {
            self.address = self.address.with_secure(false);
            self.not_encrypted = true;
        }
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                return Err(PrintError::Cancelled);
            }
            if let Some(validator) = &self.validator {
                validator.take_rejection(); // a refusal left by an earlier request is not this one's
            }
            self.request_id += 1;
            let mut request = build(
                &self.address.printer_uri(),
                &self.user_name,
                self.request_id,
            );
            if self.speaks_11 {
                request = requests::downgraded(request);
            }
            let head = request.encode();
            let timeout = if document.is_some() {
                self.options.print_timeout
            } else {
                self.options.request_timeout
            };
            let outcome = self.send_retrying(&head, document, timeout);
            let response = match outcome {
                Ok(response) => response,
                Err(error) => match self.failed(error, &mut switched) {
                    Some(failure) => return Err(failure),
                    None => continue,
                },
            };

            if response.status == 426 && !self.address.secure && !switched {
                self.address = self.address.with_secure(true);
                switched = true;
                continue;
            }
            if response.status == 401 {
                return Err(PrintError::NeedsSignIn);
            }
            if is_retryable_http(response.status) {
                return Err(PrintError::Busy);
            }
            if response.body.len() > MAX_RESPONSE {
                return Err(PrintError::BadResponse);
            }
            let Ok((message, _)) = Message::decode(&response.body) else {
                return Err(if (200..300).contains(&response.status) {
                    PrintError::BadResponse
                } else {
                    self.unreachable(&format!("it answered HTTP {}", response.status))
                });
            };
            if message.code == status::SERVER_ERROR_VERSION_NOT_SUPPORTED && !self.speaks_11 {
                self.speaks_11 = true;
                continue;
            }
            return Ok(message);
        }
    }

    /// What a failed request means: `Some` is the error to give up with, `None` that the request is
    /// to be sent again over plain ipp.
    fn failed(&mut self, error: TransportError, switched: &mut bool) -> Option<PrintError> {
        if matches!(
            error,
            TransportError::Connection(_)
                | TransportError::Handshake { .. }
                | TransportError::Timeout
        ) && let Some(rejection) = self.rejection()
        {
            return Some(PrintError::Certificate(Box::new(rejection)));
        }
        match error {
            TransportError::Handshake { certificate_seen } => {
                // Only a handshake that failed before any certificate was seen, for a printer not
                // trusted before, means the printer has no usable TLS; anything else could be
                // someone cutting the connection.
                let authority = self.address.authority();
                if self.address.secure
                    && !*switched
                    && !certificate_seen
                    && self
                        .validator
                        .as_ref()
                        .is_some_and(|v| !v.knows(&authority))
                {
                    no_tls().push(authority);
                    self.address = self.address.with_secure(false);
                    self.not_encrypted = true;
                    *switched = true;
                    return None;
                }
                Some(self.unreachable("no secure connection"))
            }
            TransportError::Connection(reason) => Some(self.unreachable(&reason)),
            TransportError::Unsupported => Some(self.unreachable("no secure connection")),
            TransportError::Timeout => Some(self.unreachable("it did not answer in time")),
            TransportError::TooLarge => Some(PrintError::BadResponse),
            TransportError::Cancelled => Some(PrintError::Cancelled),
        }
    }

    fn rejection(&self) -> Option<CertificateError> {
        self.validator.as_ref().and_then(|v| v.take_rejection())
    }

    fn unreachable(&self, reason: &str) -> PrintError {
        PrintError::Unreachable {
            printer: self.printer_name.clone(),
            reason: reason.to_string(),
        }
    }

    /// Posts the request, repeating it while the printer says it is busy, per the retry policy.
    /// Returns the first other answer, or the last busy one once the policy gives up.
    fn send_retrying(
        &mut self,
        head: &[u8],
        document: Option<&Path>,
        timeout: Duration,
    ) -> Result<HttpResponse, TransportError> {
        self.options.clock.start();
        let mut retry = 0;
        loop {
            let response =
                self.transport
                    .post(&self.address, head, document, timeout, &self.cancel)?;
            let busy = is_retryable_http(response.status)
                || Message::decode(&response.body).is_ok_and(|(m, _)| is_retryable_ipp(m.code));
            if !busy {
                return Ok(response);
            }
            let wait = self.options.retry.delay_before(retry, response.retry_after);
            if self.options.clock.elapsed() + wait > self.options.retry.give_up_after {
                return Ok(response);
            }
            if self.cancel.load(Ordering::Relaxed) {
                return Err(TransportError::Cancelled);
            }
            self.options.clock.sleep(wait, &self.cancel);
            if self.cancel.load(Ordering::Relaxed) {
                return Err(TransportError::Cancelled);
            }
            retry += 1;
        }
    }
}

/// An IPP error status as the failure it is.
fn succeeded(response: &Message) -> Result<(), PrintError> {
    if response.is_success() {
        return Ok(());
    }
    let code = response.code;
    if code == status::CLIENT_ERROR_NOT_AUTHENTICATED || code == status::CLIENT_ERROR_NOT_AUTHORIZED
    {
        return Err(PrintError::NeedsSignIn);
    }
    if code == status::SERVER_ERROR_BUSY {
        return Err(PrintError::Busy);
    }
    let detail = if code == status::SERVER_ERROR_NOT_ACCEPTING_JOBS {
        "The printer is not accepting jobs".to_string()
    } else {
        match response.first("status-message") {
            Some(Value::Text(message)) => message.clone(),
            _ => String::new(),
        }
    };
    Err(PrintError::Refused {
        status: code,
        detail,
    })
}
