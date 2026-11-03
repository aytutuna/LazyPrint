import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppEndpoint.cs: the same grouping and address order.

/// One DNS-SD service instance of a network printer, as the operating system reports it: _ipp._tcp
/// (`secure` false) or _ipps._tcp (true).
public struct IppService: Equatable, Sendable {
    /// The system's id for the service instance.
    public var id: String
    /// e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".
    public var instanceName: String
    public var secure: Bool
    /// e.g. "HPA1B2C3.local"; nil when not reported.
    public var hostName: String?
    /// IP addresses as text, e.g. "192.168.1.20", "fe80::1%12" or "fe80::1%en0" (the zone as an
    /// interface index or name; an address whose zone names no interface here is skipped).
    public var addresses: [String]
    public var port: Int
    /// TXT record entries ("key=value").
    public var textAttributes: [String]

    public init(id: String, instanceName: String, secure: Bool, hostName: String?, addresses: [String], port: Int,
                textAttributes: [String]) {
        self.id = id
        self.instanceName = instanceName
        self.secure = secure
        self.hostName = hostName
        self.addresses = addresses
        self.port = port
        self.textAttributes = textAttributes
    }
}

/// A discovered network printer: its _ipp and _ipps services merged, with the addresses to connect
/// through in the order to try them.
public struct IppEndpoint: Equatable, Sendable {
    /// "uuid:" + `IppTxtRecord.uuidKey`, or "name:" + the instance name (lowercase) without a UUID.
    public var key: String
    /// The model from the TXT record, else the service instance name.
    public var name: String
    /// The TXT record of the first service (the secure one when both are advertised).
    public var txt: IppTxtRecord
    /// Where to connect, best first: every ipps address before every ipp one, and within each, IPv4
    /// addresses, then the host name, then IPv6 addresses.
    public var addresses: [PrinterAddress]
    /// The service instance names it was advertised under, e.g. "HP LaserJet Pro M404dn (A1B2C3)", without repeats.
    public var instanceNames: [String]

    public init(key: String, name: String, txt: IppTxtRecord, addresses: [PrinterAddress], instanceNames: [String] = []) {
        self.key = key
        self.name = name
        self.txt = txt
        self.addresses = addresses
        self.instanceNames = instanceNames
    }

    /// The printer UUID from the TXT record, as advertised; nil when there is none.
    public var uuid: String? { txt.uuid }

    /// One service with its TXT record read.
    private struct Entry {
        let service: IppService
        let txt: IppTxtRecord
    }

    /// Groups services by printer (TXT UUID; services without one by instance name, which the _ipp
    /// and _ipps instances of one printer share) and orders each printer's addresses: ipps first (a
    /// failed TLS handshake falls back to the ipp ones), IPv4 before the .local host name (which needs
    /// another lookup), IPv6 last. IPv6 link-local addresses without a zone (%interface) cannot be
    /// connected to and are skipped. Printers keep the order their first service was listed in;
    /// printers left without an address are dropped.
    public static func choose(_ services: [IppService]) -> [IppEndpoint] {
        let entries = services.filter { $0.port >= 1 && $0.port <= 65535 }
            .map { Entry(service: $0, txt: IppTxtRecord.parse($0.textAttributes)) }
        // Instance names are compared ignoring case.
        var uuidByInstance: [String: String] = [:]
        for entry in entries {
            let instance = entry.service.instanceName.lowercased()
            if let uuid = IppTxtRecord.uuidKey(entry.txt.uuid), uuidByInstance[instance] == nil {
                uuidByInstance[instance] = uuid
            }
        }

        var keys: [String] = []
        var members: [String: [Entry]] = [:]
        for entry in entries {
            let instance = entry.service.instanceName.lowercased()
            let key: String
            if let uuid = IppTxtRecord.uuidKey(entry.txt.uuid) {
                key = "uuid:" + uuid
            } else if let shared = uuidByInstance[instance] {
                key = "uuid:" + shared
            } else {
                key = "name:" + instance
            }
            if members[key] == nil {
                keys.append(key)
            }
            members[key, default: []].append(entry)
        }

        var endpoints: [IppEndpoint] = []
        for key in keys {
            let group = members[key] ?? []
            // Secure first, otherwise in the order listed.
            let ordered = group.filter { $0.service.secure } + group.filter { !$0.service.secure }
            var addresses: [PrinterAddress] = []
            for member in ordered {
                for host in hosts(member.service) {
                    guard let address = PrinterAddress.create(secure: member.service.secure, host: host,
                                                              port: member.service.port,
                                                              resourcePath: member.txt.resourcePath) else { continue }
                    if !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
            }
            if addresses.isEmpty {
                continue
            }
            let first = ordered[0]
            let name = ordered.compactMap { $0.txt.model }.first ?? first.service.instanceName
            var instanceNames: [String] = []
            for member in ordered where !instanceNames.contains(where: { $0.lowercased() == member.service.instanceName.lowercased() }) {
                instanceNames.append(member.service.instanceName)
            }
            endpoints.append(IppEndpoint(key: key, name: name, txt: first.txt, addresses: addresses, instanceNames: instanceNames))
        }
        return endpoints
    }

    /// One service's hosts to try: IPv4 addresses, the host name, then usable IPv6 addresses.
    private static func hosts(_ service: IppService) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        for text in service.addresses {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains(":") {
                guard let ip = IppHostText.ipv6(trimmed), !(ip.isLinkLocal && ip.zone == 0) else { continue }
                v6.append(ip.text)
            } else if let ip = IppHostText.ipv4(trimmed) {
                v4.append(ip)
            }
        }
        var hosts = v4
        if let hostName = service.hostName?.trimmingCharacters(in: .whitespacesAndNewlines), !hostName.isEmpty {
            hosts.append(hostName)
        }
        return hosts + v6
    }
}
