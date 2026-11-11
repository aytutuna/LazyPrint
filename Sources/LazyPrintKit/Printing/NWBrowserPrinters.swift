import Darwin
import Foundation
import Network
import dnssd

// The Apple side of windows/LazyPrint.App/Services/IppDiscovery.cs and NetworkPrinters.cs: finds network printers that
// announce IPP over DNS-SD (_ipp._tcp, and _ipps._tcp for TLS) and hands them over as the same `IppService` values
// Windows produces, so `IppEndpoint.choose` groups and orders them the same way. NWBrowser browses and gives the TXT
// records but does not resolve, and an NWConnection reaches one address only; the host name, port and every address
// come from the DNS-SD C API. Both sit behind `Browsing` and `Resolving`, so tests feed results by hand and no test
// browses the network. Nothing is advertised: the app only looks.

enum IppServices {
    /// A service instance as the browser reports it: its TXT record as "key=value" entries in key order. The host name,
    /// port and addresses come with the resolve; until then the service has none and `IppEndpoint.choose` leaves it out.
    static func from(name: String, type: String, txt: [String: String]) -> IppService {
        var service = type
        while service.hasSuffix(".") { service.removeLast() }
        let entries = txt.keys.sorted().map { $0 + "=" + (txt[$0] ?? "") }
        return IppService(id: (name + "." + service).lowercased(), instanceName: name,
                          secure: service.lowercased().hasPrefix("_ipps."), hostName: nil, addresses: [], port: 0,
                          textAttributes: entries)
    }
}

/// How the system says that the app may not use the local network.
public enum LocalNetwork {
    /// kDNSServiceErr_PolicyDenied: the system refused to browse or resolve (Local Network access is off).
    public static let policyDeniedCode: Int32 = -65570

    public static func isPolicyDenied(_ code: Int32?) -> Bool {
        code == policyDeniedCode
    }
}

/// One service instance a browser reports.
public struct BrowseResult: Hashable, Sendable {
    public var name: String
    /// "_ipp._tcp" or "_ipps._tcp".
    public var type: String
    /// Usually "local.".
    public var domain: String
    /// The interface it was seen on; 0 when any.
    public var interfaceIndex: Int
    public var txt: [String: String]

    public init(name: String, type: String, domain: String = "local.", interfaceIndex: Int = 0, txt: [String: String] = [:]) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.txt = txt
    }

    var secure: Bool { type.lowercased().hasPrefix("_ipps.") }

    /// Names the instance across reports, ignoring case.
    var key: String { (name + "." + type + "." + domain).lowercased() }
}

/// How a browser is doing, as the system reports it; `code` is the DNS-SD error when there is one.
public enum BrowserStatus: Equatable, Sendable {
    case setup
    case ready
    case waiting(code: Int32?, detail: String)
    case failed(code: Int32?, detail: String)
    case cancelled
}

/// Where a service is: its host name, port and every address as text ("192.168.1.20", "fe80::1%4").
public struct ResolvedService: Equatable, Sendable {
    public var hostName: String?
    public var port: Int
    public var addresses: [String]
}

public enum ResolveOutcome: Equatable, Sendable {
    case resolved(ResolvedService)
    /// Not resolved; the text says why, for the diagnostics.
    case failed(String)
    /// The system refused: Local Network access is off.
    case denied
}

/// Browses one service type and reports the instances found (each time, all of them) and how browsing goes, on the
/// main actor. The app's is `NWBrowsing`; tests pass a stand-in.
@MainActor
public protocol Browsing: AnyObject {
    var onStatus: ((BrowserStatus) -> Void)? { get set }
    var onResults: (([BrowseResult]) -> Void)? { get set }
    func start()
    func cancel()
}

/// A resolve under way.
@MainActor
public protocol ResolveHandle: AnyObject {
    func cancel()
}

