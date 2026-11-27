//! The requests sent to a printer, byte for byte as the Swift and C# ones.
//!
//! Every one is version 2.0 with the operation group in a fixed order: charset utf-8, language en,
//! printer-uri, requesting-user-name, then the operation's own attributes. `user_name` is the
//! account name, or "iPhone" on the iPhone, and is the same for Cancel-Job or printers refuse it.

use crate::codec::{Attribute, Group, Message, Operation, Value, Version, tag};
use lazyprint_paper::{MediaMember, MemberValue};

const NAME_LIMIT: usize = 255;

/// The paper of a job. `entry` is the attributes of a media-col-database entry, sent as media-col
/// (size, margins, media-type, media-source), so the margins the layout assumed are the ones the
/// printer uses. `name` is a PWG self-describing name ("na_letter_8.5x11in"), sent as media only
/// when there is no entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaChoice {
    pub entry: Option<Vec<MediaMember>>,
    pub name: String,
}

/// What a job asks of the printer. `sides` is "one-sided" or "two-sided-long-edge"
/// ("two-sided-short-edge" only for a document sent as is), `color_mode` "color" or "monochrome",
/// `quality` 3, 4 or 5 when chosen, `scaling` "none" for imposed sheets and "fit" or "auto" for a
/// document sent as is. `collated_copies` asks the printer to make the copies
/// (separate-documents-collated-copies); `page_range` (1-based, both ends included) is the part of
/// a document sent as is that is printed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JobTicket {
    pub job_name: String,
    pub document_format: String,
    pub copies: i32,
    pub sides: String,
    pub color_mode: String,
    pub media: MediaChoice,
    pub quality: Option<i32>,
    pub scaling: Option<String>,
    pub collated_copies: bool,
    pub page_range: Option<(i32, i32)>,
}

pub fn get_printer_attributes(printer_uri: &str, user_name: &str, request_id: i32) -> Message {
    request(
        Operation::GetPrinterAttributes,
        printer_uri,
        user_name,
        request_id,
        vec![Attribute::keywords(
            "requested-attributes",
            &["all", "media-col-database"],
        )],
    )
}

pub fn print_job(
    printer_uri: &str,
    user_name: &str,
    ticket: &JobTicket,
    request_id: i32,
) -> Message {
    let mut job = vec![];
    if ticket.copies > 1 {
        job.push(Attribute::one("copies", Value::Integer(ticket.copies)));
    }
    job.push(Attribute::one(
        "sides",
        Value::Keyword(ticket.sides.clone()),
    ));
    job.push(Attribute::one(
        "print-color-mode",
        Value::Keyword(ticket.color_mode.clone()),
    ));
    job.push(match &ticket.media.entry {
        Some(entry) => Attribute::one("media-col", Value::Collection(attributes_of(entry))),
        None => Attribute::one("media", Value::Keyword(ticket.media.name.clone())),
    });
    if let Some(quality) = ticket.quality {
        job.push(Attribute::one("print-quality", Value::Enum(quality)));
    }
    if let Some(scaling) = &ticket.scaling {
        job.push(Attribute::one(
            "print-scaling",
            Value::Keyword(scaling.clone()),
        ));
    }
    if let Some((first, last)) = ticket.page_range {
        job.push(Attribute::one("page-ranges", Value::Range(first, last)));
    }
    if ticket.collated_copies {
        job.push(Attribute::one(
            "multiple-document-handling",
            Value::Keyword("separate-documents-collated-copies".into()),
        ));
    }

    let mut message = request(
        Operation::PrintJob,
        printer_uri,
        user_name,
        request_id,
        vec![
            Attribute::one("job-name", Value::Name(truncated(&ticket.job_name))),
            Attribute::one(
                "document-format",
                Value::MimeType(ticket.document_format.clone()),
            ),
        ],
    );
    message.groups.push(Group {
        tag: tag::JOB_ATTRIBUTES,
        attributes: job,
    });
    message
}

