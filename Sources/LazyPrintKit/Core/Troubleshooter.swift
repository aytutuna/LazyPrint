import Foundation

// Twin of windows/LazyPrint.Core/Core/Troubleshooter.cs (Lazy Scan's Troubleshooter, for printers): "Why isn't my
// printer listed?". What the app knows about finding printers goes into one snapshot and comes out as plain-language
// checks, each with the actions that help. Diagnosing only reads; the app asks before it runs an action that changes
// something (clearing stuck jobs, resuming a printer).

/// The network the device is on, as far as finding network printers goes.
public enum NetworkStatus: String, CaseIterable, Sendable {
    /// Not known (not checked).
    case unknown
    case offline
    /// Every connected network is public: Windows does not look for devices there.
    case publicNetwork
    case privateNetwork
    case domainNetwork
}

/// The state of a system service (on Windows, the Print Spooler).
public enum ServiceStatus: String, CaseIterable, Sendable {
    /// Not known (not checked, or the system would not say).
    case unknown
    case running
    case starting
    case stopping
    case stopped
    case paused
    /// Stopped and set not to start.
    case disabled
    case notInstalled
}

/// The automatic search for network printers (DNS-SD, _ipp._tcp and _ipps._tcp).
public enum DiscoveryStatus: String, CaseIterable, Sendable {
    /// Not known; no check is shown.
    case unknown
    case off
    /// Started; the first pass has not finished.
    case searching
    case running
    /// The system would not search.
    case unavailable
    /// The user turned off the app's access to the local network (iPhone and iPad). Windows and the Mac never produce it.
    case denied
}

/// How a check came out. The order is not the display order (see `Troubleshooter.diagnose`).
public enum CheckStatus: String, CaseIterable, Sendable {
    case ok
    /// Advice that applies whatever the checks found.
    case tip
    case warning
    case problem
}

/// Something the troubleshooter offers to do; the app carries it out.
public enum TroubleshootAction: String, CaseIterable, Sendable {
    /// Look for printers again.
    case refresh
    /// The "Add printer by address" dialog.
    case addByAddress
    /// Windows: Settings, Printers & scanners. Mac: System Settings, Printers & Scanners.
    case openPrinterSettings
    /// Windows: Settings, Network & internet. Mac: System Settings, Network.
    case openNetworkSettings
    /// Copies the checks as text.
    case copyDiagnostics
    /// The app's own page in the Settings app (iPhone and iPad), where Local Network access is turned on.
    case openAppSettings
    /// Removes the jobs waiting in the printer of the check (`stuckJobs:<id>`). Changes something: the app asks first.
    case clearStuckJobs
    /// Resumes the printer of the check (`paused:<id>`). Changes something: the app asks first.
    case resumePrinter
    case printTestPage
}

/// An address added by hand and whether a printer answers there.
public struct ManualHostStatus: Equatable, Sendable {
    /// As the user would write it, e.g. "192.168.1.50" or "printer.local".
    public var address: String
    /// A printer answered and is listed.
    public var listed: Bool
    /// Why nothing is listed, in plain language; nil when listed or not checked yet.
    public var problem: String?

    public init(address: String, listed: Bool, problem: String? = nil) {
        self.address = address
        self.listed = listed
        self.problem = problem
    }
}

/// Jobs waiting in a printer's queue.
public struct StuckJobs: Equatable, Sendable {
    public var printerId: String
    public var printerName: String
    public var count: Int
    /// How long the oldest has been waiting.
    public var oldestMinutes: Int
    /// A job in the queue is in error, which holds up the rest.
    public var anyInError: Bool

    public static let stuckAfterMinutes = 5

    /// Jobs are stuck when one is in error or the oldest has waited five minutes; a job printing now is not.
    public var isStuck: Bool { count > 0 && (anyInError || oldestMinutes >= StuckJobs.stuckAfterMinutes) }