/// Finds a service's host name, port and every address. Calls `completion` once, on the main actor, unless cancelled
/// first. The app's is `DnssdResolver`; tests pass a stand-in.
@MainActor
public protocol Resolving: AnyObject {
    func resolve(_ result: BrowseResult, completion: @escaping @MainActor (ResolveOutcome) -> Void) -> any ResolveHandle
}

/// The network printers of the app: what the browsers find, and the addresses of ipp-hosts.json. An address is asked
/// with Get-Printer-Attributes when the app starts and again every minute while it does not answer; one that answers is
/// handed over as an `IppService` like a discovered one, so the printer list merges it by UUID.
@MainActor
public final class NWBrowserPrinters: NetworkPrinters {
    typealias BrowserFactory = @MainActor (String) -> any Browsing

    private static let serviceTypes = ["_ipps._tcp", "_ipp._tcp"]

    public var onChange: (() -> Void)?

    private let makeBrowser: BrowserFactory
    private let resolver: any Resolving
    private let hostList: IppHostList
    private let trustStore: IppTrustStore
    private let userName: String
    private let recheck: TimeInterval
    private var browses: [Browse] = []
    private var found: [Found] = []
    private var deniedElsewhere = false
    private var resolveCount = 0
    private var manual: [PrinterAddress: Host] = [:]
    private var manualOrder: [PrinterAddress] = []
    private var hostLoop: Task<Void, Never>?
    private var loopGeneration = 0
    private var loopRunning = false

    /// One browser, for one service type.
    @MainActor
    private final class Browse {
        let browser: any Browsing
        let secure: Bool
        var ready = false
        var denied = false
        var failure: String?

        init(browser: any Browsing, secure: Bool) {
            self.browser = browser
            self.secure = secure
        }
    }

    /// A service instance as reported, and what resolving it came to.
    @MainActor
    private final class Found {
        var result: BrowseResult
        var resolved: ResolvedService?
        var problem: String?
        var handle: (any ResolveHandle)?
        var isResolving = false
        /// The number of the resolve started last, so a late answer of an earlier one is dropped.
        var attempt = 0

        init(result: BrowseResult) {
            self.result = result
        }
    }

    /// An address of the host list and what asking it came to.
    private struct Host {
        var listed: Bool
        var problem: String?
        var service: IppService?
    }

    /// The app's: NWBrowser and the DNS-SD resolver, the host list and the trust store in `directory` (the settings folder
    /// by default). `platform` names the requesting user of the requests.
    public convenience init(directory: URL? = nil, platform: AppPlatform = .mac) {
        self.init(directory: directory ?? StoreFiles.defaultDirectory, userName: platform.requestingUserName, recheck: 60,
                  makeBrowser: { (type: String) -> any Browsing in NWBrowsing(type: type) }, resolver: DnssdResolver())
    }

    init(directory: URL, userName: String, recheck: TimeInterval, makeBrowser: @escaping BrowserFactory,
         resolver: any Resolving) {
        self.hostList = IppHostList(directory: directory)
        self.trustStore = IppTrustStore(directory: directory)
        self.userName = userName
        self.recheck = recheck
        self.makeBrowser = makeBrowser
        self.resolver = resolver
    }

    // MARK: State

    public var services: [IppService] {
        var list = [IppService]()
        for entry in found {
            var service = IppServices.from(name: entry.result.name, type: entry.result.type, txt: entry.result.txt)
            if let resolved = entry.resolved {
                service.hostName = resolved.hostName
                service.addresses = resolved.addresses
                service.port = resolved.port
            }
            list.append(service)
        }
        for address in manualOrder {
            if let service = manual[address]?.service { list.append(service) }
        }
        return list
    }

    /// How the search goes: off (not started), denied, unavailable (a browser failed), running (every browser is ready)
    /// or searching.
    public var discovery: DiscoveryStatus {
        if deniedElsewhere { return .denied }
        if browses.isEmpty { return .off }
        if browses.contains(where: { $0.denied }) { return .denied }
        if browses.contains(where: { $0.failure != nil }) { return .unavailable }
        if browses.contains(where: { !$0.ready }) { return .searching }
        return .running
    }