pub fn get_job_attributes(
    printer_uri: &str,
    user_name: &str,
    job_id: i32,
    request_id: i32,
) -> Message {
    request(
        Operation::GetJobAttributes,
        printer_uri,
        user_name,
        request_id,
        vec![
            Attribute::one("job-id", Value::Integer(job_id)),
            Attribute::keywords(
                "requested-attributes",
                &[
                    "job-state",
                    "job-state-reasons",
                    "job-impressions-completed",
                ],
            ),
        ],
    )
}

pub fn get_jobs(printer_uri: &str, user_name: &str, request_id: i32) -> Message {
    request(
        Operation::GetJobs,
        printer_uri,
        user_name,
        request_id,
        vec![
            Attribute::one("which-jobs", Value::Keyword("not-completed".into())),
            Attribute::keywords(
                "requested-attributes",
                &[
                    "job-id",
                    "job-name",
                    "job-originating-user-name",
                    "job-state",
                    "job-impressions-completed",
                ],
            ),
        ],
    )
}

pub fn get_printer_reasons(printer_uri: &str, user_name: &str, request_id: i32) -> Message {
    request(
        Operation::GetPrinterAttributes,
        printer_uri,
        user_name,
        request_id,
        vec![Attribute::keywords(
            "requested-attributes",
            &["printer-state-reasons"],
        )],
    )
}

pub fn cancel_job(printer_uri: &str, user_name: &str, job_id: i32, request_id: i32) -> Message {
    request(
        Operation::CancelJob,
        printer_uri,
        user_name,
        request_id,
        vec![Attribute::one("job-id", Value::Integer(job_id))],
    )
}

/// The same request as IPP 1.1, for a printer that does not speak 2.0.
pub fn downgraded(mut request: Message) -> Message {
    request.version = Version::V11;
    request
}

/// An address typed as http or https goes in the request as ipp or ipps.
pub(crate) fn ipp_uri(address: &str) -> String {
    let swap = |prefix: &str, scheme: &str| {
        address
            .get(..prefix.len())
            .filter(|p| p.eq_ignore_ascii_case(prefix))
            .map(|_| format!("{scheme}{}", &address[prefix.len()..]))
    };
    swap("http://", "ipp://")
        .or_else(|| swap("https://", "ipps://"))
        .unwrap_or_else(|| address.to_string())
}

/// The text cut to 255 bytes of UTF-8 without splitting a character.
pub fn truncated(text: &str) -> String {
    let mut result = String::new();
    for c in text.chars() {
        if result.len() + c.len_utf8() > NAME_LIMIT {
            break;
        }
        result.push(c);
    }
    result
}

fn request(
    operation: Operation,
    printer_uri: &str,
    user_name: &str,
    request_id: i32,
    own: Vec<Attribute>,
) -> Message {
    let mut attributes = vec![
        Attribute::one("attributes-charset", Value::Charset("utf-8".into())),
        Attribute::one("attributes-natural-language", Value::Language("en".into())),
        Attribute::one("printer-uri", Value::Uri(ipp_uri(printer_uri))),
        Attribute::one("requesting-user-name", Value::Name(truncated(user_name))),
    ];
    attributes.extend(own);
    Message {
        version: Version::V20,
        code: operation as u16,
        request_id,
        groups: vec![Group {
            tag: tag::OPERATION_ATTRIBUTES,
            attributes,
        }],
    }
}

fn attributes_of(members: &[MediaMember]) -> Vec<Attribute> {
    members
        .iter()
        .map(|m| Attribute {
            name: m.name.clone(),
            values: m
                .values
                .iter()
                .map(|v| match v {
                    MemberValue::Integer(n) => Value::Integer(*n),
                    MemberValue::Keyword(k) | MemberValue::Other(k) => Value::Keyword(k.clone()),
                    MemberValue::Name(n) => Value::Name(n.clone()),
                    MemberValue::Text(t) => Value::Text(t.clone()),
                    MemberValue::Octets(b) => Value::Octets(b.clone()),
                    MemberValue::Collection(c) => Value::Collection(attributes_of(c)),
                })
                .collect(),
        })
        .collect()
}
