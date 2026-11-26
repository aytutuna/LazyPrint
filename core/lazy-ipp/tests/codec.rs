//! The cases of the C# and Swift IppCodecTests.

mod common;

use common::{PRINTERS, printer};
use lazy_ipp::{Attribute, Group, Message, Value, Version, tag};

fn roundtrip(message: &Message) -> Message {
    Message::decode(&message.encode()).unwrap().0
}

fn single(attributes: Vec<Attribute>) -> Message {
    Message {
        version: Version::V20,
        code: 0,
        request_id: 7,
        groups: vec![Group {
            tag: tag::PRINTER_ATTRIBUTES,
            attributes,
        }],
    }
}

fn int(name: &str, n: i32) -> Attribute {
    Attribute::one(name, Value::Integer(n))
}

#[test]
fn small_request_is_the_bytes_of_rfc_8010() {
    let message = Message {
        version: Version::V20,
        code: 0x000B,
        request_id: 1,
        groups: vec![Group {
            tag: tag::OPERATION_ATTRIBUTES,
            attributes: vec![Attribute::one(
                "attributes-charset",
                Value::Charset("utf-8".into()),
            )],
        }],
    };
    let mut expected = vec![
        0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x01, 0x01, 0x47, 0x00, 0x12,
    ];
    expected.extend_from_slice(b"attributes-charset");
    expected.extend_from_slice(&[0x00, 0x05]);
    expected.extend_from_slice(b"utf-8");
    expected.push(0x03);
    assert_eq!(message.encode(), expected);
}

#[test]
fn every_value_type_round_trips() {
    let message = single(vec![
        Attribute::new("i", vec![Value::Integer(-5), Value::Integer(70000)]),
        Attribute::new("b", vec![Value::Bool(true), Value::Bool(false)]),
        Attribute::one("e", Value::Enum(4)),
        Attribute::one("o", Value::Octets(vec![0, 1, 2, 255])),
        Attribute::one(
            "d",
            Value::DateTime(vec![0x07, 0xEA, 11, 3, 10, 20, 30, 4, b'+', 1, 0]),
        ),
        Attribute::one(
            "r",
            Value::Resolution {
                x: 600,
                y: 300,
                units: 3,
            },
        ),
        Attribute::one("g", Value::Range(1, 999)),
        Attribute::one("t", Value::Text("Grüße 日本".into())),
        Attribute::one("n", Value::Name("job".into())),
        Attribute::keywords("k", &["one-sided", "two-sided-long-edge"]),
        Attribute::one("u", Value::Uri("ipp://printer.local:631/ipp/print".into())),
        Attribute::one("s", Value::UriScheme("ipp".into())),
        Attribute::one("c", Value::Charset("utf-8".into())),
        Attribute::one("l", Value::Language("en".into())),
        Attribute::one("m", Value::MimeType("application/pdf".into())),
        Attribute::one("x", Value::OutOfBand(tag::UNSUPPORTED)),
        Attribute::one("y", Value::OutOfBand(tag::UNKNOWN)),
        Attribute::one("z", Value::OutOfBand(tag::NO_VALUE)),
    ]);
    assert_eq!(roundtrip(&message), message);
}

fn size(x: i32, y: i32) -> Value {
    Value::Collection(vec![int("x-dimension", x), int("y-dimension", y)])
}

#[test]
fn collections_keep_members_nesting_and_additional_values() {
    let first = Value::Collection(vec![
        Attribute::one("media-size", size(21000, 29700)),
        Attribute::keywords("media-type", &["stationery", "labels"]),
    ]);
    let second = Value::Collection(vec![int("media-top-margin", 0)]);
    let message = single(vec![
        Attribute::new("media-col-database", vec![first, second]),
        int("after", 1),
    ]);
    assert_eq!(roundtrip(&message), message);
}

#[test]
fn a_collection_has_member_names_and_end_collection_as_rfc_8010() {
    let collection = Value::Collection(vec![int("x-dimension", 5)]);
    let bytes = single(vec![Attribute::one("c", collection)]).encode();
    let mut body = vec![
        0x34, 0x00, 0x01, b'c', 0x00, 0x00, 0x4A, 0x00, 0x00, 0x00, 0x0B,
    ];
    body.extend_from_slice(b"x-dimension");
    body.extend_from_slice(&[0x21, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05]);
    body.extend_from_slice(&[0x37, 0x00, 0x00, 0x00, 0x00]);
    assert_eq!(&bytes[9..bytes.len() - 1], body);
}