    public var discoveryDetail: String? {
        if deniedElsewhere || browses.contains(where: { $0.denied }) { return "Local Network access is off" }
        return browses.compactMap { $0.failure }.first
    }

    public var hosts: [ManualHostStatus] {
        hostList.load().map { address in
            if let host = manual[address] {
                return ManualHostStatus(address: address.description, listed: host.listed, problem: host.problem)
            }
            return ManualHostStatus(address: address.description, listed: false)
        }
    }

    // MARK: Starting

    public func start() {
        if browses.isEmpty {
            deniedElsewhere = false
            startMissing()
        }
        startHostLoop()
        changed()
    }

    /// Starts again a browser that failed, resolves what is not resolved and checks the unanswered addresses now. A
    /// browser that works, or waits for Local Network access (the system retries by itself), is left alone.
    public func restart() {
        guard !browses.isEmpty else { return }
        var kept = [Browse]()
        for browse in browses {
            if browse.failure != nil {
                browse.browser.onStatus = nil
                browse.browser.onResults = nil
                browse.browser.cancel()
            } else {
                kept.append(browse)
            }
        }
        browses = kept
        deniedElsewhere = false
        startMissing()
        for entry in found where !entry.isResolving && entry.resolved == nil {
            startResolve(entry)
        }
        startHostLoop()
        changed()
    }

    /// Stops browsing and checking addresses, and forgets what was found.
    public func stop() {
        hostLoop?.cancel()
        hostLoop = nil
        loopRunning = false
        let stopping = browses
        browses = []
        for browse in stopping {
            browse.browser.onStatus = nil
            browse.browser.onResults = nil
            browse.browser.cancel()
        }
        for entry in found {
            cancelResolve(entry)
        }
        found = []
        deniedElsewhere = false
        changed()
    }

    private func startMissing() {
        var started = [Browse]()
        for type in Self.serviceTypes {
            let secure = type == "_ipps._tcp"
            if browses.contains(where: { $0.secure == secure }) { continue }
            let browse = Browse(browser: makeBrowser(type), secure: secure)
            browse.browser.onStatus = { [weak self, weak browse] (status: BrowserStatus) -> Void in
                guard let self, let browse else { return }
                self.browserStatus(browse, status)
            }
            browse.browser.onResults = { [weak self, weak browse] (results: [BrowseResult]) -> Void in
                guard let self, let browse else { return }
                self.browserResults(browse, results)
            }
            browses.append(browse)
            started.append(browse)
        }
        for browse in started {
            browse.browser.start()
        }
    }

    // MARK: What the browsers and the resolver report

    private func isCurrent(_ browse: Browse) -> Bool {
        browses.contains(where: { $0 === browse })
    }

    private func browserStatus(_ browse: Browse, _ status: BrowserStatus) {
        guard isCurrent(browse) else { return }
        switch status {
        case .setup, .cancelled:
            return
        case .ready:
            browse.ready = true
            browse.denied = false
            browse.failure = nil
            // Access granted again (or never refused): what a resolve said about it is over.
            deniedElsewhere = false
        case .waiting(let code, _):
            browse.ready = false
            browse.denied = LocalNetwork.isPolicyDenied(code)
        case .failed(let code, let detail):
            browse.ready = false
            browse.denied = LocalNetwork.isPolicyDenied(code)
            browse.failure = browse.denied ? nil : detail
        }
        changed()
    }