    public init(printerId: String, printerName: String, count: Int, oldestMinutes: Int, anyInError: Bool) {
        self.printerId = printerId
        self.printerName = printerName
        self.count = count
        self.oldestMinutes = oldestMinutes
        self.anyInError = anyInError
    }
}

/// The last time a job or a connection to a printer failed.
public struct PrinterFailure: Equatable, Sendable {
    /// The printer's name as listed.
    public var printerName: String
    /// The error the user was shown.
    public var message: String
    /// The condition behind it, when the error says; a problem that `isError` is a Problem check, else a Warning.
    public var problem: PrinterProblem?

    public init(printerName: String, message: String, problem: PrinterProblem? = nil) {
        self.printerName = printerName
        self.message = message
        self.problem = problem
    }

    static let busy = PrinterProblem(title: "Printer busy", advice: "Wait until it has finished, then print again.", isError: true)
    private static let needsDriver = PrinterProblem(title: "Needs its driver", advice: "Install the maker's driver, then print again.", isError: true)
    private static let needsSignIn = PrinterProblem(title: "Needs a sign-in", advice: "Lazy Print can't sign in to printers yet.", isError: true)
    private static let certificateChanged = PrinterProblem(title: "Certificate changed", advice: "Check the printer, then trust it again.", isError: true)
    private static let certificateNotTrusted = PrinterProblem(title: "Certificate not trusted", advice: "Print again and trust the printer when asked.", isError: false)

    /// What a failed job or connection tells the troubleshooter; nil for errors that say nothing about reaching the
    /// printer (cancelled, a page that could not be prepared).
    public static func from(printerName: String, error: Error) -> PrinterFailure? {
        if error is CancellationError { return nil }
        if let certificate = error as? IppCertificateError {
            return PrinterFailure(printerName: printerName, message: certificate.message,
                                  problem: certificate.verdict == .changed ? certificateChanged : certificateNotTrusted)
        }
        let message = error.localizedDescription
        guard let printError = error as? PrintError else { return PrinterFailure(printerName: printerName, message: message) }
        switch printError {
        case .badRaster: return nil
        case .busy: return PrinterFailure(printerName: printerName, message: message, problem: busy)
        case .needsDriver: return PrinterFailure(printerName: printerName, message: message, problem: needsDriver)
        case .needsSignIn: return PrinterFailure(printerName: printerName, message: message, problem: needsSignIn)
        case .certificateChanged: return PrinterFailure(printerName: printerName, message: message, problem: certificateChanged)
        case .badResponse, .unreachable, .refused: return PrinterFailure(printerName: printerName, message: message)
        }
    }
}

/// Everything the troubleshooter looks at, read at one moment. Fields left at their defaults (unknown, empty) produce
/// no check.
public struct PrinterSnapshot: Equatable, Sendable {
    public var platform: AppPlatform
    /// The printers listed, one per row, the demo printer included.
    public var printers: [PrinterInfo]
    public var network: NetworkStatus
    /// The Print Spooler; Windows only.
    public var spooler: ServiceStatus
    public var discovery: DiscoveryStatus
    /// Why the search is unavailable, as the system put it; nil otherwise.
    public var discoveryDetail: String?
    public var manualHosts: [ManualHostStatus]
    public var stuckJobs: [StuckJobs]
    public var lastFailure: PrinterFailure?

    public init(platform: AppPlatform = .windows, printers: [PrinterInfo] = [], network: NetworkStatus = .unknown,
                spooler: ServiceStatus = .unknown, discovery: DiscoveryStatus = .unknown, discoveryDetail: String? = nil,
                manualHosts: [ManualHostStatus] = [], stuckJobs: [StuckJobs] = [], lastFailure: PrinterFailure? = nil) {
        self.platform = platform
        self.printers = printers
        self.network = network
        self.spooler = spooler
        self.discovery = discovery
        self.discoveryDetail = discoveryDetail
        self.manualHosts = manualHosts
        self.stuckJobs = stuckJobs
        self.lastFailure = lastFailure
    }

