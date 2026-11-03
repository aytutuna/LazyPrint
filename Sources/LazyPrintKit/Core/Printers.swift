import Foundation

// Twin of windows/LazyPrint.Core/Core/Printers.cs (Lazy Scan's DeviceMerge, for printers): the printer list.

/// How a job goes to a printer: the system's queue, straight to IPP, or to the demo printer.
public enum PrinterRoute: String, Sendable {
    case system, ipp, demo
}

public enum PrinterState: String, Sendable {
    case unknown, idle, printing, stopped, offline
}

/// One ink or toner supply; `level` is a percent, nil when the printer does not say.
public struct Supply: Equatable, Sendable {
    public var name: String
    public var color: String?
    public var level: Int?
    public var isLow: Bool

    public init(name: String, color: String?, level: Int?, isLow: Bool) {
        self.name = name
        self.color = color
        self.level = level
        self.isLow = isLow
    }
}

/// What the system says about a queue, kept apart from what IPP says so a refresh can tell them apart.
public struct QueueStatus: Equatable, Sendable {
    public var state: PrinterState
    public var problems: [PrinterProblem]

    public init(state: PrinterState, problems: [PrinterProblem]) {
        self.state = state
        self.problems = problems
    }
}

/// One physical printer as the app lists it. `id` is stable across runs: "system:" and the queue's name, "ipp:" and the
/// printer's UUID for a network printer without a queue, "demo" for the demo printer. `address` is what the
/// troubleshooter and the test page show, `route` the system's queue when it has one, else IPP, `ippEndpoint` is also
/// set for a system printer matched to its IPP twin, for status and supplies, and `queue` holds the state and problems
/// of a system printer's queue; a refresh keeps them beside what IPP says.
public struct PrinterInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    public var address: String?
    public var route: PrinterRoute
    public var ippEndpoint: IppEndpoint?
    public var isDefault: Bool
    public var state: PrinterState
    public var problems: [PrinterProblem]
    public var supplies: [Supply]
    public var queue: QueueStatus?

    public init(id: String, name: String, model: String?, address: String?, route: PrinterRoute, ippEndpoint: IppEndpoint?,
                isDefault: Bool, state: PrinterState, problems: [PrinterProblem], supplies: [Supply],
                queue: QueueStatus? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.address = address
        self.route = route
        self.ippEndpoint = ippEndpoint
        self.isDefault = isDefault
        self.state = state
        self.problems = problems
        self.supplies = supplies
        self.queue = queue
    }
}

public enum PrinterMerge {
    public static let demoId = "demo"
    public static let demoName = "Demo Printer"

    /// One row per physical printer, whichever ways it is listed. A system queue and the IPP printer it points at are one
    /// row, found by UUID, else by a host or address in the queue's port or device URI (IP_ and WSD port names, ipp://,
    /// http:// and dnssd:// URIs), else by the service's instance name, else by name; it is routed through the queue and
    /// keeps the IPP endpoint for status. Each way is tried for all queues before the next, so a weak match never takes
    /// a printer from a queue that points at it. A name that fits more than one printer matches none, and a queue whose
    /// port names a host is not matched by name. The first queue that matches an endpoint keeps it; another queue for the
    /// same printer is a row of its own. Virtual queues (PDF, XPS, OneNote, fax) are left out. System queues come first,
    /// then the network printers no queue matched, then the demo printer.
    public static func merge(system: [SystemPrinter], network: [IppService], demo: Bool) -> [PrinterInfo] {
        var left = IppEndpoint.choose(network)
        let queues = system.filter { !isVirtual($0) }.map { (queue: $0, hints: portHints(of: $0)) }
        var twins = [IppEndpoint?](repeating: nil, count: queues.count)
        let ways = [byUuid, byHost, byInstance, byName]
        for way in ways {
            for (i, item) in queues.enumerated() where twins[i] == nil {
                if let found = way(item.queue, item.hints, left) {
                    twins[i] = found
                    left.removeAll { $0.key == found.key }
                }
            }
        }

        var rows = [PrinterInfo]()
        for (i, item) in queues.enumerated() {
            rows.append(row(for: item.queue, hints: item.hints, endpoint: twins[i]))
        }
        rows += left.map { row(for: $0) }
        if demo {
            rows.append(PrinterInfo(id: demoId, name: demoName, model: nil, address: nil, route: .demo, ippEndpoint: nil,
                                    isDefault: false, state: .idle, problems: [], supplies: []))
        }
        return rows
    }