    /// A browser's full list: new instances are resolved, a changed TXT record is taken as it is, one that did not resolve
    /// is tried again, and the instances of its type it no longer reports are gone.
    private func browserResults(_ browse: Browse, _ results: [BrowseResult]) {
        guard isCurrent(browse) else { return }
        var reported = Set<String>()
        for result in results where result.secure == browse.secure {
            reported.insert(result.key)
            if let entry = found.first(where: { $0.result.key == result.key }) {
                entry.result = result
                if entry.resolved == nil && !entry.isResolving { startResolve(entry) }
            } else {
                let entry = Found(result: result)
                found.append(entry)
                startResolve(entry)
            }
        }
        var kept = [Found]()
        for entry in found {
            if entry.result.secure == browse.secure && !reported.contains(entry.result.key) {
                cancelResolve(entry)
            } else {
                kept.append(entry)
            }
        }
        found = kept
        changed()
    }

    private func startResolve(_ entry: Found) {
        resolveCount += 1
        entry.attempt = resolveCount
        entry.problem = nil
        entry.isResolving = true
        let attempt = entry.attempt
        let key = entry.result.key
        let handle = resolver.resolve(entry.result) { [weak self] (outcome: ResolveOutcome) -> Void in
            self?.resolved(key, attempt: attempt, outcome)
        }
        // A resolver that answered at once has nothing left to stop.
        if entry.isResolving && entry.attempt == attempt { entry.handle = handle }
    }

    private func cancelResolve(_ entry: Found) {
        entry.isResolving = false
        entry.handle?.cancel()
        entry.handle = nil
    }

    private func resolved(_ key: String, attempt: Int, _ outcome: ResolveOutcome) {
        // Gone, or resolved again meanwhile: a late answer is dropped.
        guard let entry = found.first(where: { $0.result.key == key }), entry.attempt == attempt, entry.isResolving else { return }
        entry.isResolving = false
        entry.handle = nil
        switch outcome {
        case .resolved(let service):
            entry.resolved = service
            entry.problem = nil
        case .failed(let reason):
            entry.problem = reason
        case .denied:
            entry.problem = "Local Network access is off"
            deniedElsewhere = true
        }
        changed()
    }

    private func changed() {
        onChange?()
    }

    // MARK: Addresses

    /// Checks the listed addresses now and keeps checking those that do not answer; a loop already running is replaced.
    private func startHostLoop() {
        hostLoop?.cancel()
        loopGeneration += 1
        let generation = loopGeneration
        loopRunning = true
        hostLoop = Task { [weak self] in
            await self?.checkHosts(generation)
        }
    }

    private func checkHosts(_ generation: Int) async {
        defer {
            if loopGeneration == generation { loopRunning = false }
        }
        var onlyUnlisted = false
        while !Task.isCancelled {
            let addresses = hostList.load()
            manualOrder = addresses
            for gone in manual.keys where !addresses.contains(gone) { manual[gone] = nil }
            let tasks = addresses.filter { !onlyUnlisted || !isListed($0) }.map { address in
                (address, Task { await self.probe(address) })
            }
            var answers = [(PrinterAddress, AddressCheck)]()
            for (address, task) in tasks {
                answers.append((address, await task.value))
            }
            if Task.isCancelled { return }
            for (address, result) in answers {
                manual[address] = Self.host(of: result)
            }
            changed()
            if addresses.allSatisfy({ isListed($0) }) { return }
            try? await Task.sleep(nanoseconds: UInt64(recheck * 1_000_000_000))
            onlyUnlisted = true
        }
    }

    private func isListed(_ address: PrinterAddress) -> Bool {
        manual[address]?.listed == true
    }

    /// An address in the list: a new certificate is trusted on first use, since the user put the address there. A changed
    /// one lists nothing (the service would not be reachable), and the problem says so.
    private func probe(_ address: PrinterAddress) async -> AddressCheck {
        let result = await check(address, uuid: nil, name: address.description, firstUse: nil)
        if let certificate = result.certificate, certificate.verdict == .unknown, certificate.canTrust {
            return await check(address, uuid: nil, name: address.description, firstUse: certificate.fingerprint)
        }
        return result
    }

