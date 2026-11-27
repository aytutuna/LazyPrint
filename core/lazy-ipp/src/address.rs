//! Where an IPP printer answers: scheme, host, port and resource path.
//!
//! Parsed from what a user types ("192.168.1.50", "printer.local:8631", "ipps://10.0.0.7",
//! "[fe80::1%12]:631", "http://host:8080/ipp/print") and written back in one canonical form.
//! Secure means ipps (and https); http and https are read as ipp and ipps on the port they name,
//! so a printer-uri is always ipp or ipps.

use crate::txt::DEFAULT_PATH;
use std::fmt;
use std::net::{Ipv4Addr, Ipv6Addr};

/// The port IPP uses, for ipp and ipps alike.
pub const DEFAULT_PORT: u16 = 631;

/// What is wrong with a typed address; the apps put their own words to each.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddressError {
    Empty,
    HasSpaces,
    MissingBracket,
    NotAnAddress,
    BadPort,
    BadHost,
    BadScheme,
    UserInfo,
    /// A link-local IPv6 address without the interface it is on.
    NeedsZone,
}

impl fmt::Display for AddressError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            AddressError::Empty => "no address",
            AddressError::HasSpaces => "an address cannot contain spaces",
            AddressError::MissingBracket => "an IPv6 address in brackets needs its closing bracket",
            AddressError::NotAnAddress => "not a valid address",
            AddressError::BadPort => "the port must be a number from 1 to 65535",
            AddressError::BadHost => "not a valid IP address or host name",
            AddressError::BadScheme => "the address must use ipp, ipps, http or https",
            AddressError::UserInfo => "an address cannot carry a user name or password",
            AddressError::NeedsZone => "a link-local IPv6 address needs its interface",
        })
    }
}

impl std::error::Error for AddressError {}

#[derive(Clone, Debug)]
pub struct PrinterAddress {
    /// ipps (IPP over TLS) instead of plain ipp.
    pub secure: bool,
    /// Host name (lowercase) or IP address; IPv6 without brackets, with its zone (%12) when it has one.
    pub host: String,
    pub port: u16,
    /// The IPP resource path below the host, without slashes ("ipp/print" unless given).
    pub resource_path: String,
}

impl PrinterAddress {
    fn is_ipv6(&self) -> bool {
        self.host.contains(':')
    }

    /// "host:port" (IPv6 in brackets), lowercase: identifies the endpoint, e.g. for certificate trust.
    pub fn authority(&self) -> String {
        self.uri_authority(true)
    }

    /// The printer-uri an IPP request carries: ipp or ipps, always with the port. An IPv6 zone is
    /// left out, since only this machine knows what it means.
    pub fn printer_uri(&self) -> String {
        format!(
            "{}{}{}",
            if self.secure { "ipps://" } else { "ipp://" },
            self.uri_authority(false),
            self.path_text()
        )
    }

    /// Where requests are posted: the printer-uri over http or https, an IPv6 zone written
    /// "%25" + zone as RFC 6874 asks, and the web's default port left out.
    pub fn request_url(&self) -> String {
        let (scheme, web_port) = if self.secure {
            ("https://", 443)
        } else {
            ("http://", 80)
        };
        let authority = self.uri_authority(true).replace('%', "%25");
        let authority = if self.port == web_port {
            authority
                .rsplit_once(':')
                .map_or(authority.clone(), |(h, _)| h.to_string())
        } else {
            authority
        };
        format!("{scheme}{authority}{}", self.path_text())
    }

    /// The resource path as it goes in the request line, without the leading slash.
    pub fn request_path(&self) -> String {
        escape_path(&self.resource_path)
    }

    /// The Host header: "host:port", an IPv6 address in brackets and without its zone.
    pub fn request_host(&self) -> String {
        self.uri_authority(false)
    }

    fn uri_authority(&self, zone: bool) -> String {
        let host = if zone {
            self.host.as_str()
        } else {
            self.host.split('%').next().unwrap_or_default()
        };
        if self.is_ipv6() {
            format!("[{host}]:{}", self.port)
        } else {
            format!("{host}:{}", self.port)
        }
    }

