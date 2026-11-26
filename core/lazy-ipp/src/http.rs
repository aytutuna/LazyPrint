//! IPP over plain HTTP on a TCP socket.
//!
//! Only what IPP needs: one POST per connection with a Content-Length, answered with a
//! Content-Length, a chunked body or a body that runs to the end of the connection. The limits
//! on header and body sizes are those of a hostile printer. Platform transports that carry TLS
//! implement [`Transport`] themselves.

use crate::address::PrinterAddress;
use crate::client::{HttpResponse, MAX_RESPONSE, Transport, TransportError};
use std::fmt;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv6Addr, SocketAddr, SocketAddrV6, TcpStream, ToSocketAddrs};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const MAX_HEADER_LINE: usize = 8 * 1024;
const MAX_HEADERS: usize = 64;
const CLOSED: &str = "the connection was closed";
const MAX_INTERIM: usize = 2;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
// How long a read or write that would block waits before it looks at the flag and the clock again.
const SLICE: Duration = Duration::from_millis(5);
// A whole answer may take this many idle timeouts, so a printer trickling bytes cannot hold a request for ever.
const ANSWER_TIMEOUTS: u32 = 4;

/// Plain ipp over `TcpStream`. An ipps address is refused as unsupported, since this transport
/// has no TLS.
#[derive(Default)]
pub struct TcpTransport;

impl Transport for TcpTransport {
    fn post(
        &mut self,
        address: &PrinterAddress,
        head: &[u8],
        document: Option<&Path>,
        timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<HttpResponse, TransportError> {
        if address.secure {
            return Err(TransportError::Unsupported);
        }
        if cancel.load(Ordering::Relaxed) {
            return Err(TransportError::Cancelled);
        }
        let stream = connect(address.clone(), timeout, cancel)?;
        // Socket timeouts would leave a Windows socket in an unknown state after each miss, so the
        // socket never blocks and Watched waits itself.
        stream.set_nonblocking(true).map_err(connection)?;
        let mut watched = Watched {
            stream: &stream,
            cancel,
            idle: timeout,
            deadline: None,
            last: Instant::now(),
        };

        let mut file = match document {
            Some(path) => Some(std::fs::File::open(path).map_err(connection)?),
            None => None,
        };
        let body = match &file {
            Some(file) => file.metadata().map_err(connection)?.len(),
            None => 0,
        };
        let length = head.len() as u64 + body;
        let mut request = format!(
            "POST /{} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/ipp\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n",
            address.request_path(),
            address.request_host(),
        )
        .into_bytes();
        request.extend_from_slice(head);
        let sent = match send(&mut watched, &request, file.as_mut().map(|f| (f, body))) {
            Ok(()) => Ok(()),
            // The printer is still waiting for the rest of the body, so nothing would come back.
            Err(SendError::Local(e)) => return Err(e),
            Err(SendError::Socket(TransportError::Cancelled)) => {
                return Err(TransportError::Cancelled);
            }
            Err(SendError::Socket(e)) => Err(e),
        };
        // A printer that has made up its mind about a job (a 426, a 401) may answer before it has
        // read all of it and drop the rest, so what it said is still read.
        watched.last = Instant::now();
        watched.deadline = timeout
            .checked_mul(ANSWER_TIMEOUTS)
            .and_then(|whole| watched.last.checked_add(whole));
        match (read_response(&mut BufReader::new(watched)), sent) {
            (Err(TransportError::Connection(m)), Err(write_error)) if m == CLOSED => {
                Err(write_error)
            }
            (answer, _) => answer,
        }
    }
}

// The error a watched read or write gives when the cancel flag is set.
#[derive(Debug)]
struct Stopped;

impl fmt::Display for Stopped {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("stopped")
    }
}

impl std::error::Error for Stopped {}

// A socket whose reads and writes give up when the flag is set, when nothing has moved for the idle
// timeout, or when the deadline for the whole answer has passed.
struct Watched<'a> {
    stream: &'a TcpStream,
    cancel: &'a AtomicBool,
    idle: Duration,
    deadline: Option<Instant>,
    last: Instant,
}