    private static func host(of result: AddressCheck) -> Host {
        if let capabilities = result.capabilities {
            return Host(listed: true, problem: nil, service: service(of: result.address, capabilities))
        }
        return Host(listed: false, problem: result.certificate?.message ?? result.error, service: nil)
    }

    /// The service an address that answered stands for: its host as an address or a name, its resource path and what the
    /// printer says of itself in the TXT keys `IppEndpoint` uses.
    static func service(of address: PrinterAddress, _ capabilities: PrinterCapabilities) -> IppService {
        let literal = IppHostText.ipv4(address.host) != nil || IppHostText.ipv6(address.host) != nil
        var txt = ["rp=\(address.resourcePath)"]
        if !capabilities.makeAndModel.isEmpty { txt.append("ty=\(capabilities.makeAndModel)") }
        if let uuid = capabilities.uuid, !uuid.isEmpty { txt.append("UUID=\(uuid)") }
        let name = !capabilities.name.isEmpty ? capabilities.name
            : (!capabilities.makeAndModel.isEmpty ? capabilities.makeAndModel : address.host)
        return IppService(id: "address:" + address.description, instanceName: name, secure: address.secure,
                          hostName: literal ? nil : address.host, addresses: literal ? [address.host] : [],
                          port: address.port, textAttributes: txt)
    }

    // MARK: Asking printers

    public func read(_ endpoint: IppEndpoint) async -> AddressCheck {
        var last: AddressCheck?
        for address in endpoint.addresses {
            // A new certificate is not pinned by discovery: it is shown when the user selects or prints to the printer.
            let result = await check(address, uuid: endpoint.uuid, name: endpoint.name, firstUse: nil)
            if result.capabilities != nil || result.certificate != nil { return result }
            last = result
        }
        return last ?? AddressCheck(address: endpoint.addresses[0], capabilities: nil, certificate: nil, error: "it has no address")
    }

    public func check(_ address: PrinterAddress, firstUse: String?) async -> AddressCheck {
        await check(address, uuid: nil, name: address.description, firstUse: firstUse)
    }

    private func check(_ address: PrinterAddress, uuid: String?, name: String, firstUse: String?) async -> AddressCheck {
        let validator = IppCertificateValidator(store: trustStore, deviceUuid: uuid, deviceName: name, firstUse: firstUse)
        let client = IppClient(address: address, printerName: name, userName: userName, validator: validator)
        do {
            let capabilities = try await client.capabilities()
            return AddressCheck(address: client.address, capabilities: capabilities, certificate: nil, error: nil)
        } catch let error as IppCertificateError {
            return AddressCheck(address: address, capabilities: nil, certificate: error, error: nil)
        } catch {
            return AddressCheck(address: address, capabilities: nil, certificate: nil, error: error.localizedDescription)
        }
    }

    public func add(_ address: PrinterAddress, capabilities: PrinterCapabilities) {
        hostList.add(address)
        if !manualOrder.contains(address) { manualOrder.append(address) }
        manual[address] = Self.host(of: AddressCheck(address: address, capabilities: capabilities, certificate: nil, error: nil))
        changed()
        // The checks of the other addresses go on, or start if every address answered before.
        if !loopRunning { startHostLoop() }
    }

    public func trust(_ certificate: IppCertificateError, deviceUuid: String?, name: String) {
        try? trustStore.trust(certificate.fingerprint, deviceUuid: deviceUuid ?? certificate.deviceUuid,
                              authority: certificate.authority, name: name)
    }
}

// MARK: - The system's side

/// NWBrowser for _ipp._tcp or _ipps._tcp, with the TXT records, peer-to-peer off, on the main queue.
@MainActor
public final class NWBrowsing: Browsing {
    public var onStatus: ((BrowserStatus) -> Void)?
    public var onResults: (([BrowseResult]) -> Void)?
    private let type: String
    private var browser: NWBrowser?

