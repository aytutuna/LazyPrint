//! IPP messages as bytes (RFC 8010).

use std::fmt;

/// An IPP version. 2.0 is sent; 1.x and 2.x are read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
}

impl Version {
    pub const V20: Version = Version { major: 2, minor: 0 };
    pub const V11: Version = Version { major: 1, minor: 1 };
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.major, self.minor)
    }
}

/// Group delimiter and value tags (RFC 8010 3.5.1, 3.5.2).
pub mod tag {
    pub const OPERATION_ATTRIBUTES: u8 = 0x01;
    pub const JOB_ATTRIBUTES: u8 = 0x02;
    pub const END_OF_ATTRIBUTES: u8 = 0x03;
    pub const PRINTER_ATTRIBUTES: u8 = 0x04;
    pub const UNSUPPORTED_ATTRIBUTES: u8 = 0x05;

    pub const UNSUPPORTED: u8 = 0x10;
    pub const UNKNOWN: u8 = 0x12;
    pub const NO_VALUE: u8 = 0x13;
    pub const INTEGER: u8 = 0x21;
    pub const BOOLEAN: u8 = 0x22;
    pub const ENUM: u8 = 0x23;
    pub const OCTET_STRING: u8 = 0x30;
    pub const DATE_TIME: u8 = 0x31;
    pub const RESOLUTION: u8 = 0x32;
    pub const RANGE_OF_INTEGER: u8 = 0x33;
    pub const BEG_COLLECTION: u8 = 0x34;
    pub const TEXT_WITH_LANGUAGE: u8 = 0x35;
    pub const NAME_WITH_LANGUAGE: u8 = 0x36;
    pub const END_COLLECTION: u8 = 0x37;
    pub const TEXT: u8 = 0x41;
    pub const NAME: u8 = 0x42;
    pub const KEYWORD: u8 = 0x44;
    pub const URI: u8 = 0x45;
    pub const URI_SCHEME: u8 = 0x46;
    pub const CHARSET: u8 = 0x47;
    pub const NATURAL_LANGUAGE: u8 = 0x48;
    pub const MIME_MEDIA_TYPE: u8 = 0x49;
    pub const MEMBER_ATTR_NAME: u8 = 0x4A;
}

/// One value of an attribute.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    Integer(i32),
    Bool(bool),
    Enum(i32),
    Octets(Vec<u8>),
    /// The 11 bytes of RFC 2579 DateAndTime, as they came.
    DateTime(Vec<u8>),
    /// Units 3 are dots per inch, 4 dots per centimetre.
    Resolution {
        x: i32,
        y: i32,
        units: u8,
    },
    Range(i32, i32),
    Text(String),
    Name(String),
    Keyword(String),
    Uri(String),
    UriScheme(String),
    Charset(String),
    Language(String),
    MimeType(String),
    Collection(Vec<Attribute>),
    /// 0x10 unsupported, 0x12 unknown, 0x13 no-value.
    OutOfBand(u8),
    /// A value tag this codec does not know, or a known one with a length it should not have, kept as it came.
    Unknown {
        tag: u8,
        value: Vec<u8>,
    },
}

/// A named attribute with one or more values.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attribute {
    pub name: String,
    pub values: Vec<Value>,
}

impl Attribute {
    pub fn new(name: &str, values: Vec<Value>) -> Attribute {
        Attribute {
            name: name.to_string(),
            values,
        }
    }

    pub fn one(name: &str, value: Value) -> Attribute {
        Attribute::new(name, vec![value])
    }

    pub fn keywords(name: &str, values: &[&str]) -> Attribute {
        Attribute::new(
            name,
            values
                .iter()
                .map(|v| Value::Keyword(v.to_string()))
                .collect(),
        )
    }
}

/// The attributes after one delimiter tag: 0x01 operation, 0x02 job, 0x04 printer, 0x05
/// unsupported, any 0x00-0x0F kept.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Group {
    pub tag: u8,
    pub attributes: Vec<Attribute>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u16)]
