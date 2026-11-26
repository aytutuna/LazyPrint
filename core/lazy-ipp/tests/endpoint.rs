//! The endpoint cases of the C# and Swift IppDiscoveryTests.

mod common;

use common::fixture;
use lazy_ipp::address::PrinterAddress;
use lazy_ipp::endpoint::{Service, choose};

fn hp_txt() -> Vec<String> {
    let text = String::from_utf8(fixture("txt-hp.txt")).unwrap();
    text.lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

fn service(instance: &str, secure: bool, addresses: &[&str], txt: Vec<String>) -> Service {
    Service {
        instance_name: instance.into(),
        secure,
        host_name: Some("HPA1B2C3.local".into()),
        addresses: addresses.iter().map(|a| a.to_string()).collect(),
        port: 631,
        text_attributes: txt,
    }
}

fn txt(entries: &[&str]) -> Vec<String> {
    entries.iter().map(|e| e.to_string()).collect()
}

fn shown(addresses: &[PrinterAddress]) -> Vec<String> {
    addresses.iter().map(|a| a.to_string()).collect()
}

#[test]
fn both_services_of_one_printer_merge_ipps_first() {
    let hp = hp_txt();
    let endpoints = choose(&[
        service(
            "HP M479 (A1B2C3)",
            false,
            &["fe80::1", "192.168.1.20", "2001:db8::20"],
            hp.clone(),
        ),
        service("HP M479 (A1B2C3)", true, &["192.168.1.20"], hp),
    ]);
    assert_eq!(endpoints.len(), 1);
    let endpoint = &endpoints[0];
    assert_eq!(endpoint.key, "uuid:564e4333423035383930a0b3cce51a2b");
    assert_eq!(endpoint.name, "HP Color LaserJet MFP M479fdw");
    assert_eq!(
        endpoint.uuid(),
        Some("564e4333-4230-3538-3930-a0b3cce51a2b")
    );
    assert_eq!(endpoint.instance_names, ["HP M479 (A1B2C3)"]);
    // ipps first; IPv4, then the host name, then IPv6; link-local without a zone skipped.
    assert_eq!(
        shown(&endpoint.addresses),
        [
            "ipps://192.168.1.20",
            "ipps://hpa1b2c3.local",
            "192.168.1.20",
            "hpa1b2c3.local",
            "[2001:db8::20]",
        ]
    );
}

#[test]
fn an_endpoint_can_try_one_of_its_addresses_first() {
    let endpoint = choose(&[service(
        "HP M479 (A1B2C3)",
        false,
        &["192.168.1.20", "192.168.1.21"],
        hp_txt(),
    )])
    .remove(0);
    let second = endpoint.addresses[1].clone();
    let preferred = endpoint.preferring(&second);
    assert_eq!(preferred.addresses[0], second);
    assert_eq!(preferred.addresses.len(), endpoint.addresses.len());
    assert_eq!(endpoint.preferring(&endpoint.addresses[0]), endpoint);
    let other = PrinterAddress::parse("192.168.1.99").unwrap();
    assert_eq!(endpoint.preferring(&other), endpoint);
}

#[test]
fn a_plain_address_never_goes_ahead_of_a_secure_one() {
    let hp = hp_txt();
    let endpoint = choose(&[
        service("HP M479 (A1B2C3)", true, &["192.168.1.20"], hp.clone()),
        service("HP M479 (A1B2C3)", false, &["192.168.1.20"], hp),
    ])
    .remove(0);
    let plain = endpoint
        .addresses
        .iter()
        .find(|a| !a.secure && a.host == "192.168.1.20")
        .unwrap();
    assert_eq!(endpoint.preferring(plain), endpoint);
    assert!(endpoint.preferring(plain).addresses[0].secure);
}

#[test]
fn endpoints_keep_the_resource_path_port_and_zoned_addresses() {
    let mut canon = service(
        "Canon",
        false,
        &["fe80::5%7"],
        txt(&["rp=/printers/Canon", "ty=Canon MF743C"]),
    );
    canon.port = 8631;
    canon.host_name = None;
    let endpoints = choose(&[canon]);
    assert_eq!(endpoints.len(), 1);
    let endpoint = &endpoints[0];
    assert_eq!(endpoint.key, "name:canon");
    assert_eq!(endpoint.uuid(), None);
    assert_eq!(endpoint.addresses.len(), 1);
    let address = &endpoint.addresses[0];
    assert_eq!(address.printer_uri(), "ipp://[fe80::5]:8631/printers/Canon");
    assert_eq!(address.host, "fe80::5%7");
}

#[test]
fn addresses_whose_zone_names_no_interface_are_skipped() {
    let mut canon = service(
        "Canon",
        false,
        &["fe80::5%nosuch0", "2001:db8::9%nosuch0", "2001:db8::6%3"],
        txt(&["ty=Canon MF743C"]),
    );
    canon.host_name = None;
    let endpoints = choose(&[canon]);
    assert_eq!(shown(&endpoints[0].addresses), ["[2001:db8::6%3]"]);
}

#[test]
fn printers_stay_apart_and_unusable_services_are_dropped() {
    let other = txt(&[
        "ty=Epson ET-4850",
        "UUID=cfe92100-67c4-11d4-a45f-f8d0273e1a0b",
    ]);
    let mut broken = service("Broken port", false, &["192.168.1.40"], txt(&["ty=X"]));
    broken.port = 70000;
    let mut none = service("No address", false, &["fe80::9"], txt(&["ty=Y"]));
    none.host_name = None;
    let endpoints = choose(&[
        service("HP", false, &["192.168.1.20"], hp_txt()),
        service("Epson", false, &["192.168.1.30"], other),
        broken,
        none,
        // The _ipps service of the HP without a UUID of its own: the instance name ties it.
        service(
            "HP",
            true,
            &["192.168.1.20"],
            txt(&["ty=HP Color LaserJet MFP M479fdw"]),
        ),
    ]);
    let names: Vec<_> = endpoints.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["HP Color LaserJet MFP M479fdw", "Epson ET-4850"]);
    assert_eq!(endpoints[0].addresses[0].to_string(), "ipps://192.168.1.20");
    assert_eq!(endpoints[1].key, "uuid:cfe9210067c411d4a45ff8d0273e1a0b");
}

#[test]
fn without_a_model_the_instance_name_is_the_name() {
    let mut office = service("Office printer", false, &["10.0.0.9"], vec![]);
    office.host_name = None;
    let endpoints = choose(&[office]);
    assert_eq!(endpoints.len(), 1);
    assert_eq!(endpoints[0].name, "Office printer");
    assert_eq!(endpoints[0].txt.resource_path, "ipp/print");
}