    /// The printers listed other than the demo printer.
    public var listedPrinterCount: Int { printers.filter { $0.route != .demo }.count }
}

/// One line of the troubleshooter: what was checked, how it came out, what to do.
public struct TroubleshootCheck: Equatable, Sendable {
    /// Stable identifier ("network", "printer:ipp:4509a320", "manualHost:192.168.1.50", ...).
    public let id: String
    public let status: CheckStatus
    /// Six words at most.
    public let title: String
    /// What it means or what to do, in one line of fifteen words at most.
    public let detail: String
    /// The rest of the explanation, behind "More help"; empty when the detail says it all.
    public let more: String
    /// Buttons offered with it, in order.
    public let actions: [TroubleshootAction]

    public init(id: String, status: CheckStatus, title: String, detail: String, more: String = "",
                actions: [TroubleshootAction]) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.more = more
        self.actions = actions
    }

    /// The detail and the more help as one text, for screen readers and the copied diagnostics.
    public var fullDetail: String {
        more.isEmpty ? detail : detail + " " + more
    }
}

public enum Troubleshooter {

    /// The checks for `snapshot`: problems first, then warnings, then what is fine, then the tips that always apply;
    /// within each, in this order: the last failure, the network, the spooler, the automatic search (or the local
    /// network access it was refused), each printer's problems, stuck jobs, paused printers, the addresses added by
    /// hand, then the tips. The iPhone and iPad get their own wording and tips.
    public static func diagnose(_ snapshot: PrinterSnapshot) -> [TroubleshootCheck] {
        let platform = snapshot.platform
        var checks = [TroubleshootCheck]()

        if let failure = snapshot.lastFailure { checks.append(failureCheck(failure, platform: platform)) }
        if let network = networkCheck(snapshot) { checks.append(network) }
        if platform == .windows, let spooler = spoolerCheck(snapshot.spooler) { checks.append(spooler) }
        if let discovery = discoveryCheck(snapshot) { checks.append(discovery) }
        let listed = snapshot.printers.filter { $0.route != .demo }
        for printer in listed {
            if let check = printerCheck(printer) { checks.append(check) }
        }
        for jobs in snapshot.stuckJobs where jobs.isStuck { checks.append(stuckJobsCheck(jobs)) }
        for printer in listed where printer.problems.contains(where: { $0.title == IppProblemText.paused }) {
            checks.append(pausedCheck(printer))
        }
        for host in snapshot.manualHosts where !host.listed {
            checks.append(TroubleshootCheck(
                id: "manualHost:\(host.address)", status: .warning,
                title: "No printer answers at \(host.address)",
                detail: "Check that it is on and its address hasn't changed.",
                more: joinSentences(host.problem,
                                    "Its network settings page or control panel shows the current address. The app "
                                    + "tries the address again every minute."),
                actions: [.refresh]))
        }
        checks.append(contentsOf: tips(platform))

        // A stable sort: problems, warnings, what is fine, tips.
        return checks.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element.status)
                let right = rank(rhs.element.status)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// "No printer found", "1 printer found", "3 printers found" (the demo printer does not count).
    public static func headline(_ snapshot: PrinterSnapshot) -> String {
        switch snapshot.listedPrinterCount {
        case 0: return "No printer found"
        case 1: return "1 printer found"
        case let count: return "\(count) printers found"
        }
    }

    /// "2 problems and 1 warning found.", or that nothing stops printers from appearing.
    public static func summary(_ checks: [TroubleshootCheck]) -> String {
        let parts = counts(checks)
        if parts.isEmpty {
            return "Nothing here stops printers from appearing. The tips below cover the usual causes."
        }
        return parts.joined(separator: " and ") + " found."
    }

    /// The troubleshooter's one-line headline: what is listed, then how many problems and warnings there are
    /// ("No printer found · 2 problems, 1 warning"); just what is listed when there are none.
    public static func overview(_ snapshot: PrinterSnapshot, checks: [TroubleshootCheck]) -> String {
        let parts = counts(checks)
        let line = headline(snapshot)
        return parts.isEmpty ? line : line + " \u{00B7} " + parts.joined(separator: ", ")
    }