pub enum Operation {
    PrintJob = 0x0002,
    ValidateJob = 0x0004,
    CancelJob = 0x0008,
    GetJobAttributes = 0x0009,
    GetJobs = 0x000A,
    GetPrinterAttributes = 0x000B,
}

/// A request or a response; `code` is the operation id in a request, the status code in a response.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub version: Version,
    pub code: u16,
    pub request_id: i32,
    pub groups: Vec<Group>,
}

/// The data is cut short, is not IPP, or is bigger than a printer's answer can be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BadMessage;

impl fmt::Display for BadMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("not a valid IPP message")
    }
}

impl std::error::Error for BadMessage {}

// Real printers nest two or three deep; a reply deeper than this is hostile and would overflow the stack.
const MAX_DEPTH: usize = 16;
// The biggest real answers (a media database of a few hundred entries, a Get-Jobs reply with a group per job) stay far
// below these; a message that goes past them is built to make the reader allocate.
const MAX_GROUPS: usize = 100_000;
const MAX_ITEMS: usize = 200_000;

impl Message {
    /// Successful-ok and the two other successes (codes below 0x0100).
    pub fn is_success(&self) -> bool {
        self.code < 0x0100
    }

    /// The first attribute of that name outside the unsupported-attributes group.
    pub fn get(&self, name: &str) -> Option<&Attribute> {
        self.groups
            .iter()
            .filter(|g| g.tag != tag::UNSUPPORTED_ATTRIBUTES)
            .flat_map(|g| &g.attributes)
            .find(|a| a.name == name)
    }

    pub fn first(&self, name: &str) -> Option<&Value> {
        self.get(name).and_then(|a| a.values.first())
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = vec![self.version.major, self.version.minor];
        out.extend_from_slice(&self.code.to_be_bytes());
        out.extend_from_slice(&self.request_id.to_be_bytes());
        for group in &self.groups {
            out.push(group.tag);
            for attribute in &group.attributes {
                for (i, value) in attribute.values.iter().enumerate() {
                    write_value(&mut out, value, if i == 0 { &attribute.name } else { "" });
                }
            }
        }
        out.push(tag::END_OF_ATTRIBUTES);
        out
    }

    /// Reads a message from the start of `data`. A document, if there is one, starts at the
    /// returned offset. Data that is cut short or not IPP is an error.
    pub fn decode(data: &[u8]) -> Result<(Message, usize), BadMessage> {
        let mut r = Reader {
            data,
            pos: 0,
            items: 0,
        };
        let major = r.byte()?;
        let minor = r.byte()?;
        if major != 1 && major != 2 {
            return Err(BadMessage);
        }
        let code = r.u16()?;
        let request_id = r.i32()?;
        let mut groups = vec![];
        let mut t = r.byte()?;
        while t != tag::END_OF_ATTRIBUTES {
            if t > 0x0F || groups.len() >= MAX_GROUPS {
                return Err(BadMessage);
            }
            let group_tag = t;
            let mut attributes: Vec<Attribute> = vec![];
            t = r.byte()?;
            while t > 0x0F {
                let name_length = r.u16()? as usize;
                let name = r.text(name_length)?;
                let value = read_value(&mut r, t, 0)?;
                if !name.is_empty() {
                    attributes.push(Attribute {
                        name,
                        values: vec![value],
                    });
                } else if let Some(last) = attributes.last_mut() {
                    last.values.push(value);
                } else {
                    return Err(BadMessage);
                }
                t = r.byte()?;
            }
            groups.push(Group {
                tag: group_tag,
                attributes,
            });
        }
        let message = Message {
            version: Version { major, minor },
            code,
            request_id,
            groups,
        };
        Ok((message, r.pos))
    }
}

fn read_value(r: &mut Reader, t: u8, depth: usize) -> Result<Value, BadMessage> {
    r.count()?;
    let length = r.u16()? as usize;
    if t == tag::BEG_COLLECTION {
        if depth >= MAX_DEPTH {
            return Err(BadMessage);
        }
        r.skip(length)?;
        return read_collection(r, depth + 1);
    }
    let bytes = r.bytes(length)?;
    Ok(value(t, bytes))
}