impl Watched<'_> {
    fn wait(&self, e: io::Error) -> io::Result<()> {
        if !matches!(
            e.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
        ) {
            return Err(e);
        }
        if self.cancel.load(Ordering::Relaxed) {
            return Err(io::Error::other(Stopped));
        }
        if self.last.elapsed() >= self.idle || self.deadline.is_some_and(|d| Instant::now() >= d) {
            return Err(io::ErrorKind::TimedOut.into());
        }
        std::thread::sleep(SLICE);
        Ok(())
    }
}

impl Read for Watched<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            match self.stream.read(buf) {
                Ok(n) => {
                    if self.deadline.is_some_and(|d| Instant::now() >= d) {
                        return Err(io::ErrorKind::TimedOut.into());
                    }
                    self.last = Instant::now();
                    return Ok(n);
                }
                Err(e) => self.wait(e)?,
            }
        }
    }
}

impl Write for Watched<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        loop {
            match self.stream.write(buf) {
                Ok(n) => {
                    self.last = Instant::now();
                    return Ok(n);
                }
                Err(e) => self.wait(e)?,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

fn connection(e: io::Error) -> TransportError {
    if e.get_ref().is_some_and(|inner| inner.is::<Stopped>()) {
        return TransportError::Cancelled;
    }
    match e.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => TransportError::Timeout,
        _ => TransportError::Connection(describe(&e)),
    }
}

fn describe(e: &io::Error) -> String {
    match e.kind() {
        io::ErrorKind::ConnectionRefused
        | io::ErrorKind::ConnectionAborted
        | io::ErrorKind::ConnectionReset
        | io::ErrorKind::HostUnreachable
        | io::ErrorKind::NetworkUnreachable => "it did not answer".into(),
        _ => e.to_string(),
    }
}

// Name lookup and connecting run on their own thread, so that cancel and the timeout are seen
// while they block; a thread that outlives its request ends by itself and drops its socket.
fn connect(
    address: PrinterAddress,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Result<TcpStream, TransportError> {
    connect_via(move || resolve(&address), timeout, cancel)
}

fn connect_via(
    lookup: impl FnOnce() -> io::Result<Vec<SocketAddr>> + Send + 'static,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Result<TcpStream, TransportError> {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(dial(lookup, timeout));
    });
    let deadline = Instant::now().checked_add(timeout);
    loop {
        match receiver.recv_timeout(SLICE) {
            Ok(result) => return result,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                return Err(TransportError::Connection("it did not answer".into()));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
        if cancel.load(Ordering::Relaxed) {
            return Err(TransportError::Cancelled);
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return Err(TransportError::Timeout);
        }
    }
}

fn dial(
    lookup: impl FnOnce() -> io::Result<Vec<SocketAddr>>,
    timeout: Duration,
) -> Result<TcpStream, TransportError> {
    let addresses = lookup().map_err(connection)?;
    let mut last = TransportError::Connection("it did not answer".into());
    for socket in addresses {
        match TcpStream::connect_timeout(&socket, CONNECT_TIMEOUT.min(timeout)) {
            Ok(stream) => return Ok(stream),
            Err(e) => last = connection(e),
        }
    }
    Err(last)
}

// An IPv6 zone is the interface number after a '%'; std cannot read it from text.
fn resolve(address: &PrinterAddress) -> io::Result<Vec<SocketAddr>> {
    if address.host.contains(':') {
        let (ip, zone) = address.host.split_once('%').unwrap_or((&address.host, "0"));
        let ip: Ipv6Addr = ip
            .parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "not an IPv6 address"))?;
        let scope = zone.parse().unwrap_or(0);
        return Ok(vec![SocketAddr::V6(SocketAddrV6::new(
            ip,
            address.port,
            0,
            scope,
        ))]);
    }
    if let Ok(ip) = address.host.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, address.port)]);
    }
    (address.host.as_str(), address.port)
        .to_socket_addrs()
        .map(Iterator::collect)
        .map_err(|e| io::Error::new(io::ErrorKind::HostUnreachable, e))
}