    /// The button text for an action.
    public static func label(_ action: TroubleshootAction, platform: AppPlatform) -> String {
        switch action {
        case .refresh: return "Refresh"
        case .addByAddress: return "Add by address\u{2026}"
        case .openPrinterSettings: return platform == .windows ? "Printer settings" : "Printers & Scanners"
        case .openNetworkSettings: return "Network settings"
        case .copyDiagnostics: return "Copy diagnostics"
        case .openAppSettings: return "Open Settings"
        case .clearStuckJobs: return "Clear stuck jobs"
        case .resumePrinter: return "Resume printer"
        case .printTestPage: return "Print test page"
        }
    }

    /// The status as a word, for screen readers and the copied text: "OK", "Tip", "Warning", "Problem".
    public static func statusLabel(_ status: CheckStatus) -> String {
        switch status {
        case .ok: return "OK"
        case .tip: return "Tip"
        case .warning: return "Warning"
        case .problem: return "Problem"
        }
    }

    /// The checks as plain text, for the pasteboard: the heading, the headline and summary, then one "Status: title"
    /// line per check with its detail indented below, and its more help (when it has some) on the line after.
    public static func report(_ snapshot: PrinterSnapshot, checks: [TroubleshootCheck]) -> String {
        var text = "Why isn't my printer listed?\n"
        text += headline(snapshot) + ". " + summary(checks) + "\n"
        for check in checks {
            text += statusLabel(check.status) + ": " + check.title + "\n"
            text += "  " + check.detail + "\n"
            if !check.more.isEmpty { text += "  " + check.more + "\n" }
        }
        return text
    }

    /// The network status of a device connected to these networks: none is offline; a public network among them wins,
    /// since a VPN or other private adapter says nothing about the Wi-Fi the printer is on.
    public static func combineNetworks(_ connected: [NetworkStatus]) -> NetworkStatus {
        let all = connected.filter { $0 != .unknown && $0 != .offline }
        if all.isEmpty { return connected.contains(.unknown) ? .unknown : .offline }
        if all.contains(.publicNetwork) { return .publicNetwork }
        if all.contains(.domainNetwork) { return .domainNetwork }
        return .privateNetwork
    }

    // MARK: - The checks

    private static func rank(_ status: CheckStatus) -> Int {
        switch status {
        case .problem: return 0
        case .warning: return 1
        case .ok: return 2
        case .tip: return 3
        }
    }

