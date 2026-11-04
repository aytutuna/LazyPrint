#if os(iOS)
import LazyPrintKit
import Foundation

/// The computers a phone pairs with, seen on the network: their `CompanionProtocol.serviceType` services (TXT `id`),
/// browsed with `NWBrowsing` and resolved with `DnssdResolver` as network printers are, only while something needs it
/// (`begin`, `end`): the computer screen while it is open, a check of the paired computer while it runs. What it saw says
/// whether a computer that does not answer is on this network at all (`isSeen`, the state's `companionDesktopSeenOnNetwork`)
/// and where each computer is now (`onFound`, for an address that changed). The app makes one only when launched without
/// `-demoPrinter`.
@MainActor
public final class IOSCompanionBrowser: ObservableObject {
    /// The browser waits for Local Network access, which is off for the app.
    @Published public private(set) var accessDenied: Bool = false
    /// A computer resolved: its id, addresses and port. Once for each computer while browsing runs.
    public var onFound: ((String, [String], Int) -> Void)?

    private let makeBrowser: @MainActor () -> any Browsing
    private let resolver: any Resolving
    private var browser: (any Browsing)?
    private var users: Int = 0
    private var seen: Set<String> = []
    private var resolving: [String: any ResolveHandle] = [:]
    private var done: Set<String> = []

    /// The app's: NWBrowser and DNS-SD.
    public convenience init() {
        self.init(makeBrowser: { () -> any Browsing in
            NWBrowsing(type: CompanionProtocol.serviceType)
        }, resolver: DnssdResolver())
    }

    /// Browses with what `makeBrowser` makes and resolves with `resolver` (tests: stand-ins).
    init(makeBrowser: @escaping @MainActor () -> any Browsing, resolver: any Resolving) {
        self.makeBrowser = makeBrowser
        self.resolver = resolver
    }

    public var isBrowsing: Bool { browser != nil }

    /// Browsing is needed: it starts unless it runs already. Each `begin` is ended by an `end`.
    public func begin() {
        users += 1
        guard browser == nil else { return }
        seen = []
        done = []
        let made: any Browsing = makeBrowser()
        made.onStatus = { [weak self] (status: BrowserStatus) -> Void in
            self?.statusChanged(status)
        }
        made.onResults = { [weak self] (results: [BrowseResult]) -> Void in
            self?.found(results)
        }
        browser = made
        made.start()
    }

    /// No longer needed by one of those that began it; stops once none needs it. What was seen stays until the next
    /// start.
    public func end() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0, let running = browser else { return }
        browser = nil
        running.onStatus = nil
        running.onResults = nil
        running.cancel()
        for operation in resolving.values {
            operation.cancel()
        }
        resolving = [:]
    }

    /// Whether the computer with this id was among the services last reported.
    public func isSeen(_ desktopId: String) -> Bool {
        seen.contains(desktopId)
    }

    /// The computer id in a service's TXT record; nil without a valid one.
    nonisolated static func desktopId(_ result: BrowseResult) -> String? {
        guard let id = result.txt[CompanionProtocol.txtIdKey], CompanionProtocol.isValidId(id) else { return nil }
        return id
    }

    private func statusChanged(_ status: BrowserStatus) {
        switch status {
        case .waiting(let code, _), .failed(let code, _):
            accessDenied = LocalNetwork.isPolicyDenied(code)
        case .ready:
            accessDenied = false
        case .setup, .cancelled:
            break
        }
    }

    private func found(_ results: [BrowseResult]) {
        var ids: Set<String> = []
        for result in results {
            guard let id = IOSCompanionBrowser.desktopId(result) else { continue }
            ids.insert(id)
            guard !done.contains(id), resolving[id] == nil else { continue }
            let operation: any ResolveHandle = resolver.resolve(result) { [weak self] (outcome: ResolveOutcome) -> Void in
                self?.resolved(id, outcome)
            }
            // A resolver that answered at once has nothing left to stop.
            if !done.contains(id) {
                resolving[id] = operation
            }
        }
        seen = ids
    }

    private func resolved(_ id: String, _ outcome: ResolveOutcome) {
        resolving[id] = nil
        done.insert(id)
        if case .resolved(let service) = outcome {
            onFound?(id, service.addresses, service.port)
        }
    }
}
#endif