// Members come as a memberAttrName whose value is the name, then that member's values with empty names.
fn read_collection(r: &mut Reader, depth: usize) -> Result<Value, BadMessage> {
    let mut members: Vec<Attribute> = vec![];
    loop {
        let t = r.byte()?;
        let name_length = r.u16()? as usize;
        r.skip(name_length)?;
        if t == tag::END_COLLECTION {
            let length = r.u16()? as usize;
            r.skip(length)?;
            break;
        }
        if t == tag::MEMBER_ATTR_NAME {
            r.count()?;
            let length = r.u16()? as usize;
            let name = r.text(length)?;
            members.push(Attribute {
                name,
                values: vec![],
            });
            continue;
        }
        let v = read_value(r, t, depth)?;
        members.last_mut().ok_or(BadMessage)?.values.push(v);
    }
    Ok(Value::Collection(members))
}

fn value(t: u8, bytes: &[u8]) -> Value {
    let int = |at: usize| i32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    let utf8 = || String::from_utf8_lossy(bytes).into_owned();
    match (t, bytes.len()) {
        (tag::INTEGER, 4) => Value::Integer(int(0)),
        (tag::ENUM, 4) => Value::Enum(int(0)),
        (tag::BOOLEAN, 1) => Value::Bool(bytes[0] != 0),
        (tag::OCTET_STRING, _) => Value::Octets(bytes.to_vec()),
        (tag::DATE_TIME, 11) => Value::DateTime(bytes.to_vec()),
        (tag::RESOLUTION, 9) => Value::Resolution {
            x: int(0),
            y: int(4),
            units: bytes[8],
        },
        (tag::RANGE_OF_INTEGER, 8) => Value::Range(int(0), int(4)),
        (tag::UNSUPPORTED | tag::UNKNOWN | tag::NO_VALUE, 0) => Value::OutOfBand(t),
        (tag::TEXT, _) => Value::Text(utf8()),
        (tag::NAME, _) => Value::Name(utf8()),
        (tag::KEYWORD, _) => Value::Keyword(utf8()),
        (tag::URI, _) => Value::Uri(utf8()),
        (tag::URI_SCHEME, _) => Value::UriScheme(utf8()),
        (tag::CHARSET, _) => Value::Charset(utf8()),
        (tag::NATURAL_LANGUAGE, _) => Value::Language(utf8()),
        (tag::MIME_MEDIA_TYPE, _) => Value::MimeType(utf8()),
        (tag::TEXT_WITH_LANGUAGE | tag::NAME_WITH_LANGUAGE, _) => match with_language(bytes) {
            Some(text) if t == tag::TEXT_WITH_LANGUAGE => Value::Text(text),
            Some(text) => Value::Name(text),
            None => unknown(t, bytes),
        },
        _ => unknown(t, bytes),
    }
}

fn unknown(t: u8, bytes: &[u8]) -> Value {
    Value::Unknown {
        tag: t,
        value: bytes.to_vec(),
    }
}

// Two length-prefixed strings, the language and the text; only the text is kept.
fn with_language(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 4 {
        return None;
    }
    let language = u16::from_be_bytes([bytes[0], bytes[1]]) as usize;
    let offset = 2 + language;
    if bytes.len() < offset + 2 {
        return None;
    }
    let length = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
    let text = bytes.get(offset + 2..offset + 2 + length)?;
    Some(String::from_utf8_lossy(text).into_owned())
}

// Lengths are 16 bits on the wire; a longer name or value is cut so the rest of the request keeps its framing.
fn write_entry(out: &mut Vec<u8>, t: u8, name: &str, value: &[u8]) {
    let name = &name.as_bytes()[..name.len().min(u16::MAX as usize)];
    let value = &value[..value.len().min(u16::MAX as usize)];
    out.push(t);
    out.extend_from_slice(&(name.len() as u16).to_be_bytes());
    out.extend_from_slice(name);
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
}