#[test]
fn unknown_tags_and_odd_lengths_are_kept_as_they_came() {
    let unknown = |tag, value: &[u8]| Value::Unknown {
        tag,
        value: value.to_vec(),
    };
    let message = single(vec![
        Attribute::one("a", unknown(0x7F, &[1, 2, 3])),
        Attribute::one("b", unknown(tag::INTEGER, &[1, 2, 3])),
        Attribute::one("c", unknown(0x15, &[])),
        Attribute::one("d", unknown(tag::BOOLEAN, &[])),
    ]);
    assert_eq!(roundtrip(&message), message);
}

#[test]
fn any_delimiter_group_is_kept() {
    let message = Message {
        version: Version::V11,
        code: 0x0402,
        request_id: 99,
        groups: vec![
            Group {
                tag: tag::OPERATION_ATTRIBUTES,
                attributes: vec![int("a", 1)],
            },
            Group {
                tag: 0x07,
                attributes: vec![int("b", 2)],
            },
            Group {
                tag: tag::UNSUPPORTED_ATTRIBUTES,
                attributes: vec![Attribute::one("c", Value::OutOfBand(tag::UNSUPPORTED))],
            },
            Group {
                tag: tag::JOB_ATTRIBUTES,
                attributes: vec![],
            },
        ],
    };
    assert_eq!(roundtrip(&message), message);
}

#[test]
fn text_and_name_with_language_drop_the_language() {
    let mut data = vec![0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04];
    data.extend_from_slice(&[
        0x35, 0x00, 0x01, b't', 0x00, 0x09, 0x00, 0x02, b'e', b'n', 0x00, 0x03,
    ]);
    data.extend_from_slice(b"abc");
    data.extend_from_slice(&[
        0x36, 0x00, 0x01, b'n', 0x00, 0x09, 0x00, 0x02, b'd', b'e', 0x00, 0x03,
    ]);
    data.extend_from_slice(b"xyz");
    data.extend_from_slice(&[0x03, 0xAA, 0xBB]);
    let (message, offset) = Message::decode(&data).unwrap();
    assert_eq!(message.first("t"), Some(&Value::Text("abc".into())));
    assert_eq!(message.first("n"), Some(&Value::Name("xyz".into())));
    assert_eq!(offset, data.len() - 2);
    assert_eq!(message.version, Version { major: 1, minor: 1 });
}

#[test]
fn a_request_followed_by_a_document_gives_the_document_offset() {
    let message = single(vec![int("a", 1)]);
    let mut bytes = message.encode();
    bytes.extend_from_slice(b"%PDF-1.7");
    let (decoded, offset) = Message::decode(&bytes).unwrap();
    assert_eq!(decoded, message);
    assert_eq!(&bytes[offset..], b"%PDF-1.7");
}

#[test]
fn every_cut_of_a_fixture_is_a_bad_message() {
    let data = printer("epson-ecotank");
    for length in 0..data.len() {
        assert!(Message::decode(&data[..length]).is_err(), "cut at {length}");
    }
}

#[test]
fn not_ipp_is_a_bad_message() {
    assert!(Message::decode(b"HTTP/1.1 200 OK\r\n\r\n").is_err());
    assert!(Message::decode(&[0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03]).is_err());
}

#[test]
fn a_value_without_a_name_is_bad_when_nothing_precedes_it() {
    let data = [
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x21, 0x00, 0x00, 0x00, 0x04, 0, 0,
        0, 1, 0x03,
    ];
    assert!(Message::decode(&data).is_err());
}

fn nested(levels: usize) -> Value {
    let mut value = Value::Collection(vec![int("x", 1)]);
    for _ in 1..levels {
        value = Value::Collection(vec![Attribute::one("c", value)]);
    }
    value
}

#[test]
fn collections_nested_sixteen_deep_are_kept() {
    let message = single(vec![Attribute::one("c", nested(16))]);
    assert_eq!(roundtrip(&message), message);
}

#[test]
fn collections_nested_past_the_limit_are_a_bad_message() {
    let bytes = single(vec![Attribute::one("c", nested(17))]).encode();
    assert!(Message::decode(&bytes).is_err());
}

#[test]
fn an_endless_nest_is_refused_without_overflowing_the_stack() {
    let mut data = vec![0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04];
    data.extend_from_slice(&[0x34, 0x00, 0x01, b'c', 0x00, 0x00]);
    for _ in 0..100_000 {
        data.extend_from_slice(&[0x34, 0x00, 0x00, 0x00, 0x00]);
    }
    assert!(Message::decode(&data).is_err());
}

