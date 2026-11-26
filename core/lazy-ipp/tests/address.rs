//! The address cases of the C# and Swift IppDiscoveryTests.

use lazy_ipp::address::{AddressError, PrinterAddress};

#[test]
fn addresses_parse_and_normalize() {
    // text, secure, host, port, path, canonical, printer-uri, request url
    let cases = [
        (
            "192.168.1.50",
            false,
            "192.168.1.50",
            631,
            "ipp/print",
            "192.168.1.50",
            "ipp://192.168.1.50:631/ipp/print",
            "http://192.168.1.50:631/ipp/print",
        ),
        (
            " 192.168.001.050 ",
            false,
            "192.168.1.50",
            631,
            "ipp/print",
            "192.168.1.50",
            "ipp://192.168.1.50:631/ipp/print",
            "http://192.168.1.50:631/ipp/print",
        ),
        (
            "Printer.Local",
            false,
            "printer.local",
            631,
            "ipp/print",
            "printer.local",
            "ipp://printer.local:631/ipp/print",
            "http://printer.local:631/ipp/print",
        ),
        (
            "epson.local:8631",
            false,
            "epson.local",
            8631,
            "ipp/print",
            "epson.local:8631",
            "ipp://epson.local:8631/ipp/print",
            "http://epson.local:8631/ipp/print",
        ),
        (
            "ipp://192.168.1.50",
            false,
            "192.168.1.50",
            631,
            "ipp/print",
            "192.168.1.50",
            "ipp://192.168.1.50:631/ipp/print",
            "http://192.168.1.50:631/ipp/print",
        ),
        (
            "ipps://10.0.0.7",
            true,
            "10.0.0.7",
            631,
            "ipp/print",
            "ipps://10.0.0.7",
            "ipps://10.0.0.7:631/ipp/print",
            "https://10.0.0.7:631/ipp/print",
        ),
        (
            "ipps://10.0.0.7:8443/ipp/print/",
            true,
            "10.0.0.7",
            8443,
            "ipp/print",
            "ipps://10.0.0.7:8443",
            "ipps://10.0.0.7:8443/ipp/print",
            "https://10.0.0.7:8443/ipp/print",
        ),
        (
            "ipp://host:8631/printers/Office",
            false,
            "host",
            8631,
            "printers/Office",
            "ipp://host:8631/printers/Office",
            "ipp://host:8631/printers/Office",
            "http://host:8631/printers/Office",
        ),
        (
            "http://10.0.0.7",
            false,
            "10.0.0.7",
            80,
            "ipp/print",
            "10.0.0.7:80",
            "ipp://10.0.0.7:80/ipp/print",
            "http://10.0.0.7/ipp/print",
        ),
        (
            "https://10.0.0.7",
            true,
            "10.0.0.7",
            443,
            "ipp/print",
            "ipps://10.0.0.7:443",
            "ipps://10.0.0.7:443/ipp/print",
            "https://10.0.0.7/ipp/print",
        ),
        (
            "http://host:9090/printers/a%20b",
            false,
            "host",
            9090,
            "printers/a b",
            "ipp://host:9090/printers/a%20b",
            "ipp://host:9090/printers/a%20b",
            "http://host:9090/printers/a%20b",
        ),
        (
            "10.0.0.7/ipp/print",
            false,
            "10.0.0.7",
            631,
            "ipp/print",
            "10.0.0.7",
            "ipp://10.0.0.7:631/ipp/print",
            "http://10.0.0.7:631/ipp/print",
        ),
        (
            "[fe80::1%12]:8631",
            false,
            "fe80::1%12",
            8631,
            "ipp/print",
            "[fe80::1%12]:8631",
            "ipp://[fe80::1]:8631/ipp/print",
            "http://[fe80::1%12]:8631/ipp/print",
        ),
        (
            "2001:DB8::5",
            false,
            "2001:db8::5",
            631,
            "ipp/print",
            "[2001:db8::5]",
            "ipp://[2001:db8::5]:631/ipp/print",
            "http://[2001:db8::5]:631/ipp/print",
        ),
        (
            "[2001:db8::5]",
            false,
            "2001:db8::5",
            631,
            "ipp/print",
            "[2001:db8::5]",
            "ipp://[2001:db8::5]:631/ipp/print",
            "http://[2001:db8::5]:631/ipp/print",
        ),
        (
            "ipps://[2001:db8::5]",
            true,
            "2001:db8::5",
            631,
            "ipp/print",
            "ipps://[2001:db8::5]",
            "ipps://[2001:db8::5]:631/ipp/print",
            "https://[2001:db8::5]:631/ipp/print",
        ),
        (
            "https://[2001:db8::5]:9443",
            true,
            "2001:db8::5",
            9443,
            "ipp/print",
            "ipps://[2001:db8::5]:9443",
            "ipps://[2001:db8::5]:9443/ipp/print",
            "https://[2001:db8::5]:9443/ipp/print",
        ),
    ];
    for (text, secure, host, port, path, canonical, printer_uri, request_url) in cases {
        let address = PrinterAddress::parse(text).unwrap_or_else(|e| panic!("{text}: {e}"));
        assert_eq!(address.secure, secure, "{text}");
        assert_eq!(address.host, host, "{text}");
        assert_eq!(address.port, port, "{text}");
        assert_eq!(address.resource_path, path, "{text}");
        assert_eq!(address.to_string(), canonical, "{text}");
        assert_eq!(address.printer_uri(), printer_uri, "{text}");
        assert_eq!(address.request_url(), request_url, "{text}");
        // The canonical text reads back as the same address.
        assert_eq!(PrinterAddress::parse(canonical).unwrap(), address, "{text}");
    }
}