// A string cut at the last character boundary that fits, so a long value stays valid UTF-8.
fn cut(s: &str) -> &[u8] {
    let mut end = s.len().min(u16::MAX as usize);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s.as_bytes()[..end]
}

fn write_value(out: &mut Vec<u8>, v: &Value, name: &str) {
    let ints = |values: &[i32]| {
        values
            .iter()
            .flat_map(|v| v.to_be_bytes())
            .collect::<Vec<u8>>()
    };
    match v {
        Value::Integer(n) => write_entry(out, tag::INTEGER, name, &ints(&[*n])),
        Value::Bool(b) => write_entry(out, tag::BOOLEAN, name, &[*b as u8]),
        Value::Enum(n) => write_entry(out, tag::ENUM, name, &ints(&[*n])),
        Value::Octets(b) => write_entry(out, tag::OCTET_STRING, name, b),
        Value::DateTime(b) => write_entry(out, tag::DATE_TIME, name, b),
        Value::Resolution { x, y, units } => {
            let mut bytes = ints(&[*x, *y]);
            bytes.push(*units);
            write_entry(out, tag::RESOLUTION, name, &bytes);
        }
        Value::Range(lower, upper) => {
            write_entry(out, tag::RANGE_OF_INTEGER, name, &ints(&[*lower, *upper]))
        }
        Value::Text(s) => write_entry(out, tag::TEXT, name, cut(s)),
        Value::Name(s) => write_entry(out, tag::NAME, name, cut(s)),
        Value::Keyword(s) => write_entry(out, tag::KEYWORD, name, cut(s)),
        Value::Uri(s) => write_entry(out, tag::URI, name, cut(s)),
        Value::UriScheme(s) => write_entry(out, tag::URI_SCHEME, name, cut(s)),
        Value::Charset(s) => write_entry(out, tag::CHARSET, name, cut(s)),
        Value::Language(s) => write_entry(out, tag::NATURAL_LANGUAGE, name, cut(s)),
        Value::MimeType(s) => write_entry(out, tag::MIME_MEDIA_TYPE, name, cut(s)),
        Value::OutOfBand(t) => write_entry(out, *t, name, &[]),
        Value::Unknown { tag, value } => write_entry(out, *tag, name, value),
        Value::Collection(members) => {
            write_entry(out, tag::BEG_COLLECTION, name, &[]);
            for member in members {
                write_entry(out, tag::MEMBER_ATTR_NAME, "", member.name.as_bytes());
                for v in &member.values {
                    write_value(out, v, "");
                }
            }
            write_entry(out, tag::END_COLLECTION, "", &[]);
        }
    }
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    items: usize,
}

impl<'a> Reader<'a> {
    fn byte(&mut self) -> Result<u8, BadMessage> {
        let b = *self.data.get(self.pos).ok_or(BadMessage)?;
        self.pos += 1;
        Ok(b)
    }

    fn u16(&mut self) -> Result<u16, BadMessage> {
        Ok(u16::from_be_bytes(self.bytes(2)?.try_into().unwrap()))
    }

    fn i32(&mut self) -> Result<i32, BadMessage> {
        Ok(i32::from_be_bytes(self.bytes(4)?.try_into().unwrap()))
    }

    fn skip(&mut self, count: usize) -> Result<(), BadMessage> {
        self.bytes(count).map(|_| ())
    }

    fn bytes(&mut self, count: usize) -> Result<&'a [u8], BadMessage> {
        let end = self.pos.checked_add(count).ok_or(BadMessage)?;
        let bytes = self.data.get(self.pos..end).ok_or(BadMessage)?;
        self.pos = end;
        Ok(bytes)
    }

    fn text(&mut self, count: usize) -> Result<String, BadMessage> {
        Ok(String::from_utf8_lossy(self.bytes(count)?).into_owned())
    }

    /// Every value and member name read counts against one budget for the whole message.
    fn count(&mut self) -> Result<(), BadMessage> {
        self.items += 1;
        if self.items > MAX_ITEMS {
            return Err(BadMessage);
        }
        Ok(())
    }
}