    private static func counts(_ checks: [TroubleshootCheck]) -> [String] {
        let problems = checks.filter { $0.status == .problem }.count
        let warnings = checks.filter { $0.status == .warning }.count
        var parts = [String]()
        if problems > 0 { parts.append(problems == 1 ? "1 problem" : "\(problems) problems") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts
    }

    private static func computer(_ platform: AppPlatform) -> String {
        switch platform {
        case .windows: return "PC"
        case .ios: return "device"
        case .mac: return "Mac"
        }
    }

    private static func otherApps(_ platform: AppPlatform) -> String {
        platform == .ios ? "printing apps on other devices" : "other printing apps"
    }

    /// The system that searches the network, in the discovery check's more help.
    private static func searchingSystem(_ platform: AppPlatform) -> String {
        switch platform {
        case .windows: return "Windows"
        case .mac: return "macOS"
        case .ios: return "iOS"
        }
    }

    private static func failureCheck(_ failure: PrinterFailure, platform: AppPlatform) -> TroubleshootCheck {
        let name = failure.printerName
        guard let problem = failure.problem else {
            let reach = platform == .ios
                ? "It must be on the same network as this " + computer(platform) + "."
                : "It must be connected by its cable or to the same network as this " + computer(platform) + "."
            return TroubleshootCheck(
                id: "lastFailure", status: .warning, title: "Could not print to \(name)",
                detail: "Check that it is on, awake and connected.",
                more: joinSentences(failure.message, reach),
                actions: [.refresh])
        }
        return TroubleshootCheck(
            id: "lastFailure", status: problem.isError ? .problem : .warning, title: "\(problem.title): \(name)",
            detail: problem.advice,
            more: problem == PrinterFailure.busy
                ? "A printer works on one job at a time; \(otherApps(platform)) may be using it."
                : "",
            actions: [.refresh])
    }

    private static func networkCheck(_ snapshot: PrinterSnapshot) -> TroubleshootCheck? {
        let platform = snapshot.platform
        if platform == .ios { return phoneNetworkCheck(snapshot.network) }
        switch snapshot.network {
        case .offline:
            return TroubleshootCheck(
                id: "network", status: .problem, title: "Not connected to a network",
                detail: "Connect to the network the printer is on, then select Refresh.",
                more: "This \(computer(platform)) is not on a network, so network printers can't be found. "
                    + "Printers connected by USB are not affected.",
                actions: [.openNetworkSettings, .refresh])
        case .publicNetwork:
            return TroubleshootCheck(
                id: "network", status: .warning, title: "Network set to Public",
                detail: "Windows won't find network printers on a Public network.",
                more: "If this is your home or office network, set it to Private in network settings. You can also add "
                    + "the printer by its address.",
                actions: [.openNetworkSettings, .addByAddress])
        case .privateNetwork, .domainNetwork:
            return TroubleshootCheck(
                id: "network", status: .ok, title: "Connected to a private network",
                detail: "Network printers on this network can be found.", actions: [])
        case .unknown:
            return nil
        }
    }

    /// The iPhone's and iPad's network: Wi-Fi or a wired network, or none. iOS has no public or private networks.
    private static func phoneNetworkCheck(_ network: NetworkStatus) -> TroubleshootCheck? {
        switch network {
        case .offline:
            return TroubleshootCheck(
                id: "network", status: .problem, title: "Not connected to Wi-Fi",
                detail: "Join the printer's Wi-Fi network, then tap Refresh.",
                more: "Network printers are found only on Wi-Fi or a wired network.",
                actions: [.refresh])
        case .publicNetwork, .privateNetwork, .domainNetwork:
            return TroubleshootCheck(
                id: "network", status: .ok, title: "Connected to a local network",
                detail: "Network printers on this network can be found.", actions: [])
        case .unknown:
            return nil
        }
    }

    private static func localNetworkDeniedCheck() -> TroubleshootCheck {
        TroubleshootCheck(
            id: "localNetwork", status: .problem, title: "Local Network access is off",
            detail: "Turn on Local Network for Lazy Print in Settings.",
            more: "Without it, the app can't find or reach printers on your network. Printers appear as soon as it's on. "
                + "If it's on already, turn it off and on again.",
            actions: [.openAppSettings])
    }

    private static func spoolerCheck(_ status: ServiceStatus) -> TroubleshootCheck? {
        switch status {
        case .running:
            return TroubleshootCheck(
                id: "spooler", status: .ok, title: "Print spooler is on",
                detail: "The Print Spooler, which queues every print job, is on.", actions: [])
        case .starting:
            return TroubleshootCheck(
                id: "spooler", status: .warning, title: "Print spooler is starting",
                detail: "Wait a moment, then select Refresh.",
                more: "The Print Spooler, which queues every print job, is starting.",
                actions: [.refresh])
        case .stopped, .stopping, .paused:
            return TroubleshootCheck(
                id: "spooler", status: .problem, title: "Print spooler is not running",
                detail: "Restarting the PC usually starts it again.",
                more: "The Print Spooler, which queues every print job, is not running, so printers set up in Windows can't "
                    + "print. To start it now, someone with administrator rights can start Print Spooler in Services.",
                actions: [.refresh])
        case .disabled:
            return TroubleshootCheck(
                id: "spooler", status: .problem, title: "Print spooler is turned off",
                detail: "An administrator can set it to Automatic in Services.",
                more: "The Print Spooler, which queues every print job, is disabled, so printers set up in Windows can't print. "
                    + "Someone with administrator rights can set its startup type to Automatic in Services, then restart the PC.",
                actions: [.refresh])
        case .notInstalled:
            return TroubleshootCheck(
                id: "spooler", status: .problem, title: "Print spooler is missing",
                detail: "Network printers can still print straight to the printer.",
                more: "This copy of Windows has no Print Spooler service.",
                actions: [.addByAddress])
        case .unknown:
            return nil
        }
    }

    private static func discoveryCheck(_ snapshot: PrinterSnapshot) -> TroubleshootCheck? {
        if snapshot.discovery == .denied { return localNetworkDeniedCheck() }
        var detail = ""
        if let text = snapshot.discoveryDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            var trimmed = text
            while trimmed.hasSuffix(".") { trimmed.removeLast() }
            detail = " (\(trimmed))"
        }
        switch snapshot.discovery {
        case .searching:
            return TroubleshootCheck(
                id: "discovery", status: .ok, title: "Looking for network printers",
                detail: "Printers on the network appear as they answer.",
                more: "The search has just started.",
                actions: [.addByAddress])
        case .running:
            let found = snapshot.printers.filter { $0.route != .demo && $0.ippEndpoint != nil }.count
            let count: String
            switch found {
            case 0: count = "No network printer has been found on this network yet."
            case 1: count = "1 network printer found."
            default: count = "\(found) network printers found."
            }
            return TroubleshootCheck(
                id: "discovery", status: .ok, title: "Looking for network printers",
                detail: count,
                more: "A printer that doesn't appear can be added by its address.",
                actions: [.addByAddress])
        case .unavailable:
            return TroubleshootCheck(
                id: "discovery", status: .warning, title: "Network search is not working",
                detail: "You can still add a network printer by its address.",
                more: "\(searchingSystem(snapshot.platform)) could not search the network for printers\(detail).",
                actions: [.addByAddress, .refresh])
        case .unknown, .off, .denied:
            return nil
        }
    }