    fn path_text(&self) -> String {
        format!("/{}", escape_path(&self.resource_path))
    }

    /// The ipps address to try when a host typed bare (no scheme, no path) got no answer over
    /// plain ipp on port 631; `None` for any other address.
    pub fn https_fallback(&self, typed: &str) -> Option<PrinterAddress> {
        (!self.secure
            && self.port == DEFAULT_PORT
            && self.resource_path == DEFAULT_PATH
            && !typed.contains('/'))
        .then(|| self.with_secure(true))
    }

    /// The same host, port and path over TLS or not: where the client goes on HTTP 426 or a failed handshake.
    pub fn with_secure(&self, secure: bool) -> PrinterAddress {
        PrinterAddress {
            secure,
            ..self.clone()
        }
    }

    /// An address from its parts (a discovered service); `None` when the host is not usable.
    pub fn create(
        secure: bool,
        host: &str,
        port: u16,
        resource_path: &str,
    ) -> Option<PrinterAddress> {
        if port == 0 {
            return None;
        }
        let host = normalize_host(host.trim().trim_start_matches('[').trim_end_matches(']'))?;
        Some(PrinterAddress {
            secure,
            host,
            port,
            resource_path: resource_path.trim_matches('/').to_string(),
        })
    }

    /// Parses what a user typed. Accepted: an IPv4 or IPv6 address or host name, optionally with
    /// a port ("host:8631", "[2001:db8::1]:8631"), or an ipp, ipps, http or https URL with an
    /// optional port and resource path. Plain addresses mean ipp on port 631 at /ipp/print; an
    /// ipp or ipps URL without a port means 631, an http or https one the web's 80 or 443.
    pub fn parse(text: &str) -> Result<PrinterAddress, AddressError> {
        let value = text.trim();
        if value.is_empty() {
            return Err(AddressError::Empty);
        }
        if value.chars().any(char::is_whitespace) {
            return Err(AddressError::HasSpaces);
        }
        let has_scheme = value.contains("://");
        // "192.168.1.5/ipp/print": a path without a scheme means plain ipp.
        if !has_scheme && value.contains('/') {
            return PrinterAddress::parse(&format!("ipp://{value}"));
        }
        if has_scheme {
            return parse_url(value);
        }

        let (host, port) = if let Some(rest) = value.strip_prefix('[') {
            let close = rest.find(']').ok_or(AddressError::MissingBracket)?;
            let after = &rest[close + 1..];
            let port = match after {
                "" => None,
                _ => Some(after.strip_prefix(':').ok_or(AddressError::NotAnAddress)?),
            };
            (&rest[..close], port)
        } else if value.matches(':').count() >= 2 {
            (value, None) // a bare IPv6 address: no port
        } else {
            match value.split_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (value, None),
            }
        };
        let port = match port {
            Some(p) => parse_port(p)?,
            None => DEFAULT_PORT,
        };
        let host = normalize_host(host).ok_or(AddressError::BadHost)?;
        if lacks_zone(&host) {
            return Err(AddressError::NeedsZone);
        }
        Ok(PrinterAddress {
            secure: false,
            host,
            port,
            resource_path: DEFAULT_PATH.to_string(),
        })
    }
}

impl fmt::Display for PrinterAddress {
    /// The canonical text: the bare host for the plain default ("192.168.1.50"), "host:port" for
    /// plain ipp on another port, otherwise a URL ("ipps://10.0.0.7",
    /// "ipp://host:8080/printers/office").
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bracketed = if self.is_ipv6() {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        if !self.secure && self.resource_path == DEFAULT_PATH {
            return if self.port == DEFAULT_PORT {
                f.write_str(&bracketed)
            } else {
                write!(f, "{bracketed}:{}", self.port)
            };
        }
        // In a URL the zone's "%" is written "%25", so a zone starting with 25 reads back as it was.
        write!(
            f,
            "{}{}",
            if self.secure { "ipps://" } else { "ipp://" },
            bracketed.replace('%', "%25")
        )?;
        if self.port != DEFAULT_PORT {
            write!(f, ":{}", self.port)?;
        }
        if self.resource_path != DEFAULT_PATH {
            write!(f, "/{}", escape_path(&self.resource_path))?;
        }
        Ok(())
    }
}