#[derive(Debug)]
enum SendError {
    Local(TransportError),
    Socket(TransportError),
}

// The body is exactly `length` bytes, the size the Content-Length promised; a file that has
// shrunk since is an error here, not a printer left waiting for the rest.
fn send(
    stream: &mut impl Write,
    head: &[u8],
    document: Option<(&mut std::fs::File, u64)>,
) -> Result<(), SendError> {
    let socket = |e| SendError::Socket(connection(e));
    stream.write_all(head).map_err(socket)?;
    if let Some((file, length)) = document {
        let mut left = length;
        let mut chunk = vec![0u8; 64 * 1024];
        while left > 0 {
            let want = chunk.len().min(left as usize);
            let read = file
                .read(&mut chunk[..want])
                .map_err(|e| SendError::Local(connection(e)))?;
            if read == 0 {
                return Err(SendError::Local(TransportError::Connection(
                    "the file changed while it was sent".into(),
                )));
            }
            stream.write_all(&chunk[..read]).map_err(socket)?;
            left -= read as u64;
        }
    }
    stream.flush().map_err(socket)
}

/// Reads one HTTP answer, skipping interim ones, within the size limits of a hostile printer.
pub fn read_response(reader: &mut impl BufRead) -> Result<HttpResponse, TransportError> {
    let mut interim = 0;
    loop {
        let status_line = read_line(reader)?;
        let status = status_line
            .strip_prefix("HTTP/1.")
            .and_then(|rest| rest.get(2..5))
            .and_then(|code| code.parse::<u16>().ok())
            .ok_or_else(|| TransportError::Connection("it did not answer with HTTP".into()))?;
        let mut length = None;
        let mut chunked = false;
        let mut retry_after = None;
        for count in 0.. {
            let line = read_line(reader)?;
            if line.is_empty() {
                break;
            }
            if count >= MAX_HEADERS {
                return Err(TransportError::TooLarge);
            }
            let Some((name, value)) = line.split_once(':') else {
                continue;
            };
            let value = value.trim();
            match name.trim().to_ascii_lowercase().as_str() {
                "content-length" => length = value.parse::<u64>().ok(),
                "transfer-encoding" => chunked = value.to_ascii_lowercase().contains("chunked"),
                "retry-after" => retry_after = value.parse::<u64>().ok().map(Duration::from_secs),
                _ => {}
            }
        }
        if (100..200).contains(&status) {
            interim += 1;
            if interim > MAX_INTERIM {
                return Err(TransportError::TooLarge);
            }
            continue; // an interim answer such as 100 Continue
        }
        let body = if status == 204 || status == 304 {
            vec![]
        } else if chunked {
            read_chunked(reader)?
        } else if let Some(length) = length {
            if length > MAX_RESPONSE as u64 {
                return Err(TransportError::TooLarge);
            }
            let mut body = vec![];
            let read = reader
                .take(length)
                .read_to_end(&mut body)
                .map_err(connection)?;
            if (read as u64) < length {
                return Err(TransportError::Connection(
                    "the answer was cut short".into(),
                ));
            }
            body
        } else {
            let mut body = vec![];
            reader
                .take(MAX_RESPONSE as u64 + 1)
                .read_to_end(&mut body)
                .map_err(connection)?;
            if body.len() > MAX_RESPONSE {
                return Err(TransportError::TooLarge);
            }
            body
        };
        return Ok(HttpResponse {
            status,
            retry_after,
            body,
        });
    }
}

fn read_chunked(reader: &mut impl BufRead) -> Result<Vec<u8>, TransportError> {
    let mut body = vec![];
    loop {
        let line = read_line(reader)?;
        let size = line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size, 16)
            .map_err(|_| TransportError::Connection("the answer was not valid HTTP".into()))?;
        if size == 0 {
            // Trailers, up to the blank line.
            for _ in 0..MAX_HEADERS {
                if read_line(reader)?.is_empty() {
                    return Ok(body);
                }
            }
            return Err(TransportError::TooLarge);
        }
        if size > MAX_RESPONSE - body.len() {
            return Err(TransportError::TooLarge);
        }
        let start = body.len();
        body.resize(start + size, 0);
        reader
            .read_exact(&mut body[start..])
            .map_err(|e| match connection(e) {
                TransportError::Connection(_) => {
                    TransportError::Connection("the answer was cut short".into())
                }
                other => other,
            })?;
        if !read_line(reader)?.is_empty() {
            return Err(TransportError::Connection(
                "the answer was not valid HTTP".into(),
            ));
        }
    }
}