    /// The first problem the printer reports, as a check; the others are named in its more help. A paused printer has
    /// its own check.
    private static func printerCheck(_ printer: PrinterInfo) -> TroubleshootCheck? {
        let problems = printer.problems.filter { $0.title != IppProblemText.paused }
        guard let first = problems.first else { return nil }
        var detail = first.advice
        var more = ""
        // An unknown error carries the printer's own message, which can be long.
        if StatusLine.words(detail) > 15 {
            more = detail
            detail = IppProblemText.printerErrorAdvice
        }
        if problems.count > 1 {
            let others = "Also: " + problems.dropFirst().map { $0.title }.joined(separator: ", ") + "."
            more = more.isEmpty ? others : more + " " + others
        }
        return TroubleshootCheck(
            id: "printer:\(printer.id)", status: first.isError ? .problem : .warning,
            title: "\(first.title): \(printer.name)", detail: detail, more: more, actions: [.refresh])
    }

    private static func stuckJobsCheck(_ jobs: StuckJobs) -> TroubleshootCheck {
        let one = jobs.count == 1
        let waited = duration(jobs.oldestMinutes)
        let more = one
            ? "It has waited \(waited)." + (jobs.anyInError ? " It is in error." : "")
            : "The oldest has waited \(waited)." + (jobs.anyInError ? " One of them is in error, which holds up the rest." : "")
        return TroubleshootCheck(
            id: "stuckJobs:\(jobs.printerId)", status: jobs.anyInError ? .problem : .warning,
            title: one ? "1 job stuck on \(jobs.printerName)" : "\(jobs.count) jobs stuck on \(jobs.printerName)",
            detail: one ? "Clearing it lets new jobs print." : "Clearing them lets new jobs print.",
            more: more, actions: [.clearStuckJobs])
    }