    public init(type: String) {
        self.type = type
    }

    public func start() {
        guard browser == nil else { return }
        let parameters: NWParameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor: NWBrowser.Descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: type, domain: nil)
        let made: NWBrowser = NWBrowser(for: descriptor, using: parameters)
        made.stateUpdateHandler = { [weak self] (state: NWBrowser.State) -> Void in
            let status: BrowserStatus = NWBrowsing.status(of: state)
            MainActor.assumeIsolated {
                self?.onStatus?(status)
            }
        }
        made.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _: Set<NWBrowser.Result.Change>) -> Void in
            let found: [BrowseResult] = NWBrowsing.browseResults(results)
            MainActor.assumeIsolated {
                self?.onResults?(found)
            }
        }
        browser = made
        made.start(queue: DispatchQueue.main)
    }

    public func cancel() {
        guard let running = browser else { return }
        browser = nil
        running.stateUpdateHandler = nil
        running.browseResultsChangedHandler = nil
        running.cancel()
    }

    nonisolated static func status(of state: NWBrowser.State) -> BrowserStatus {
        switch state {
        case .setup:
            return BrowserStatus.setup
        case .ready:
            return BrowserStatus.ready
        case .cancelled:
            return BrowserStatus.cancelled
        case .waiting(let error):
            return BrowserStatus.waiting(code: dnsCode(error), detail: error.debugDescription)
        case .failed(let error):
            return BrowserStatus.failed(code: dnsCode(error), detail: error.debugDescription)
        @unknown default:
            return BrowserStatus.setup
        }
    }

    nonisolated static func dnsCode(_ error: NWError) -> Int32? {
        if case .dns(let code) = error {
            return Int32(code)
        }
        return nil
    }

    /// The service instances in `results`, by name, with their TXT records.
    nonisolated static func browseResults(_ results: Set<NWBrowser.Result>) -> [BrowseResult] {
        var list: [BrowseResult] = []
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            var entries: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                entries = record.dictionary
            }
            var interfaceIndex: Int = 0
            if let first = result.interfaces.first {
                interfaceIndex = first.index
            }
            list.append(BrowseResult(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex, txt: entries))
        }
        list.sort { (left: BrowseResult, right: BrowseResult) -> Bool in
            left.key < right.key
        }
        return list
    }
}

/// Resolves services with the DNS-SD C API: DNSServiceResolve for the host name and port, then DNSServiceGetAddrInfo for
/// every IPv4 and IPv6 address of that host. The answer comes once the first address has had `settleTime` for the others
/// to follow, or `timeout` after the start without any; the requests are deallocated then.
@MainActor
public final class DnssdResolver: Resolving {
    var timeout: TimeInterval = 5
    var settleTime: TimeInterval = 1

    public init() {}

    public func resolve(_ result: BrowseResult, completion: @escaping @MainActor (ResolveOutcome) -> Void) -> any ResolveHandle {
        let operation: DnssdResolve = DnssdResolve(result: result, timeout: timeout, settleTime: settleTime, completion: completion)
        operation.start()
        return operation
    }
}

/// The resolve's answer: the operation is kept alive (retained by hand) until it finishes, since the DNS-SD callbacks only
/// carry a raw pointer to it.
private let resolveReply: DNSServiceResolveReply = {
    (_: DNSServiceRef?, _: DNSServiceFlags, interfaceIndex: UInt32, error: DNSServiceErrorType,
     _: UnsafePointer<CChar>?, hostTarget: UnsafePointer<CChar>?, port: UInt16, _: UInt16,
     _: UnsafePointer<UInt8>?, context: UnsafeMutableRawPointer?) -> Void in
    guard let context else { return }
    let operation: DnssdResolve = Unmanaged<DnssdResolve>.fromOpaque(context).takeUnretainedValue()
    var host: String?
    if let hostTarget {
        host = String(cString: hostTarget)
    }
    let hostPort: Int = Int(UInt16(bigEndian: port))
    MainActor.assumeIsolated {
        operation.resolved(error: error, hostTarget: host, port: hostPort, interfaceIndex: interfaceIndex)
    }
}