// One CRLF line without its ending; a longer one is a hostile printer.
fn read_line(reader: &mut impl BufRead) -> Result<String, TransportError> {
    let mut line = vec![];
    let read = reader
        .take(MAX_HEADER_LINE as u64 + 1)
        .read_until(b'\n', &mut line)
        .map_err(connection)?;
    if read == 0 {
        return Err(TransportError::Connection(CLOSED.into()));
    }
    if line.len() > MAX_HEADER_LINE {
        return Err(TransportError::TooLarge);
    }
    if line.last() != Some(&b'\n') {
        return Err(TransportError::Connection(
            "the answer was cut short".into(),
        ));
    }
    while matches!(line.last(), Some(b'\n' | b'\r')) {
        line.pop();
    }
    Ok(String::from_utf8_lossy(&line).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_ends_a_lookup_that_does_not_come_back() {
        let cancel = AtomicBool::new(true);
        let started = Instant::now();
        let result = connect_via(
            || {
                std::thread::sleep(Duration::from_secs(3));
                Ok(vec![])
            },
            Duration::from_secs(10),
            &cancel,
        );
        assert!(matches!(result, Err(TransportError::Cancelled)));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn the_timeout_ends_a_lookup_that_does_not_come_back() {
        let started = Instant::now();
        let result = connect_via(
            || {
                std::thread::sleep(Duration::from_secs(3));
                Ok(vec![])
            },
            Duration::from_millis(100),
            &AtomicBool::new(false),
        );
        assert!(matches!(result, Err(TransportError::Timeout)));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn a_timeout_too_large_to_add_to_the_clock_does_not_panic() {
        let cancel = AtomicBool::new(false);
        let result = connect_via(|| Ok(vec![]), Duration::MAX, &cancel);
        assert!(matches!(result, Err(TransportError::Connection(_))));
    }

    #[test]
    fn a_file_that_shrank_is_an_error_and_a_longer_one_is_cut() {
        let path = std::env::temp_dir().join(format!("lazy-ipp-send-{}", std::process::id()));
        std::fs::write(&path, [7u8; 100]).unwrap();
        let mut file = std::fs::File::open(&path).unwrap();
        let mut out = vec![];
        assert!(matches!(
            send(&mut out, b"", Some((&mut file, 150))),
            Err(SendError::Local(_))
        ));
        let mut file = std::fs::File::open(&path).unwrap();
        let mut out = vec![];
        send(&mut out, b"", Some((&mut file, 40))).unwrap();
        assert_eq!(out.len(), 40);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn a_closed_socket_is_a_socket_error() {
        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        assert!(matches!(
            send(&mut Broken, b"x", None),
            Err(SendError::Socket(_))
        ));
    }

    #[test]
    fn a_lookup_failure_or_a_dropped_connection_says_it_did_not_answer() {
        // .invalid never resolves (RFC 6761).
        let address = PrinterAddress {
            secure: false,
            host: "printer.invalid".into(),
            port: 631,
            resource_path: "ipp/print".into(),
        };
        let failure = resolve(&address).unwrap_err();
        assert_eq!(describe(&failure), "it did not answer");
        for kind in [
            io::ErrorKind::HostUnreachable,
            io::ErrorKind::NetworkUnreachable,
            io::ErrorKind::ConnectionAborted,
            io::ErrorKind::ConnectionReset,
            io::ErrorKind::ConnectionRefused,
        ] {
            assert_eq!(describe(&kind.into()), "it did not answer");
        }
        assert_eq!(describe(&io::Error::other("disk")), "disk");
    }
}