#[test]
fn a_get_jobs_answer_with_hundreds_of_job_groups_decodes() {
    let mut groups = vec![Group {
        tag: tag::OPERATION_ATTRIBUTES,
        attributes: vec![int("status", 0)],
    }];
    for id in 0..400 {
        groups.push(Group {
            tag: tag::JOB_ATTRIBUTES,
            attributes: vec![int("job-id", id)],
        });
    }
    let message = Message {
        version: Version::V20,
        code: 0,
        request_id: 1,
        groups,
    };
    assert_eq!(roundtrip(&message), message);
}

#[test]
fn a_flood_of_empty_groups_is_refused() {
    let mut data = vec![0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01];
    data.extend(std::iter::repeat_n(0x04, 100_001));
    data.push(0x03);
    assert!(Message::decode(&data).is_err());
}

#[test]
fn a_value_longer_than_the_wire_allows_is_cut_and_the_rest_keeps_its_framing() {
    let message = single(vec![
        Attribute::one("long", Value::Keyword("k".repeat(90_000))),
        int("after", 5),
    ]);
    let decoded = roundtrip(&message);
    let attributes = &decoded.groups[0].attributes;
    assert_eq!(attributes[0].values[0], Value::Keyword("k".repeat(65_535)));
    assert_eq!(attributes[1], int("after", 5));
}

#[test]
fn a_flood_of_tiny_values_is_refused() {
    let mut data = vec![0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04];
    data.extend_from_slice(&[0x21, 0x00, 0x01, b'a', 0x00, 0x04, 0, 0, 0, 0]);
    for _ in 0..200_001 {
        data.extend_from_slice(&[0x21, 0x00, 0x00, 0x00, 0x04, 0, 0, 0, 0]);
    }
    data.push(0x03);
    assert!(Message::decode(&data).is_err());
}

#[test]
fn success_is_a_code_below_0x0100() {
    let with = |code| Message {
        version: Version::V20,
        code,
        request_id: 1,
        groups: vec![],
    };
    for code in [0x0000, 0x0001, 0x0002] {
        assert!(with(code).is_success());
    }
    for code in [0x0400, 0x0507] {
        assert!(!with(code).is_success());
    }
}

#[test]
fn lookup_finds_the_first_attribute_outside_the_unsupported_group() {
    let message = Message {
        version: Version::V20,
        code: 0x040B,
        request_id: 1,
        groups: vec![
            Group {
                tag: tag::OPERATION_ATTRIBUTES,
                attributes: vec![int("x", 1)],
            },
            Group {
                tag: tag::UNSUPPORTED_ATTRIBUTES,
                attributes: vec![
                    int("copies", 9),
                    Attribute::one("sides", Value::OutOfBand(tag::UNSUPPORTED)),
                ],
            },
            Group {
                tag: tag::JOB_ATTRIBUTES,
                attributes: vec![int("copies", 2), int("copies", 3)],
            },
        ],
    };
    assert_eq!(message.first("copies"), Some(&Value::Integer(2)));
    assert!(message.get("sides").is_none());
    assert!(message.get("missing").is_none());
}

#[test]
fn every_printer_fixture_reads_to_the_end_and_encodes_back() {
    for name in PRINTERS {
        let data = printer(name);
        let (message, offset) = Message::decode(&data).unwrap();
        assert!(message.is_success(), "{name}");
        assert_eq!(offset, data.len(), "{name}");
        assert_eq!(
            Message::decode(&message.encode()).unwrap().0,
            message,
            "{name}"
        );
        // The fixtures come from a separate Python encoder. Brother's has values with a language, which the codec drops.
        if name != "brother-laser" {
            assert_eq!(message.encode(), data, "{name}");
        }
    }
}

// A quick stand-in for the fuzz target on every test run: flipped, cut and filled bytes of the
// fixtures must be refused or read, never panic, and what is read writes back to the same message.
#[test]
fn mutated_fixtures_never_panic() {
    let mut seed = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    for name in PRINTERS {
        let original = printer(name);
        for _ in 0..300 {
            let mut data = original.clone();
            for _ in 0..(next() % 6 + 1) {
                let at = (next() % data.len() as u64) as usize;
                data[at] = next() as u8;
            }
            if next() % 3 == 0 {
                data.truncate((next() % data.len() as u64) as usize);
            }
            if let Ok((message, _)) = Message::decode(&data) {
                assert_eq!(Message::decode(&message.encode()).unwrap().0, message);
            }
        }
    }
}