/// An address of the host: added or removed.
private let addressReply: DNSServiceGetAddrInfoReply = {
    (_: DNSServiceRef?, flags: DNSServiceFlags, _: UInt32, error: DNSServiceErrorType, _: UnsafePointer<CChar>?,
     address: UnsafePointer<sockaddr>?, _: UInt32, context: UnsafeMutableRawPointer?) -> Void in
    guard let context else { return }
    let operation: DnssdResolve = Unmanaged<DnssdResolve>.fromOpaque(context).takeUnretainedValue()
    var text: String?
    if let address {
        text = DnssdResolve.text(of: address)
    }
    let added: Bool = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
    MainActor.assumeIsolated {
        operation.address(error: error, text: text, added: added)
    }
}

/// One resolve: its DNS-SD requests, on the main queue, and what they found so far.
@MainActor
final class DnssdResolve: ResolveHandle {
    private let result: BrowseResult
    private let timeout: TimeInterval
    private let settleTime: TimeInterval
    private var completion: (@MainActor (ResolveOutcome) -> Void)?
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var retained: Unmanaged<DnssdResolve>?
    private var hostName: String?
    private var port: Int = 0
    private var addresses: [String] = []
    private var settling: Bool = false

    init(result: BrowseResult, timeout: TimeInterval, settleTime: TimeInterval,
         completion: @escaping @MainActor (ResolveOutcome) -> Void) {
        self.result = result
        self.timeout = timeout
        self.settleTime = settleTime
        self.completion = completion
    }

