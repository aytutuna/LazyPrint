//! Network printers as discovery reports them, merged into one endpoint per printer with the
//! addresses to try in order.
//! Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

use crate::address::{PrinterAddress, lacks_zone};
use crate::txt::{TxtRecord, uuid_key};

/// One DNS-SD service instance of a network printer: _ipp._tcp (`secure` false) or _ipps._tcp.
#[derive(Clone, Debug)]
pub struct Service {
    /// e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".
    pub instance_name: String,
    pub secure: bool,
    /// e.g. "HPA1B2C3.local"; none when not reported.
    pub host_name: Option<String>,
    /// IP addresses as text; an IPv6 one may carry its zone ("fe80::1%12"). An address whose
    /// zone names no interface here is skipped.
    pub addresses: Vec<String>,
    pub port: u32,
    /// TXT record entries ("key=value").
    pub text_attributes: Vec<String>,
}

/// A discovered printer: its _ipp and _ipps services merged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// "uuid:" and the TXT UUID's key, or "name:" and the lowercase instance name without a UUID.
    pub key: String,
    /// The model from the TXT record, else the service instance name.
    pub name: String,
    /// The TXT record of the first service (the secure one when both are advertised).
    pub txt: TxtRecord,
    /// Where to connect, best first: every ipps address before every ipp one, and within each,
    /// IPv4 addresses, then the host name, then IPv6 addresses.
    pub addresses: Vec<PrinterAddress>,
    /// The instance names it was advertised under, without repeats.
    pub instance_names: Vec<String>,
}

impl Endpoint {
    /// The endpoint with `address` tried first; as it is when the address is not one of its own.
    /// A plain ipp address never goes ahead of an ipps one: the ipps address of the same host goes
    /// first instead, and the order stays when there is none.
    pub fn preferring(&self, address: &PrinterAddress) -> Endpoint {
        let mut address = address.clone();
        if !address.secure && self.addresses.iter().any(|a| a.secure) {
            address = self
                .addresses
                .iter()
                .find(|a| a.secure && a.host == address.host)
                .unwrap_or(&self.addresses[0])
                .clone();
        }
        if self.addresses.first() == Some(&address) || !self.addresses.contains(&address) {
            return self.clone();
        }
        let rest = self.addresses.iter().filter(|a| **a != address).cloned();
        Endpoint {
            addresses: std::iter::once(address.clone()).chain(rest).collect(),
            ..self.clone()
        }
    }

    pub fn uuid(&self) -> Option<&str> {
        self.txt.uuid.as_deref()
    }
}

struct Entry<'a> {
    service: &'a Service,
    txt: TxtRecord,
}

/// Groups services by printer (TXT UUID; services without one by instance name, which the _ipp
/// and _ipps instances of one printer share) and orders each printer's addresses: ipps first (a
/// failed TLS handshake falls back to the ipp ones), IPv4 before the .local host name (which needs
/// another lookup), IPv6 last. IPv6 link-local addresses without a zone cannot be connected to and
/// are skipped. Printers keep the order their first service was listed in; printers left without
/// an address are dropped.
pub fn choose(services: &[Service]) -> Vec<Endpoint> {
    let entries: Vec<Entry> = services
        .iter()
        .filter(|s| (1..=65535).contains(&s.port))
        .map(|service| Entry {
            service,
            txt: TxtRecord::parse(&service.text_attributes),
        })
        .collect();

    let mut uuid_by_instance: Vec<(String, String)> = vec![];
    for entry in &entries {
        let instance = entry.service.instance_name.to_lowercase();
        if let Some(uuid) = uuid_key(entry.txt.uuid.as_deref())
            && !uuid_by_instance.iter().any(|(i, _)| *i == instance)
        {
            uuid_by_instance.push((instance, uuid));
        }
    }

    let mut groups: Vec<(String, Vec<&Entry>)> = vec![];
    for entry in &entries {
        let instance = entry.service.instance_name.to_lowercase();
        let key = match uuid_key(entry.txt.uuid.as_deref()) {
            Some(uuid) => format!("uuid:{uuid}"),
            None => match uuid_by_instance.iter().find(|(i, _)| *i == instance) {
                Some((_, shared)) => format!("uuid:{shared}"),
                None => format!("name:{instance}"),
            },
        };
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, members)) => members.push(entry),
            None => groups.push((key, vec![entry])),
        }
    }

    let mut endpoints = vec![];
    for (key, group) in groups {
        let ordered: Vec<&Entry> = group
            .iter()
            .filter(|e| e.service.secure)
            .chain(group.iter().filter(|e| !e.service.secure))
            .copied()
            .collect();
        let mut addresses: Vec<PrinterAddress> = vec![];
        for member in &ordered {
            for host in hosts(member.service) {
                let Some(address) = PrinterAddress::create(
                    member.service.secure,
                    &host,
                    member.service.port as u16,
                    &member.txt.resource_path,
                ) else {
                    continue;
                };
                if !addresses.contains(&address) {
                    addresses.push(address);
                }
            }
        }
        if addresses.is_empty() {
            continue;
        }
        let first = ordered[0];
        let name = ordered
            .iter()
            .find_map(|e| e.txt.model.clone())
            .unwrap_or_else(|| first.service.instance_name.clone());
        let mut instance_names: Vec<String> = vec![];
        for member in &ordered {
            let instance = &member.service.instance_name;
            if !instance_names
                .iter()
                .any(|n| n.to_lowercase() == instance.to_lowercase())
            {
                instance_names.push(instance.clone());
            }
        }
        endpoints.push(Endpoint {
            key,
            name,
            txt: first.txt.clone(),
            addresses,
            instance_names,
        });
    }
    endpoints
}

// One service's hosts to try: IPv4 addresses, the host name, then usable IPv6 addresses.
fn hosts(service: &Service) -> Vec<String> {
    let mut v4 = vec![];
    let mut v6 = vec![];
    for text in &service.addresses {
        let text = text.trim();
        if text.contains(':') {
            if let Some(address) = PrinterAddress::create(false, text, 1, "")
                && !lacks_zone(&address.host)
            {
                v6.push(address.host);
            }
        } else if text.bytes().all(|b| b.is_ascii_digit() || b == b'.')
            && let Some(address) = PrinterAddress::create(false, text, 1, "")
        {
            v4.push(address.host);
        }
    }
    let mut hosts = v4;
    if let Some(name) = service.host_name.as_deref().map(str::trim)
        && !name.is_empty()
    {
        hosts.push(name.to_string());
    }
    hosts.extend(v6);
    hosts
}