#[test]
fn zoned_ipv6_addresses_stay_usable() {
    let address = PrinterAddress::parse("[fe80::1%12]:8631").unwrap();
    assert_eq!(address.authority(), "[fe80::1%12]:8631");
    assert_eq!(address.host, "fe80::1%12");
}

#[test]
fn a_zone_of_zero_or_none_is_no_zone_and_a_named_one_is_refused() {
    assert_eq!(
        PrinterAddress::parse("[2001:db8::1%0]").unwrap().host,
        "2001:db8::1"
    );
    assert_eq!(
        PrinterAddress::parse("[2001:db8::1%]").unwrap().host,
        "2001:db8::1"
    );
    assert!(PrinterAddress::parse("[fe80::1%nosuch0]").is_err());
}

#[test]
fn bad_addresses_say_what_is_wrong() {
    use AddressError::*;
    for (text, error) in [
        ("", Empty),
        ("   ", Empty),
        ("192.168.1", BadHost),
        ("300.1.1.1", BadHost),
        ("printer:0", BadPort),
        ("printer:70000", BadPort),
        ("printer:ipp", BadPort),
        ("my printer", HasSpaces),
        ("ftp://10.0.0.7", BadScheme),
        ("socket://10.0.0.7:9100", BadScheme),
        ("ipp://user:pw@10.0.0.7", UserInfo),
        ("[fe80::1", MissingBracket),
        ("[fe80::1]x", NotAnAddress),
        ("bad_host!", BadHost),
        ("[fe80::1%nosuch0]", BadHost),
        ("fe80::1%99999999999", BadHost),
        ("ipp://[fe80::1%nosuch0]:8631", NotAnAddress),
        ("fe80::1a2b:3c4d:5e6f:7a8b", NeedsZone),
        ("[fe80::1%0]:8631", NeedsZone),
        ("ipp://[fe80::1]", NeedsZone),
    ] {
        assert_eq!(PrinterAddress::parse(text).unwrap_err(), error, "{text}");
    }
}

#[test]
fn addresses_compare_by_their_canonical_form() {
    let parse = |t: &str| PrinterAddress::parse(t).unwrap();
    assert_eq!(
        parse("ipp://PRINTER.local:631/ipp/print"),
        parse("printer.local")
    );
    assert_ne!(parse("ipps://printer.local"), parse("printer.local"));
    assert_ne!(parse("printer.local:8631"), parse("printer.local"));
    assert_ne!(parse("printer.local/printers/a"), parse("printer.local"));
    assert!(PrinterAddress::create(false, "host", 0, "ipp/print").is_none());
    assert!(PrinterAddress::create(false, "not a host", 631, "ipp/print").is_none());
    assert_eq!(
        PrinterAddress::create(false, "host", 631, "")
            .unwrap()
            .printer_uri(),
        "ipp://host:631/"
    );
}

#[test]
fn a_bare_host_that_did_not_answer_is_tried_over_ipps() {
    let parse = |t: &str| PrinterAddress::parse(t).unwrap();
    let plain = parse("192.168.1.50");
    assert_eq!(
        plain.https_fallback("192.168.1.50").unwrap().to_string(),
        "ipps://192.168.1.50"
    );
    assert!(plain.https_fallback("ipp://192.168.1.50").is_none());
    assert!(plain.https_fallback("192.168.1.50/ipp/print").is_none());
    assert!(
        parse("192.168.1.50:8631")
            .https_fallback("192.168.1.50:8631")
            .is_none()
    );
    assert!(
        parse("ipps://192.168.1.50")
            .https_fallback("ipps://192.168.1.50")
            .is_none()
    );
    assert!(
        parse("192.168.1.50/printers/a")
            .https_fallback("192.168.1.50")
            .is_none()
    );
}