impl PartialEq for PrinterAddress {
    fn eq(&self, other: &Self) -> bool {
        self.to_string().eq_ignore_ascii_case(&other.to_string())
    }
}

impl Eq for PrinterAddress {}

fn parse_url(value: &str) -> Result<PrinterAddress, AddressError> {
    let (scheme, rest) = value.split_once("://").ok_or(AddressError::NotAnAddress)?;
    if !is_scheme(scheme) {
        return Err(AddressError::NotAnAddress);
    }
    let scheme = scheme.to_ascii_lowercase();
    let (authority, path) = match rest.find(['/', '?', '#']) {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    let (user_info, authority) = match authority.rsplit_once('@') {
        Some((user_info, rest)) => (user_info, rest),
        None => ("", authority),
    };
    let bracketed = authority.starts_with('[');
    let (host, port) = if let Some(inner) = authority.strip_prefix('[') {
        let close = inner.find(']').ok_or(AddressError::NotAnAddress)?;
        let after = &inner[close + 1..];
        let port = match after {
            "" => None,
            _ => Some(after.strip_prefix(':').ok_or(AddressError::NotAnAddress)?),
        };
        (&inner[..close], port)
    } else {
        match authority.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    let port = match port {
        Some("") | None => None,
        Some(p) => Some(parse_port(p).map_err(|_| AddressError::NotAnAddress)?),
    };
    if host.is_empty() || !(bracketed || is_plausible_host(host)) {
        return Err(AddressError::NotAnAddress);
    }
    let (secure, default_port) = match scheme.as_str() {
        "ipp" => (false, DEFAULT_PORT),
        "ipps" => (true, DEFAULT_PORT),
        "http" => (false, 80),
        "https" => (true, 443),
        _ => return Err(AddressError::BadScheme),
    };
    if !user_info.is_empty() {
        return Err(AddressError::UserInfo);
    }
    // RFC 6874 writes the zone's "%" as "%25".
    let host = host.replace("%25", "%");
    let host = normalize_host(&host).ok_or(if bracketed {
        AddressError::NotAnAddress
    } else {
        AddressError::BadHost
    })?;
    if lacks_zone(&host) {
        return Err(AddressError::NeedsZone);
    }
    let flat = remove_dot_segments(path.split(['?', '#']).next().unwrap_or_default());
    let path = unescape(&flat).unwrap_or(flat);
    let path = path.trim_matches('/');
    Ok(PrinterAddress {
        secure,
        host,
        port: port.unwrap_or(default_port),
        resource_path: if path.is_empty() {
            DEFAULT_PATH.to_string()
        } else {
            path.to_string()
        },
    })
}

// A scheme as a URL writes it: a letter, then letters, digits and + - .
fn is_scheme(text: &str) -> bool {
    let mut chars = text.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
}

// What a URL's host may be before `normalize_host` reads it: digits and dots, or a DNS name.
fn is_plausible_host(host: &str) -> bool {
    host.bytes().all(|b| b.is_ascii_digit() || b == b'.') || is_dns_name(host)
}

fn parse_port(text: &str) -> Result<u16, AddressError> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(AddressError::BadPort);
    }
    match text.parse::<u32>() {
        Ok(p @ 1..=65535) => Ok(p as u16),
        _ => Err(AddressError::BadPort),
    }
}

/// A link-local IPv6 address with no zone: it cannot be reached, as discovery also finds.
pub(crate) fn lacks_zone(host: &str) -> bool {
    host.contains(':')
        && !host.contains('%')
        && host
            .parse::<Ipv6Addr>()
            .is_ok_and(|ip| ip.segments()[0] & 0xffc0 == 0xfe80)
}

