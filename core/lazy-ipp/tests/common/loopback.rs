// A printer on 127.0.0.1 that answers from a script. Requests it has read are kept for the test.

use lazy_ipp::address::PrinterAddress;
use lazy_ipp::{Attribute, Group, Message, Value, Version, tag};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct Received {
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// What follows the IPP message in the body.
    pub document: Vec<u8>,
}

impl Received {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn message(&self) -> Message {
        Message::decode(&self.body).unwrap().0
    }
}

pub enum Answer {
    /// An IPP message in a 200 answer.
    Ipp(Message),
    /// A status and body, with a Content-Length.
    Http(u16, Vec<u8>),
    /// The bytes as they are, for answers that are not well formed HTTP.
    Raw(Vec<u8>),
    /// A 503 with a Retry-After.
    BusyAfter(u64),
    /// Stays silent this long, then drops the connection.
    Silent(Duration),
    /// Starts an answer and sends a byte of its headers every 50 ms for this long.
    Trickle(Duration),
}

type Handler = Box<dyn Fn(&Received) -> Option<Answer> + Send>;

pub struct Loopback {
    pub port: u16,
    pub requests: Arc<Mutex<Vec<Received>>>,
    script: Arc<Mutex<VecDeque<Answer>>>,
    handler: Arc<Mutex<Option<Handler>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

pub fn response(code: u16, attributes: Vec<Attribute>) -> Message {
    Message {
        version: Version::V20,
        code,
        request_id: 1,
        groups: vec![
            Group {
                tag: tag::OPERATION_ATTRIBUTES,
                attributes: vec![
                    Attribute::one("attributes-charset", Value::Charset("utf-8".into())),
                    Attribute::one("attributes-natural-language", Value::Language("en".into())),
                ],
            },
            Group {
                tag: tag::JOB_ATTRIBUTES,
                attributes,
            },
        ],
    }
}

pub fn job_response(code: u16, id: i32, state: i32, reasons: &[&str]) -> Message {
    response(
        code,
        vec![
            Attribute::one("job-id", Value::Integer(id)),
            Attribute::one("job-state", Value::Enum(state)),
            Attribute::keywords("job-state-reasons", reasons),
        ],
    )
}

impl Loopback {
    /// Answers every request with a pending job 42 unless the script says otherwise.
    pub fn new() -> Loopback {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(vec![]));
        let script = Arc::new(Mutex::new(VecDeque::new()));
        let handler: Arc<Mutex<Option<Handler>>> = Arc::new(Mutex::new(None));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (requests, script, handler, stop) = (
                requests.clone(),
                script.clone(),
                handler.clone(),
                stop.clone(),
            );
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let _ = stream.set_nonblocking(false);
                            serve(stream, &requests, &script, &handler);
                        }
                        Err(_) => std::thread::sleep(Duration::from_millis(2)),
                    }
                }
            })
        };
        Loopback {
            port,
            requests,
            script,
            handler,
            stop,
            thread: Some(thread),
        }
    }

    pub fn address(&self) -> PrinterAddress {
        PrinterAddress::parse(&format!("127.0.0.1:{}", self.port)).unwrap()
    }

    /// The next answers, one per request; after them the default one.
    pub fn script(&self, answers: Vec<Answer>) {
        self.script.lock().unwrap().extend(answers);
    }

    /// Decides the answer to a request when the script is empty; `None` gives the default.
    pub fn handle(&self, f: impl Fn(&Received) -> Option<Answer> + Send + 'static) {
        *self.handler.lock().unwrap() = Some(Box::new(f));
    }

    pub fn requests(&self) -> Vec<Received> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for Loopback {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn serve(
    mut stream: TcpStream,
    requests: &Mutex<Vec<Received>>,
    script: &Mutex<VecDeque<Answer>>,
    handler: &Mutex<Option<Handler>>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let Some(received) = read_request(&mut stream) else {
        return;
    };
    requests.lock().unwrap().push(received.clone());
    let answer = script
        .lock()
        .unwrap()
        .pop_front()
        .or_else(|| handler.lock().unwrap().as_ref().and_then(|h| h(&received)))
        .unwrap_or_else(|| Answer::Ipp(job_response(0, 42, 3, &["none"])));
    match answer {
        Answer::Ipp(message) => {
            let body = message.encode();
            let _ = write_http(
                &mut stream,
                200,
                &body,
                &[("Content-Type", "application/ipp")],
            );
        }
        Answer::Http(status, body) => {
            let _ = write_http(&mut stream, status, &body, &[]);
        }
        Answer::Raw(bytes) => {
            let _ = stream.write_all(&bytes);
        }
        Answer::BusyAfter(seconds) => {
            let retry = seconds.to_string();
            let _ = write_http(&mut stream, 503, b"", &[("Retry-After", retry.as_str())]);
        }
        Answer::Silent(wait) => std::thread::sleep(wait),
        Answer::Trickle(total) => {
            let started = std::time::Instant::now();
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nX: ");
            while started.elapsed() < total && stream.write_all(b"y").is_ok() {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn write_http(
    stream: &mut TcpStream,
    status: u16,
    body: &[u8],
    extra: &[(&str, &str)],
) -> std::io::Result<()> {
    let mut text = format!(
        "HTTP/1.1 {status} Status\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (name, value) in extra {
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    text.push_str("\r\n");
    stream.write_all(text.as_bytes())?;
    stream.write_all(body)
}

fn read_request(stream: &mut TcpStream) -> Option<Received> {
    let mut data = vec![];
    let mut chunk = [0u8; 8192];
    let end = loop {
        if let Some(i) = data.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        data.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&data[..end]).into_owned();
    let mut lines = head.lines();
    let path = lines.next()?.split(' ').nth(1)?.to_string();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(n, v)| (n.trim().to_string(), v.trim().to_string()))
        .collect();
    let length: usize = headers
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.parse().ok())?;
    let mut body = data[end + 4..].to_vec();
    while body.len() < length {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    let offset = Message::decode(&body).map_or(body.len(), |(_, o)| o);
    let document = body[offset..].to_vec();
    Some(Received {
        path,
        headers,
        body,
        document,
    })
}