    func start() {
        let unmanaged: Unmanaged<DnssdResolve> = Unmanaged<DnssdResolve>.passRetained(self)
        retained = unmanaged
        var ref: DNSServiceRef?
        let interfaceIndex: UInt32 = UInt32(clamping: result.interfaceIndex)
        let error: DNSServiceErrorType = DNSServiceResolve(&ref, 0, interfaceIndex, result.name, result.type, result.domain,
                                                           resolveReply, unmanaged.toOpaque())
        guard Int(error) == kDNSServiceErr_NoError, let started = ref else {
            finish(DnssdResolve.outcome(error, doing: "resolve"))
            return
        }
        resolveRef = started
        _ = DNSServiceSetDispatchQueue(started, DispatchQueue.main)
        let wait: TimeInterval = timeout
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                self?.timedOut()
            }
        }
    }

    func cancel() {
        completion = nil
        release()
    }

    /// The service's host and port: its addresses are asked for next.
    fileprivate func resolved(error: DNSServiceErrorType, hostTarget: String?, port: Int, interfaceIndex: UInt32) {
        guard completion != nil, addressRef == nil else { return }
        guard Int(error) == kDNSServiceErr_NoError else {
            finish(DnssdResolve.outcome(error, doing: "resolve"))
            return
        }
        if let ref = resolveRef {
            resolveRef = nil
            DNSServiceRefDeallocate(ref)
        }
        guard let target = hostTarget, !target.isEmpty else {
            finish(ResolveOutcome.failed("no host name"))
            return
        }
        var shown: String = target
        while shown.hasSuffix(".") {
            shown.removeLast()
        }
        hostName = shown
        self.port = port
        guard let unmanaged = retained else { return }
        var ref: DNSServiceRef?
        let protocols: DNSServiceProtocol = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let started: DNSServiceErrorType = DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, protocols, target,
                                                                 addressReply, unmanaged.toOpaque())
        guard Int(started) == kDNSServiceErr_NoError, let lookup = ref else {
            finish(DnssdResolve.outcome(started, doing: "address lookup"))
            return
        }
        addressRef = lookup
        _ = DNSServiceSetDispatchQueue(lookup, DispatchQueue.main)
    }

    /// An address of the host: kept (or dropped when removed); the answer follows `settleTime` after the first.
    fileprivate func address(error: DNSServiceErrorType, text: String?, added: Bool) {
        guard completion != nil else { return }
        guard Int(error) == kDNSServiceErr_NoError else {
            if addresses.isEmpty {
                finish(DnssdResolve.outcome(error, doing: "address lookup"))
            }
            return
        }
        guard let text else { return }
        if added {
            if !addresses.contains(text) {
                addresses.append(text)
            }
        } else {
            addresses.removeAll { (known: String) -> Bool in known == text }
        }
        if !addresses.isEmpty && !settling {
            settling = true
            let wait: TimeInterval = settleTime
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.settled()
                }
            }
        }
    }

    private func settled() {
        guard completion != nil else { return }
        if addresses.isEmpty {
            finish(ResolveOutcome.failed("no address"))
            return
        }
        finish(ResolveOutcome.resolved(ResolvedService(hostName: hostName, port: port, addresses: addresses)))
    }

    private func timedOut() {
        guard completion != nil, !settling else { return }
        finish(ResolveOutcome.failed("no answer in time"))
    }

    private func finish(_ outcome: ResolveOutcome) {
        let answer: (@MainActor (ResolveOutcome) -> Void)? = completion
        completion = nil
        release()
        answer?(outcome)
    }

    /// Ends the DNS-SD requests (no callback comes after this on the main queue) and lets go of the operation.
    private func release() {
        if let ref = resolveRef {
            resolveRef = nil
            DNSServiceRefDeallocate(ref)
        }
        if let ref = addressRef {
            addressRef = nil
            DNSServiceRefDeallocate(ref)
        }
        if let unmanaged = retained {
            retained = nil
            unmanaged.release()
        }
    }

    /// A DNS-SD error as an outcome: PolicyDenied (Local Network access off) is `.denied`.
    nonisolated static func outcome(_ error: DNSServiceErrorType, doing: String) -> ResolveOutcome {
        if LocalNetwork.isPolicyDenied(Int32(error)) {
            return ResolveOutcome.denied
        }
        return ResolveOutcome.failed("\(doing) failed (DNS-SD error \(error))")
    }

    /// An IPv4 or IPv6 address as text; a link-local IPv6 address with its interface as the zone ("fe80::1%4").
    nonisolated static func text(of address: UnsafePointer<sockaddr>) -> String? {
        let family: Int32 = Int32(address.pointee.sa_family)
        if family == AF_INET {
            var ipv4: in_addr = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in>) -> in_addr in
                pointer.pointee.sin_addr
            }
            var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
            let length: socklen_t = socklen_t(buffer.count)
            guard inet_ntop(AF_INET, &ipv4, &buffer, length) != nil else { return nil }
            return DnssdResolve.string(buffer)
        }
        if family == AF_INET6 {
            var ipv6: in6_addr = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in6>) -> in6_addr in
                pointer.pointee.sin6_addr
            }
            let scope: UInt32 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                (pointer: UnsafePointer<sockaddr_in6>) -> UInt32 in
                pointer.pointee.sin6_scope_id
            }
            var buffer: [CChar] = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
            let length: socklen_t = socklen_t(buffer.count)
            guard inet_ntop(AF_INET6, &ipv6, &buffer, length) != nil else { return nil }
            guard let text = DnssdResolve.string(buffer) else { return nil }
            return scope == 0 ? text : text + "%" + String(scope)
        }
        return nil
    }

    private nonisolated static func string(_ buffer: [CChar]) -> String? {
        let text: String = buffer.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<CChar>) -> String in
            guard let base = pointer.baseAddress else { return "" }
            return String(cString: base)
        }
        return text.isEmpty ? nil : text
    }
}