/// A host name in lowercase or an IP address in its standard form (IPv6 keeps its numeric zone);
/// `None` when it is neither.
fn normalize_host(host: &str) -> Option<String> {
    if host.is_empty() {
        return None;
    }
    if host.contains(':') {
        return normalize_ipv6(host);
    }
    if host.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        // Digits and dots only: it has to be a complete dotted IPv4 address ("192.168.1" would
        // otherwise pass as a host name).
        let parts: Vec<&str> = host.split('.').collect();
        if parts.len() != 4 || parts.iter().any(|p| p.is_empty() || p.len() > 3) {
            return None;
        }
        let octets: Vec<u8> = parts
            .iter()
            .map(|p| p.parse().ok())
            .collect::<Option<_>>()?;
        return Some(Ipv4Addr::new(octets[0], octets[1], octets[2], octets[3]).to_string());
    }
    let name = host.trim_end_matches('.');
    is_dns_name(host).then(|| name.to_lowercase())
}

// A DNS name as .NET's Uri.CheckHostName takes one: labels of 1 to 63 characters, one trailing dot
// allowed, each starting with a letter or digit and holding letters, digits, '-' and '_'. Letters
// beyond ASCII make it an internationalized name.
fn is_dns_name(host: &str) -> bool {
    let mut labels: Vec<&str> = host.split('.').collect();
    if labels.len() > 1 && labels.last().is_some_and(|l| l.is_empty()) {
        labels.pop();
    }
    let other = |c: char| !c.is_ascii() && !c.is_whitespace() && !c.is_control();
    labels.iter().all(|label| {
        (1..=63).contains(&label.chars().count())
            && label.chars().enumerate().all(|(i, c)| {
                c.is_ascii_alphanumeric() || other(c) || (i > 0 && (c == '-' || c == '_'))
            })
    })
}

// A zone is an interface number, or on Unix the name of an interface on this machine, read as its
// number. Windows takes only numbers. A zone of 0 or none is no zone.
fn normalize_ipv6(text: &str) -> Option<String> {
    let (address, zone) = match text.split_once('%') {
        Some((a, z)) => (a, Some(z)),
        None => (text, None),
    };
    let ip: Ipv6Addr = address.parse().ok()?;
    let scope = match zone {
        None | Some("") => 0,
        Some(z) if z.bytes().all(|b| b.is_ascii_digit()) => z.parse::<u32>().ok()?,
        Some(name) => interface_index(name)?,
    };
    Some(if scope == 0 {
        ip.to_string()
    } else {
        format!("{ip}%{scope}")
    })
}

#[cfg(unix)]
fn interface_index(name: &str) -> Option<u32> {
    unsafe extern "C" {
        fn if_nametoindex(name: *const std::ffi::c_char) -> std::ffi::c_uint;
    }
    let name = std::ffi::CString::new(name).ok()?;
    // SAFETY: the pointer is to a NUL-terminated string that outlives the call.
    let index = unsafe { if_nametoindex(name.as_ptr()) };
    (index > 0).then_some(index)
}

#[cfg(not(unix))]
fn interface_index(_name: &str) -> Option<u32> {
    None
}

// "a/./b/../c" becomes "a/c", as System.Uri does before the path is read; the leading slash goes.
fn remove_dot_segments(path: &str) -> String {
    let mut out: Vec<&str> = vec![];
    let mut segments = path.split('/');
    if path.starts_with('/') {
        segments.next();
    }
    for segment in segments {
        match segment {
            "." => {}
            ".." => {
                out.pop();
            }
            _ => out.push(segment),
        }
    }
    out.join("/")
}

fn escape_path(path: &str) -> String {
    let mut out = String::new();
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// None when an escape is malformed or the bytes are not UTF-8: the path then stays as written.
fn unescape(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = |b: Option<&u8>| b.and_then(|b| (*b as char).to_digit(16));
            let (h, l) = (hex(bytes.get(i + 1)), hex(bytes.get(i + 2)));
            out.push((h? * 16 + l?) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}