    private static func pausedCheck(_ printer: PrinterInfo) -> TroubleshootCheck {
        TroubleshootCheck(
            id: "paused:\(printer.id)", status: .problem, title: "\(printer.name) is paused",
            detail: "Resume it to let its jobs print.",
            more: "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer.",
            actions: [.resumePrinter])
    }

    private static func duration(_ minutes: Int) -> String {
        switch minutes {
        case ..<1: return "less than a minute"
        case 1: return "1 minute"
        case ..<120: return "\(minutes) minutes"
        case ..<2880: return "\(minutes / 60) hours"
        default: return "\(minutes / 1440) days"
        }
    }

    private static func tips(_ platform: AppPlatform) -> [TroubleshootCheck] {
        var tips = [TroubleshootCheck]()
        switch platform {
        case .ios:
            tips.append(TroubleshootCheck(
                id: "networkPrinter", status: .tip, title: "Printer on the same Wi-Fi?",
                detail: "This device and the printer must be on the same Wi-Fi.",
                more: "Guest networks and some VPNs hide printers. Try adding the printer by its address.",
                actions: [.addByAddress]))
            tips.append(TroubleshootCheck(
                id: "localNetworkAccess", status: .tip, title: "Local Network allowed?",
                detail: "Lazy Print needs Local Network access to find printers.",
                more: "Turn it on for Lazy Print in Settings. If it's on already, turn it off and on again.",
                actions: [.openAppSettings]))
            tips.append(TroubleshootCheck(
                id: "airPrint", status: .tip, title: "Does it support AirPrint?",
                detail: "Lazy Print prints to AirPrint and other driverless printers.",
                more: "A printer that needs its own driver doesn't appear, and iPhone and iPad can't use USB printers. "
                    + "The printer's manual says whether it supports AirPrint.",
                actions: []))
        case .windows:
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Connected by USB?",
                detail: "Connect it directly and use the maker's driver or the one Windows offers.",
                more: "Windows lists a USB printer only after its driver is installed. Get it from the maker's website, "
                    + "or let Windows install the one it offers, then select Refresh. Printer settings show whether "
                    + "Windows sees it.",
                actions: [.openPrinterSettings, .refresh]))
        case .mac:
            tips.append(TroubleshootCheck(
                id: "usb", status: .tip, title: "Connected by USB?",
                detail: "Connect it directly and add it in Printers & Scanners.",
                more: "macOS sets up most USB printers by itself. If Printers & Scanners doesn't show it either, "
                    + "macOS doesn't see it.",
                actions: [.openPrinterSettings, .refresh]))
        }
        let refresh = platform == .ios ? "tap" : "select"
        tips.append(TroubleshootCheck(
            id: "asleep", status: .tip, title: "Printer asleep?",
            detail: "Press any button on it, then \(refresh) Refresh.",
            more: "A printer in sleep mode can stop answering on the network until it wakes.",
            actions: [.refresh]))
        let device = computer(platform)
        tips.append(TroubleshootCheck(
            id: "wifiDirect", status: .tip, title: "On the printer's own Wi-Fi?",
            detail: "A printer's own Wi-Fi is another network.",
            more: "A printer's own Wi-Fi (Wi-Fi Direct) hides it from the network this \(device) uses. Join the printer "
                + "to your Wi-Fi, or this \(device) to its network.",
            actions: platform == .ios ? [] : [.openNetworkSettings]))
        tips.append(TroubleshootCheck(
            id: "otherApps", status: .tip, title: "Still not listed?",
            detail: "Restart the printer and close other printing apps.",
            more: "Turn the printer off and on. Close \(otherApps(platform)). Some printers print only through their maker's app.",
            actions: [.refresh]))
        return tips
    }

    /// The first text as a sentence, then the second; the first may be missing.
    private static func joinSentences(_ first: String?, _ second: String) -> String {
        var head = first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if head.isEmpty { return second }
        if let last = head.last, !".!?".contains(last) { head += "." }
        return head + " " + second
    }
}