    /// The printer's state, problems and supplies from what it just said; nil is a printer that did not answer.
    /// Supplies that hold waste (waste ink, waste toner) are left out: their level is how full they are. A printer with a
    /// queue keeps the queue's problems beside IPP's, and its offline or stopped state wins; one that does not answer IPP
    /// is as the queue says, since it may print through its port all the same.
    public static func refresh(_ printer: PrinterInfo, with capabilities: PrinterCapabilities?) -> PrinterInfo {
        var refreshed = printer
        let queue = printer.route == .system ? printer.queue : nil
        guard let capabilities else {
            if let queue {
                refreshed.state = queue.state
                refreshed.problems = queue.problems
            } else {
                refreshed.state = .offline
                refreshed.problems = IppProblems.describe(reasons: [], message: nil, reachable: false)
            }
            refreshed.supplies = []
            return refreshed
        }
        refreshed.state = capabilities.state == .processing ? .printing : capabilities.state == .stopped ? .stopped : .idle
        refreshed.problems = IppProblems.describe(reasons: capabilities.stateReasons, message: capabilities.stateMessage,
                                                  reachable: true)
        if let queue {
            if queue.state == .offline || queue.state == .stopped { refreshed.state = queue.state }
            let titles = queue.problems.map { $0.title }
            refreshed.problems = queue.problems + refreshed.problems.filter { !titles.contains($0.title) }
        }
        refreshed.supplies = capabilities.supplies
            .filter { !$0.type.lowercased().hasPrefix("waste") }
            .map { supply in
                Supply(name: supply.name,
                       color: supply.color.isEmpty ? nil : supply.color,
                       level: (0...100).contains(supply.level) ? supply.level : nil,
                       isLow: supply.level >= 0 && supply.lowLevel.map { supply.level <= $0 } == true)
            }
        return refreshed
    }

    private static func row(for queue: SystemPrinter, hints: PortHints, endpoint: IppEndpoint?) -> PrinterInfo {
        let problems = SystemQueueProblems.describe(queue.states)
        let state: PrinterState
        if queue.states.contains(.offline) {
            state = .offline
        } else if problems.contains(where: { $0.isError }) {
            state = .stopped
        } else if queue.states.contains(.busy) {
            state = .printing
        } else {
            state = .idle
        }
        return PrinterInfo(id: "system:" + queue.name,
                           name: queue.name,
                           model: endpoint?.txt.model ?? blank(queue.model),
                           address: endpoint?.addresses.first?.host ?? hints.hosts.first,
                           route: .system,
                           ippEndpoint: endpoint,
                           isDefault: queue.isDefault,
                           state: state,
                           problems: problems,
                           supplies: [],
                           queue: QueueStatus(state: state, problems: problems))
    }

    private static func row(for endpoint: IppEndpoint) -> PrinterInfo {
        PrinterInfo(id: "ipp:" + (uuidText(endpoint.uuid) ?? endpoint.key), name: endpoint.name, model: endpoint.txt.model,
                    address: endpoint.addresses.first?.host, route: .ipp, ippEndpoint: endpoint, isDefault: false,
                    state: .unknown, problems: [], supplies: [])
    }

    private static func blank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A UUID in lower case without "urn:uuid:"; nil when there is none.
    private static func uuidText(_ uuid: String?) -> String? {
        guard let trimmed = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("urn:uuid:") ? String(trimmed.dropFirst("urn:uuid:".count)) : trimmed
    }

    private static func byUuid(_ queue: SystemPrinter, _ hints: PortHints, _ endpoints: [IppEndpoint]) -> IppEndpoint? {
        for candidate in [hints.uuid, hints.portUuid] {
            guard let key = IppTxtRecord.uuidKey(candidate) else { continue }
            if let match = endpoints.first(where: { IppTxtRecord.uuidKey($0.uuid) == key }) { return match }
        }
        return nil
    }

    private static func byHost(_ queue: SystemPrinter, _ hints: PortHints, _ endpoints: [IppEndpoint]) -> IppEndpoint? {
        candidates(hints, endpoints).first { endpoint in
            endpoint.addresses.contains { hints.hosts.contains(hostKey($0.host)) }
        }
    }

    // The name of a queue or the service of a dnssd URI, exactly as the printer advertises it ("... (A1B2C3)" tells two
    // printers of one model apart).
    private static func byInstance(_ queue: SystemPrinter, _ hints: PortHints, _ endpoints: [IppEndpoint]) -> IppEndpoint? {
        if !hints.hosts.isEmpty { return nil }
        let names = [queue.name, hints.instance].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return only(candidates(hints, endpoints).filter { endpoint in
            endpoint.instanceNames.contains { names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        })
    }

    private static func byName(_ queue: SystemPrinter, _ hints: PortHints, _ endpoints: [IppEndpoint]) -> IppEndpoint? {
        if !hints.hosts.isEmpty { return nil }
        let names = [nameKey(queue.name), nameKey(queue.model), nameKey(hints.instance)].compactMap { $0 }
        return only(candidates(hints, endpoints).filter { endpoint in
            if let key = nameKey(endpoint.name), names.contains(key) { return true }
            return endpoint.instanceNames.contains { name in nameKey(name).map { names.contains($0) } == true }
        })
    }

    /// The endpoint when it is the only one; two that fit are not told apart.
    private static func only(_ found: [IppEndpoint]) -> IppEndpoint? {
        found.count == 1 ? found[0] : nil
    }

    // Two printers of one model have different UUIDs: a queue that names its printer's UUID is not another one's.
    private static func candidates(_ hints: PortHints, _ endpoints: [IppEndpoint]) -> [IppEndpoint] {
        let own = IppTxtRecord.uuidKey(hints.uuid)
        return endpoints.filter { endpoint in
            guard let own, let other = IppTxtRecord.uuidKey(endpoint.uuid) else { return true }
            return other == own
        }
    }

    private static func isVirtual(_ queue: SystemPrinter) -> Bool {
        queue.isVirtual
            || matches(virtualName, in: queue.name)
            || (queue.port?.uppercased().hasPrefix("PORTPROMPT:") ?? false)
            || (queue.port?.uppercased().hasPrefix("SHRFAX:") ?? false)
    }

    private static let virtualName = makeRegex(#"print to pdf|send to|\b(xps|onenote)\b|^\s*fax\s*$|\(fax\)"#, ignoreCase: true)
    private static let ipv4 = makeRegex(#"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9.])"#)
    private static let guid = makeRegex(#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, ignoreCase: true)
    private static let uuidParameter = makeRegex(#"[?&]uuid=([^&#]+)"#, ignoreCase: true)
    private static let copySuffix = makeRegex(#"\(\s*(?:copy|redirected)\s*\d*\s*\)"#)

    /// What a queue's port or URI says about the printer behind it. `hosts` are host names and addresses in lower case,
    /// `instance` is the DNS-SD service name of a dnssd:// URI, `uuid` the printer's UUID from the system or a "uuid="
    /// in the device URI, `portUuid` any UUID found in the port name (a WSD port's, which may be the printer's).
    private struct PortHints {
        var hosts: [String]
        var instance: String?
        var uuid: String?
        var portUuid: String?
    }

    private static func portHints(of queue: SystemPrinter) -> PortHints {
        let port = queue.port?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var hosts = [String]()
        var instance: String?
        if let scheme = port.range(of: "://"), scheme.lowerBound > port.startIndex {
            var authority = String(port[scheme.upperBound...])
            if let end = authority.firstIndex(where: { "/?#".contains($0) }) { authority = String(authority[..<end]) }
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            var host: String
            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                host = String(authority[authority.index(after: authority.startIndex)..<close])
            } else {
                host = authority.components(separatedBy: ":")[0]
            }
            host = host.removingPercentEncoding ?? host
            // A DNS-SD URI names the service, "Name._ipp._tcp.local", not a host.
            if let cut = host.range(of: "._"), host.range(of: "._tcp", options: .caseInsensitive) != nil {
                instance = String(host[..<cut.lowerBound])
            } else if !host.isEmpty {
                hosts.append(hostKey(host))
            }
        } else {
            let text = port.lowercased().hasPrefix("ip_") ? String(port.dropFirst(3)) : port
            hosts += allMatches(ipv4, in: text)
            let name = text.components(separatedBy: ":")[0]
            if hosts.isEmpty && name.contains(".") && isDnsName(name) { hosts.append(hostKey(name)) }
        }

        let uuid = queue.uuid ?? firstGroup(uuidParameter, in: port)
        return PortHints(hosts: hosts, instance: instance, uuid: uuid, portUuid: allMatches(guid, in: port).first)
    }

    private static func isDnsName(_ name: String) -> Bool {
        let labels = name.components(separatedBy: ".")
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (scalar.properties.isAlphabetic || (0x30...0x39).contains(scalar.value) || scalar == "-" || scalar == "_")
            }
        }
    }

    /// A host in lower case without a trailing dot or an IPv6 zone, so the ways it is written compare equal.
    private static func hostKey(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while text.hasSuffix(".") { text.removeLast() }
        text = text.lowercased()
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        return text
    }

    /// A name's letters and digits as lower-case words, a "(Copy 1)" or "(Redirected 1)" left out; nil when none are left.
    private static func nameKey(_ name: String?) -> String? {
        guard let name else { return nil }
        let lowered = name.lowercased()
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        let text = copySuffix.stringByReplacingMatches(in: lowered, options: [], range: range, withTemplate: " ")
        var words = [String]()
        var word = ""
        for scalar in text.unicodeScalars {
            if (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func allMatches(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func makeRegex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }
}
