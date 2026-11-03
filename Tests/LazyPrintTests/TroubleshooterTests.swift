import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/TroubleshooterTests.cs: the same cases.
// Swift-only case: CancellationError and a plain error in PrinterFailure.from (C# has OperationCanceledException and PrintException).

final class TroubleshooterTests: XCTestCase {
    private let platforms: [AppPlatform] = [.windows, .mac, .ios]

    private let demo = PrinterInfo(id: PrinterMerge.demoId, name: PrinterMerge.demoName, model: nil, address: nil,
                                   route: .demo, ippEndpoint: nil, isDefault: false, state: .idle, problems: [], supplies: [])

    private func queue(_ name: String, _ problems: [PrinterProblem] = []) -> PrinterInfo {
        PrinterInfo(id: "system:" + name, name: name, model: nil, address: nil, route: .system, ippEndpoint: nil,
                    isDefault: false, state: .idle, problems: problems, supplies: [])
    }

    private var laserJet: PrinterInfo { queue("HP LaserJet") }

    private func networkPrinter(_ name: String) -> PrinterInfo {
        let service = IppService(id: "ipp:\(name)", instanceName: name, secure: false, hostName: nil,
                                 addresses: ["192.168.1.20"], port: 631, textAttributes: ["ty=Test"])
        return PrinterInfo(id: "ipp:" + name, name: name, model: nil, address: "192.168.1.20", route: .ipp,
                           ippEndpoint: IppEndpoint.choose([service])[0], isDefault: false, state: .idle, problems: [], supplies: [])
    }

    private let outOfPaper = PrinterProblem(title: IppProblemText.outOfPaper, advice: IppProblemText.outOfPaperAdvice, isError: true)
    private let inkLow = PrinterProblem(title: IppProblemText.inkLow, advice: IppProblemText.inkLowAdvice, isError: false)
    private let paused = PrinterProblem(title: IppProblemText.paused, advice: IppProblemText.pausedAdvice, isError: true)

    private func ids(_ checks: [TroubleshootCheck]) -> [String] { checks.map(\.id) }

    private func check(_ checks: [TroubleshootCheck], _ id: String) -> TroubleshootCheck {
        let found = checks.filter { $0.id == id }
        XCTAssertEqual(found.count, 1, id)
        return found[0]
    }

    private func with(_ snapshot: PrinterSnapshot, _ change: (inout PrinterSnapshot) -> Void) -> PrinterSnapshot {
        var copy = snapshot
        change(&copy)
        return copy
    }

    private func make(_ id: String, _ status: CheckStatus, _ title: String, _ detail: String, _ more: String,
                      _ actions: [TroubleshootAction]) -> TroubleshootCheck {
        TroubleshootCheck(id: id, status: status, title: title, detail: detail, more: more, actions: actions)
    }

    /// A PC where everything that can be checked is fine.
    private func healthyWindows() -> PrinterSnapshot {
        PrinterSnapshot(platform: .windows, printers: [demo, networkPrinter("HP LaserJet")], network: .privateNetwork,
                        spooler: .running, discovery: .running)
    }

    /// A PC where most things are wrong.
    private func troubledWindows() -> PrinterSnapshot {
        PrinterSnapshot(
            platform: .windows,
            printers: [demo, queue("Brother", [outOfPaper, inkLow]), queue("Epson", [paused])],
            network: .publicNetwork, spooler: .disabled, discovery: .unavailable, discoveryDetail: "Access is denied.",
            manualHosts: [ManualHostStatus(address: "192.168.1.50", listed: false, problem: "No printer answered at 192.168.1.50."),
                          ManualHostStatus(address: "10.0.0.2", listed: true)],
            stuckJobs: [StuckJobs(printerId: "system:Brother", printerName: "Brother", count: 3, oldestMinutes: 45, anyInError: false)],
            lastFailure: PrinterFailure.from(printerName: "Brother", error: PrintError.busy))
    }

    // MARK: - iPhone and iPad (never produced on Windows)

    /// A phone on Wi-Fi that found a network printer.
    private func healthyPhone() -> PrinterSnapshot {
        PrinterSnapshot(platform: .ios, printers: [demo, networkPrinter("HP LaserJet")], network: .privateNetwork, discovery: .running)
    }

    /// A phone off Wi-Fi, without Local Network access, with an address that does not answer.
    private func troubledPhone() -> PrinterSnapshot {
        PrinterSnapshot(
            platform: .ios, printers: [demo], network: .offline, discovery: .denied,
            manualHosts: [ManualHostStatus(address: "192.168.1.50", listed: false, problem: "No printer answered at 192.168.1.50."),
                          ManualHostStatus(address: "10.0.0.2", listed: true)],
            lastFailure: PrinterFailure(printerName: "Office MFP", message: "Can't reach Office MFP: no answer in time"))
    }

    func test_healthyWindows_showsWhatIsFineThenTheTips() {
        let snapshot = healthyWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "spooler", "discovery", "usb", "asleep", "wifiDirect", "otherApps"])
        XCTAssertEqual(checks.map(\.status), [.ok, .ok, .ok, .tip, .tip, .tip, .tip])
        XCTAssertEqual(Troubleshooter.headline(snapshot), "1 printer found")
        XCTAssertEqual(Troubleshooter.summary(checks), "Nothing here stops printers from appearing. The tips below cover the usual causes.")
    }

    func test_problemsComeFirst_thenWarnings_thenTips() {
        let snapshot = troubledWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["lastFailure", "spooler", "printer:system:Brother", "paused:system:Epson", "network", "discovery",
                                     "stuckJobs:system:Brother", "manualHost:192.168.1.50", "usb", "asleep", "wifiDirect", "otherApps"])
        XCTAssertEqual(checks.map(\.status), [.problem, .problem, .problem, .problem, .warning, .warning, .warning, .warning,
                                              .tip, .tip, .tip, .tip])
        XCTAssertEqual(Troubleshooter.headline(snapshot), "2 printers found")
        XCTAssertEqual(Troubleshooter.summary(checks), "4 problems and 4 warnings found.")
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "2 printers found \u{00B7} 4 problems, 4 warnings")
    }

    func test_overview_isOneLine() {
        let healthy = healthyWindows()
        XCTAssertEqual(Troubleshooter.overview(healthy, checks: Troubleshooter.diagnose(healthy)), "1 printer found")
        let publicNetwork = PrinterSnapshot(printers: [demo], network: .publicNetwork)
        XCTAssertEqual(Troubleshooter.overview(publicNetwork, checks: Troubleshooter.diagnose(publicNetwork)),
                       "No printer found \u{00B7} 1 warning")
        let offline = PrinterSnapshot(network: .offline)
        XCTAssertEqual(Troubleshooter.overview(offline, checks: Troubleshooter.diagnose(offline)), "No printer found \u{00B7} 1 problem")
    }

    /// Every check the fixtures make, on every platform.
    private func everyCheck() -> [TroubleshootCheck] {
        var snapshots = [healthyWindows(), troubledWindows(), healthyPhone(), troubledPhone()]
        for platform in platforms {
            for service in ServiceStatus.allCases { snapshots.append(with(healthyWindows()) { $0.platform = platform; $0.spooler = service }) }
            for network in NetworkStatus.allCases { snapshots.append(with(healthyWindows()) { $0.platform = platform; $0.network = network }) }
            for discovery in DiscoveryStatus.allCases {
                snapshots.append(with(healthyWindows()) { $0.platform = platform; $0.discovery = discovery })
                snapshots.append(PrinterSnapshot(platform: platform, discovery: discovery, discoveryDetail: "NoSuchRecord."))
            }
            snapshots.append(with(troubledWindows()) { $0.platform = platform })
            snapshots.append(PrinterSnapshot(platform: platform))
        }
        let errors: [PrintError] = [
            .badResponse, .unreachable(name: "Office MFP", reason: "no answer"), .refused(status: 0x0400, detail: ""),
            .needsDriver, .busy, .certificateChanged, .needsSignIn,
            .noPrinter,
        ]
        for error in errors {
            for platform in platforms {
                snapshots.append(PrinterSnapshot(platform: platform, lastFailure: PrinterFailure.from(printerName: "Office MFP", error: error)))
            }
        }
        for verdict in [IppTrustVerdict.unknown, .changed, .invalid] {
            let certificate = IppCertificateError(verdict: verdict, deviceName: "Office MFP", deviceUuid: nil,
                                                  authority: "192.168.1.9:631", fingerprint: "ab", subject: "CN=x")
            snapshots.append(PrinterSnapshot(lastFailure: PrinterFailure.from(printerName: "Office MFP", error: certificate)))
        }
        let problems = [
            outOfPaper, inkLow, PrinterProblem(title: IppProblemText.offline, advice: IppProblemText.offlineAdvice, isError: true),
            PrinterProblem(title: IppProblemText.printerError,
                           advice: "The printer has a long message of its own that says so in more than fifteen words.", isError: true),
        ]
        for problem in problems { snapshots.append(PrinterSnapshot(printers: [queue("Office", [problem, inkLow])])) }
        snapshots.append(PrinterSnapshot(stuckJobs: [
            StuckJobs(printerId: "a", printerName: "Office", count: 1, oldestMinutes: 0, anyInError: true),
            StuckJobs(printerId: "b", printerName: "Home", count: 5, oldestMinutes: 3000, anyInError: false),
        ]))
        return snapshots.flatMap { Troubleshooter.diagnose($0) }
    }

    func test_everyCheck_hasAShortTitle_andAOneLineDetail_theRestIsMoreHelp() {
        for check in everyCheck() {
            XCTAssertTrue((1...6).contains(StatusLine.words(check.title)), check.title)
            XCTAssertTrue((1...15).contains(StatusLine.words(check.detail)), check.detail)
            XCTAssertEqual(check.fullDetail, check.more.isEmpty ? check.detail : "\(check.detail) \(check.more)")
            XCTAssertFalse(check.more.contains(check.detail), check.id)
        }
        for action in TroubleshootAction.allCases {
            for platform in platforms {
                XCTAssertTrue((1...3).contains(StatusLine.words(Troubleshooter.label(action, platform: platform))), "\(action)")
            }
        }
    }

    func test_everyCheck_hasAStableIdAndAtMostThreeActions() {
        for check in everyCheck() {
            XCTAssertFalse(check.id.isEmpty)
            XCTAssertTrue((0...3).contains(check.actions.count), check.id)
        }
    }

    func test_nothingKnown_onlyTheTips() {
        XCTAssertEqual(ids(Troubleshooter.diagnose(PrinterSnapshot(platform: .windows))), ["usb", "asleep", "wifiDirect", "otherApps"])
        XCTAssertEqual(ids(Troubleshooter.diagnose(PrinterSnapshot(platform: .mac))), ["usb", "asleep", "wifiDirect", "otherApps"])
    }

    func test_windows_tips() {
        let checks = Troubleshooter.diagnose(healthyWindows())
        XCTAssertEqual(check(checks, "usb"), make(
            "usb", .tip, "Connected by USB?",
            "Connect it directly and use the maker's driver or the one Windows offers.",
            "Windows lists a USB printer only after its driver is installed. Get it from the maker's website, or let "
                + "Windows install the one it offers, then select Refresh. Printer settings show whether Windows sees it.",
            [.openPrinterSettings, .refresh]))
        XCTAssertEqual(check(checks, "asleep"), make(
            "asleep", .tip, "Printer asleep?", "Press any button on it, then select Refresh.",
            "A printer in sleep mode can stop answering on the network until it wakes.", [.refresh]))
        let wifi = check(checks, "wifiDirect")
        XCTAssertEqual(wifi.title, "On the printer's own Wi-Fi?")
        XCTAssertEqual(wifi.detail, "A printer's own Wi-Fi is another network.")
        XCTAssertEqual(wifi.more, "A printer's own Wi-Fi (Wi-Fi Direct) hides it from the network this PC uses. Join the printer to "
                       + "your Wi-Fi, or this PC to its network.")
        XCTAssertEqual(wifi.actions, [.openNetworkSettings])
        let other = check(checks, "otherApps")
        XCTAssertEqual(other.title, "Still not listed?")
        XCTAssertEqual(other.detail, "Restart the printer and close other printing apps.")
        XCTAssertEqual(other.more, "Turn the printer off and on. Close other printing apps. Some printers print only through their "
                       + "maker's app.")
    }

    func test_mac_tips_andNoWindowsChecks() {
        let snapshot = with(troubledWindows()) { $0.platform = .mac; $0.discovery = .running }
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertFalse(ids(checks).contains("spooler"))
        let usb = check(checks, "usb")
        XCTAssertEqual(usb.detail, "Connect it directly and add it in Printers & Scanners.")
        XCTAssertEqual(usb.more, "macOS sets up most USB printers by itself. If Printers & Scanners doesn't show it either, macOS "
                       + "doesn't see it.")
        XCTAssertEqual(usb.actions, [.openPrinterSettings, .refresh])
        XCTAssertTrue(check(checks, "wifiDirect").more.contains("this Mac"))
    }

    func test_phone_healthy_showsWhatIsFineThenItsTips() {
        let snapshot = healthyPhone()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "discovery", "networkPrinter", "localNetworkAccess", "airPrint", "asleep",
                                     "wifiDirect", "otherApps"])
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "1 printer found")
        let network = check(checks, "network")
        XCTAssertEqual(network.title, "Connected to a local network")
        XCTAssertEqual(network.detail, "Network printers on this network can be found.")
        XCTAssertEqual(check(checks, "networkPrinter"), make(
            "networkPrinter", .tip, "Printer on the same Wi-Fi?",
            "This device and the printer must be on the same Wi-Fi.",
            "Guest networks and some VPNs hide printers. Try adding the printer by its address.", [.addByAddress]))
        XCTAssertEqual(check(checks, "localNetworkAccess"), make(
            "localNetworkAccess", .tip, "Local Network allowed?",
            "Lazy Print needs Local Network access to find printers.",
            "Turn it on for Lazy Print in Settings. If it's on already, turn it off and on again.", [.openAppSettings]))
        XCTAssertEqual(check(checks, "airPrint"), make(
            "airPrint", .tip, "Does it support AirPrint?",
            "Lazy Print prints to AirPrint and other driverless printers.",
            "A printer that needs its own driver doesn't appear, and iPhone and iPad can't use USB printers. The "
                + "printer's manual says whether it supports AirPrint.", []))
        XCTAssertEqual(check(checks, "asleep").detail, "Press any button on it, then tap Refresh.")
        XCTAssertTrue(check(checks, "wifiDirect").actions.isEmpty)
        XCTAssertEqual(check(checks, "otherApps").more, "Turn the printer off and on. Close printing apps on other devices. Some "
                       + "printers print only through their maker's app.")
    }

    func test_phone_troubled_localNetworkAccessOffComesFirstWithSettings() {
        let snapshot = troubledPhone()
        let checks = Troubleshooter.diagnose(snapshot)
        XCTAssertEqual(ids(checks), ["network", "localNetwork", "lastFailure", "manualHost:192.168.1.50", "networkPrinter",
                                     "localNetworkAccess", "airPrint", "asleep", "wifiDirect", "otherApps"])
        XCTAssertEqual(Troubleshooter.overview(snapshot, checks: checks), "No printer found \u{00B7} 2 problems, 2 warnings")
        XCTAssertEqual(check(checks, "localNetwork"), make(
            "localNetwork", .problem, "Local Network access is off",
            "Turn on Local Network for Lazy Print in Settings.",
            "Without it, the app can't find or reach printers on your network. Printers appear as soon as it's on. "
                + "If it's on already, turn it off and on again.", [.openAppSettings]))
        XCTAssertEqual(check(checks, "network"), make(
            "network", .problem, "Not connected to Wi-Fi",
            "Join the printer's Wi-Fi network, then tap Refresh.",
            "Network printers are found only on Wi-Fi or a wired network.", [.refresh]))
        XCTAssertEqual(check(checks, "lastFailure").more,
                       "Can't reach Office MFP: no answer in time. It must be on the same network as this device.")
        XCTAssertFalse(ids(checks).contains("manualHost:10.0.0.2"))
    }

    func test_phone_searchStates_sayWhatIOSDoes() {
        func detail(_ snapshot: PrinterSnapshot) -> String { check(Troubleshooter.diagnose(snapshot), "discovery").fullDetail }
        XCTAssertEqual(detail(with(healthyPhone()) { $0.discovery = .searching }),
                       "Printers on the network appear as they answer. The search has just started.")
        let unavailable = check(Troubleshooter.diagnose(with(healthyPhone()) {
            $0.discovery = .unavailable
            $0.discoveryDetail = "NoSuchRecord."
        }), "discovery")
        XCTAssertEqual(unavailable.status, .warning)
        XCTAssertEqual(unavailable.title, "Network search is not working")
        XCTAssertEqual(unavailable.more, "iOS could not search the network for printers (NoSuchRecord).")
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyPhone()) { $0.discovery = .off })).contains("discovery"))
        let denied = Troubleshooter.diagnose(with(healthyPhone()) { $0.discovery = .denied })
        XCTAssertFalse(ids(denied).contains("discovery"))
        XCTAssertTrue(ids(denied).contains("localNetwork"))
        // iOS has no public networks: any local network is fine; an unknown one has no check.
        XCTAssertEqual(check(Troubleshooter.diagnose(with(healthyPhone()) { $0.network = .publicNetwork }), "network").status, .ok)
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyPhone()) { $0.network = .unknown })).contains("network"))
    }

    func test_phone_neverOffersTheComputersActions_andTheComputersNeverOfferSettings() {
        let computerActions: Set<TroubleshootAction> = [.openPrinterSettings, .openNetworkSettings]
        var phone = [TroubleshootCheck]()
        for snapshot in [healthyPhone(), troubledPhone()] {
            for network in NetworkStatus.allCases {
                for discovery in DiscoveryStatus.allCases {
                    phone += Troubleshooter.diagnose(with(snapshot) { $0.network = network; $0.discovery = discovery })
                }
            }
        }
        XCTAssertFalse(phone.contains { !computerActions.isDisjoint(with: $0.actions) })
        // Windows and the Mac never report denied access; the only check that offers the phone's Settings is the iPhone's tip.
        XCTAssertFalse(Troubleshooter.diagnose(troubledWindows()).contains { $0.actions.contains(.openAppSettings) })
        XCTAssertFalse(Troubleshooter.diagnose(with(healthyWindows()) { $0.platform = .mac }).contains { $0.actions.contains(.openAppSettings) })
    }

    // MARK: - The last failure

    func test_busyPrinter_saysToCloseOtherApps() {
        XCTAssertEqual(check(Troubleshooter.diagnose(troubledWindows()), "lastFailure"), make(
            "lastFailure", .problem, "Printer busy: Brother",
            "Wait until it has finished, then print again.",
            "A printer works on one job at a time; other printing apps may be using it.", [.refresh]))
    }

    func test_failureWithoutProblem_isAWarningWithTheMessage() {
        let snapshot = PrinterSnapshot(lastFailure: PrinterFailure(printerName: "Office MFP", message: "Can't reach Office MFP: no answer in time"))
        let failure = check(Troubleshooter.diagnose(snapshot), "lastFailure")
        XCTAssertEqual(failure.status, .warning)
        XCTAssertEqual(failure.title, "Could not print to Office MFP")
        XCTAssertEqual(failure.detail, "Check that it is on, awake and connected.")
        XCTAssertEqual(failure.more, "Can't reach Office MFP: no answer in time. It must be connected by its cable or to the same "
                       + "network as this PC.")
        let mac = check(Troubleshooter.diagnose(with(snapshot) { $0.platform = .mac }), "lastFailure")
        XCTAssertTrue(mac.more.hasSuffix("to the same network as this Mac."))
    }

    func test_failureWithAProblem_usesItsTextAndSeverity() {
        let error = check(Troubleshooter.diagnose(PrinterSnapshot(lastFailure: PrinterFailure(
            printerName: "Office", message: "x",
            problem: PrinterProblem(title: "Cover open", advice: "Close the cover or door, then press Resume.", isError: true)))),
                          "lastFailure")
        XCTAssertEqual(error.status, .problem)
        XCTAssertEqual(error.title, "Cover open: Office")
        XCTAssertEqual(error.detail, "Close the cover or door, then press Resume.")
        XCTAssertEqual(error.more, "")
        let warning = check(Troubleshooter.diagnose(PrinterSnapshot(lastFailure: PrinterFailure(
            printerName: "Office", message: "x",
            problem: PrinterProblem(title: "Ink low", advice: "Order a new cartridge soon.", isError: false)))),
                            "lastFailure")
        XCTAssertEqual(warning.status, .warning)
    }

    func test_failureFrom_mapsPrintErrors() throws {
        XCTAssertEqual(PrinterFailure.from(printerName: "Acme", error: PrintError.badResponse),
                       PrinterFailure(printerName: "Acme", message: "The printer's answer could not be read"))
        XCTAssertEqual(PrinterFailure.from(printerName: "Acme", error: PrintError.unreachable(name: "Acme", reason: "gone")),
                       PrinterFailure(printerName: "Acme", message: "Can't reach Acme: gone"))
        XCTAssertEqual(PrinterFailure.from(printerName: "Acme", error: PrintError.refused(status: 0x0507, detail: "Out of paper")),
                       PrinterFailure(printerName: "Acme", message: "Out of paper"))

        let busy = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: PrintError.busy))
        XCTAssertEqual(busy.message, "The printer is busy")
        XCTAssertEqual(busy.problem?.title, "Printer busy")
        XCTAssertEqual(busy.problem?.isError, true)
        let driver = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: PrintError.needsDriver))
        XCTAssertEqual(driver.problem?.title, "Needs its driver")
        XCTAssertEqual(driver.problem?.advice, "Install the maker's driver, then print again.")
        let signIn = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: PrintError.needsSignIn))
        XCTAssertEqual(signIn.problem?.title, "Needs a sign-in")
        XCTAssertEqual(signIn.problem?.advice, "Lazy Print can't sign in to printers yet.")
        let changed = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: PrintError.certificateChanged))
        XCTAssertEqual(changed.problem?.title, "Certificate changed")
        XCTAssertEqual(changed.problem?.isError, true)

        // A page that could not be prepared says nothing about reaching the printer.
        XCTAssertNil(PrinterFailure.from(printerName: "Acme", error: PrintError.badRaster(line: 1, length: 2, expected: 3)))
        // Nor does a file that can't be read.
        XCTAssertNil(PrinterFailure.from(printerName: "Acme", error: PrintError.unreadable(DocumentText.unreadable)))
    }

    func test_failureFrom_mapsCertificateErrors() throws {
        func error(_ verdict: IppTrustVerdict) -> IppCertificateError {
            IppCertificateError(verdict: verdict, deviceName: "Acme", deviceUuid: nil, authority: "192.168.1.9:631",
                                fingerprint: "ab", subject: "CN=Acme")
        }
        let changed = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: error(.changed)))
        XCTAssertEqual(changed.problem?.title, "Certificate changed")
        XCTAssertEqual(changed.problem?.advice, "Check the printer, then trust it again.")
        XCTAssertEqual(changed.problem?.isError, true)
        XCTAssertTrue(changed.message.contains("has changed since you trusted it"))
        for verdict in [IppTrustVerdict.unknown, .invalid] {
            let untrusted = try XCTUnwrap(PrinterFailure.from(printerName: "Acme", error: error(verdict)))
            XCTAssertEqual(untrusted.problem?.title, "Certificate not trusted")
            XCTAssertEqual(untrusted.problem?.isError, false)
        }
        let failure = check(Troubleshooter.diagnose(PrinterSnapshot(lastFailure: PrinterFailure.from(printerName: "Acme", error: error(.unknown)))),
                            "lastFailure")
        XCTAssertEqual(failure.status, .warning)
        XCTAssertEqual(failure.title, "Certificate not trusted: Acme")
    }

    func test_failureFrom_ignoresCancellation() {
        XCTAssertNil(PrinterFailure.from(printerName: "Acme", error: CancellationError()))
        let other = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        XCTAssertEqual(PrinterFailure.from(printerName: "Acme", error: other), PrinterFailure(printerName: "Acme", message: "boom"))
    }

    // MARK: - Network, spooler, search

    func test_network() {
        let offline = check(Troubleshooter.diagnose(with(healthyWindows()) { $0.network = .offline }), "network")
        XCTAssertEqual(offline.status, .problem)
        XCTAssertEqual(offline.title, "Not connected to a network")
        XCTAssertEqual(offline.detail, "Connect to the network the printer is on, then select Refresh.")
        XCTAssertEqual(offline.more, "This PC is not on a network, so network printers can't be found. Printers connected by USB are "
                       + "not affected.")
        XCTAssertEqual(offline.actions, [.openNetworkSettings, .refresh])

        let publicNetwork = check(Troubleshooter.diagnose(with(healthyWindows()) { $0.network = .publicNetwork }), "network")
        XCTAssertEqual(publicNetwork.status, .warning)
        XCTAssertEqual(publicNetwork.title, "Network set to Public")
        XCTAssertEqual(publicNetwork.detail, "Windows won't find network printers on a Public network.")
        XCTAssertEqual(publicNetwork.more, "If this is your home or office network, set it to Private in network settings. You can also add "
                       + "the printer by its address.")
        XCTAssertEqual(publicNetwork.actions, [.openNetworkSettings, .addByAddress])

        for status in [NetworkStatus.privateNetwork, .domainNetwork] {
            let ok = check(Troubleshooter.diagnose(with(healthyWindows()) { $0.network = status }), "network")
            XCTAssertEqual(ok.status, .ok)
            XCTAssertEqual(ok.title, "Connected to a private network")
        }
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.network = .unknown })).contains("network"))
    }

    func test_spooler() {
        let cases: [(ServiceStatus, CheckStatus, String)] = [
            (.running, .ok, "Print spooler is on"),
            (.starting, .warning, "Print spooler is starting"),
            (.stopped, .problem, "Print spooler is not running"),
            (.stopping, .problem, "Print spooler is not running"),
            (.paused, .problem, "Print spooler is not running"),
            (.disabled, .problem, "Print spooler is turned off"),
            (.notInstalled, .problem, "Print spooler is missing"),
        ]
        for (service, status, title) in cases {
            let spooler = check(Troubleshooter.diagnose(with(healthyWindows()) { $0.spooler = service }), "spooler")
            XCTAssertEqual(spooler.status, status, "\(service)")
            XCTAssertEqual(spooler.title, title, "\(service)")
            if service != .notInstalled { XCTAssertTrue(spooler.fullDetail.contains("Print Spooler"), "\(service)") }
        }
    }

    func test_spooler_unknownHasNoCheck_andOnlyWindowsHasOne() {
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.spooler = .unknown })).contains("spooler"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.platform = .mac })).contains("spooler"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.platform = .ios })).contains("spooler"))
    }

    func test_disabledSpooler_saysHowToTurnItOnWithoutDoingIt() {
        let spooler = check(Troubleshooter.diagnose(with(healthyWindows()) { $0.spooler = .disabled }), "spooler")
        XCTAssertEqual(spooler.detail, "An administrator can set it to Automatic in Services.")
        XCTAssertEqual(spooler.more, "The Print Spooler, which queues every print job, is disabled, so printers set up in Windows can't "
                       + "print. Someone with administrator rights can set its startup type to Automatic in Services, then "
                       + "restart the PC.")
        XCTAssertEqual(spooler.actions, [.refresh])
        XCTAssertEqual(check(Troubleshooter.diagnose(with(healthyWindows()) { $0.spooler = .notInstalled }), "spooler").actions,
                       [.addByAddress])
    }

    func test_networkSearch() {
        func detail(_ snapshot: PrinterSnapshot) -> String { check(Troubleshooter.diagnose(snapshot), "discovery").fullDetail }
        XCTAssertEqual(detail(healthyWindows()), "1 network printer found. A printer that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(with(healthyWindows()) { $0.printers = [demo, laserJet] }),
                       "No network printer has been found on this network yet. A printer that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(with(healthyWindows()) { $0.printers = [demo, networkPrinter("A"), networkPrinter("B")] }),
                       "2 network printers found. A printer that doesn't appear can be added by its address.")
        XCTAssertEqual(detail(with(healthyWindows()) { $0.discovery = .searching }),
                       "Printers on the network appear as they answer. The search has just started.")
        let running = check(Troubleshooter.diagnose(healthyWindows()), "discovery")
        XCTAssertEqual(running.status, .ok)
        XCTAssertEqual(running.title, "Looking for network printers")
        XCTAssertEqual(running.actions, [.addByAddress])

        let unavailable = check(Troubleshooter.diagnose(troubledWindows()), "discovery")
        XCTAssertEqual(unavailable.status, .warning)
        XCTAssertEqual(unavailable.title, "Network search is not working")
        XCTAssertEqual(unavailable.detail, "You can still add a network printer by its address.")
        XCTAssertEqual(unavailable.more, "Windows could not search the network for printers (Access is denied).")
        XCTAssertEqual(unavailable.actions, [.addByAddress, .refresh])
        let mac = check(Troubleshooter.diagnose(with(troubledWindows()) { $0.platform = .mac }), "discovery")
        XCTAssertTrue(mac.more.hasPrefix("macOS could not search"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.discovery = .off })).contains("discovery"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(with(healthyWindows()) { $0.discovery = .unknown })).contains("discovery"))
    }

    // MARK: - Printers

    func test_printerProblems_areChecksNamedByThePrinter() {
        let checks = Troubleshooter.diagnose(PrinterSnapshot(printers: [demo, queue("HP LaserJet", [outOfPaper, inkLow]), queue("Epson", [inkLow])]))
        XCTAssertEqual(check(checks, "printer:system:HP LaserJet"), make(
            "printer:system:HP LaserJet", .problem, "Out of paper: HP LaserJet",
            "Load paper in the tray, then press Resume.", "Also: Ink low.", [.refresh]))
        let low = check(checks, "printer:system:Epson")
        XCTAssertEqual(low.status, .warning)
        XCTAssertEqual(low.title, "Ink low: Epson")
        XCTAssertEqual(low.detail, "Order a new cartridge soon.")
        XCTAssertEqual(low.more, "")
        XCTAssertFalse(ids(checks).contains("printer:demo"))
        XCTAssertFalse(ids(Troubleshooter.diagnose(PrinterSnapshot(printers: [laserJet]))).contains("printer:system:Nobody"))
    }

    func test_aLongPrinterMessage_movesToMoreHelp() {
        let message = "The printer has a long message of its own that says so in more than fifteen words."
        let long = check(Troubleshooter.diagnose(PrinterSnapshot(printers: [
            queue("Office", [PrinterProblem(title: IppProblemText.printerError, advice: message, isError: true)]),
        ])), "printer:system:Office")
        XCTAssertEqual(long.detail, IppProblemText.printerErrorAdvice)
        XCTAssertEqual(long.more, message)
    }

    func test_aPausedPrinter_hasItsOwnCheckWithResume() {
        let checks = Troubleshooter.diagnose(PrinterSnapshot(printers: [queue("Epson", [paused, inkLow])]))
        XCTAssertEqual(check(checks, "paused:system:Epson"), make(
            "paused:system:Epson", .problem, "Epson is paused",
            "Resume it to let its jobs print.",
            "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer.", [.resumePrinter]))
        // The pause is not repeated in the printer's problems.
        XCTAssertEqual(check(checks, "printer:system:Epson").title, "Ink low: Epson")
        XCTAssertFalse(ids(Troubleshooter.diagnose(PrinterSnapshot(printers: [queue("Epson", [paused])]))).contains("printer:system:Epson"))
    }

    func test_stuckJobs_areCountedAndCanBeCleared() {
        let checks = Troubleshooter.diagnose(PrinterSnapshot(stuckJobs: [
            StuckJobs(printerId: "system:HP", printerName: "HP LaserJet", count: 3, oldestMinutes: 45, anyInError: false),
            StuckJobs(printerId: "system:Epson", printerName: "Epson", count: 1, oldestMinutes: 200, anyInError: true),
            StuckJobs(printerId: "x", printerName: "Gone", count: 0, oldestMinutes: 0, anyInError: false),
        ]))
        XCTAssertEqual(check(checks, "stuckJobs:system:HP"), make(
            "stuckJobs:system:HP", .warning, "3 jobs stuck on HP LaserJet",
            "Clearing them lets new jobs print.", "The oldest has waited 45 minutes.", [.clearStuckJobs]))
        XCTAssertEqual(check(checks, "stuckJobs:system:Epson"), make(
            "stuckJobs:system:Epson", .problem, "1 job stuck on Epson",
            "Clearing it lets new jobs print.", "It has waited 3 hours. It is in error.", [.clearStuckJobs]))
        XCTAssertFalse(ids(checks).contains("stuckJobs:x"))
    }

    func test_stuckJobs_sayHowLongTheOldestWaited() {
        let cases: [(Int, String)] = [(5, "5 minutes"), (119, "119 minutes"), (120, "2 hours"), (3000, "2 days")]
        for (minutes, waited) in cases {
            let jobs = StuckJobs(printerId: "a", printerName: "HP", count: 2, oldestMinutes: minutes, anyInError: false)
            XCTAssertEqual(check(Troubleshooter.diagnose(PrinterSnapshot(stuckJobs: [jobs])), "stuckJobs:a").more,
                           "The oldest has waited \(waited).")
        }
    }

    func test_stuckJobs_aJobThatIsPrintingNowIsNotStuck() {
        let checks = Troubleshooter.diagnose(PrinterSnapshot(stuckJobs: [
            StuckJobs(printerId: "a", printerName: "HP", count: 1, oldestMinutes: 0, anyInError: false),
            StuckJobs(printerId: "b", printerName: "Epson", count: 2, oldestMinutes: 4, anyInError: false),
            StuckJobs(printerId: "c", printerName: "Canon", count: 1, oldestMinutes: 0, anyInError: true),
            StuckJobs(printerId: "d", printerName: "Brother", count: 1, oldestMinutes: 5, anyInError: false),
        ]))
        XCTAssertEqual(ids(checks).filter { $0.hasPrefix("stuckJobs:") }, ["stuckJobs:c", "stuckJobs:d"])
    }

    func test_addressesAddedByHand_onlyThoseNotAnsweringAreChecks() {
        let checks = Troubleshooter.diagnose(troubledWindows())
        XCTAssertFalse(ids(checks).contains("manualHost:10.0.0.2"))
        XCTAssertEqual(check(checks, "manualHost:192.168.1.50"), make(
            "manualHost:192.168.1.50", .warning, "No printer answers at 192.168.1.50",
            "Check that it is on and its address hasn't changed.",
            "No printer answered at 192.168.1.50. Its network settings page or control panel shows the current address. "
                + "The app tries the address again every minute.", [.refresh]))
        for platform in platforms {
            let unchecked = check(Troubleshooter.diagnose(PrinterSnapshot(
                platform: platform, manualHosts: [ManualHostStatus(address: "printer.local", listed: false)])),
                                  "manualHost:printer.local")
            XCTAssertTrue(unchecked.more.hasPrefix("Its network settings page"))
        }
    }

    // MARK: - Headline, summary, labels, report

    func test_headline_countsPrintersButNotTheDemo() {
        XCTAssertEqual(Troubleshooter.headline(PrinterSnapshot()), "No printer found")
        XCTAssertEqual(Troubleshooter.headline(PrinterSnapshot(printers: [demo])), "No printer found")
        XCTAssertEqual(Troubleshooter.headline(PrinterSnapshot(printers: [demo, laserJet])), "1 printer found")
        XCTAssertEqual(Troubleshooter.headline(PrinterSnapshot(printers: [demo, laserJet, queue("Epson")])), "2 printers found")
    }

    func test_summary_countsProblemsAndWarnings() {
        func item(_ status: CheckStatus) -> TroubleshootCheck { make("x", status, "t", "d", "", []) }
        XCTAssertEqual(Troubleshooter.summary([item(.problem), item(.ok)]), "1 problem found.")
        XCTAssertEqual(Troubleshooter.summary([item(.warning), item(.tip)]), "1 warning found.")
        XCTAssertEqual(Troubleshooter.summary([item(.problem), item(.warning), item(.problem)]), "2 problems and 1 warning found.")
    }

    func test_labels() {
        XCTAssertEqual(Troubleshooter.label(.refresh, platform: .windows), "Refresh")
        XCTAssertEqual(Troubleshooter.label(.addByAddress, platform: .windows), "Add by address\u{2026}")
        XCTAssertEqual(Troubleshooter.label(.addByAddress, platform: .ios), "Add by address\u{2026}")
        XCTAssertEqual(Troubleshooter.label(.openPrinterSettings, platform: .windows), "Printer settings")
        XCTAssertEqual(Troubleshooter.label(.openPrinterSettings, platform: .mac), "Printers & Scanners")
        XCTAssertEqual(Troubleshooter.label(.openNetworkSettings, platform: .mac), "Network settings")
        XCTAssertEqual(Troubleshooter.label(.copyDiagnostics, platform: .mac), "Copy diagnostics")
        XCTAssertEqual(Troubleshooter.label(.openAppSettings, platform: .ios), "Open Settings")
        XCTAssertEqual(Troubleshooter.label(.clearStuckJobs, platform: .windows), "Clear stuck jobs")
        XCTAssertEqual(Troubleshooter.label(.resumePrinter, platform: .mac), "Resume printer")
        XCTAssertEqual(Troubleshooter.label(.printTestPage, platform: .windows), "Print test page")
        XCTAssertEqual([CheckStatus.ok, .tip, .warning, .problem].map(Troubleshooter.statusLabel), ["OK", "Tip", "Warning", "Problem"])
    }

    func test_actions_areInTheContractsOrder() {
        XCTAssertEqual(TroubleshootAction.allCases.map(\.rawValue),
                       ["refresh", "addByAddress", "openPrinterSettings", "openNetworkSettings", "copyDiagnostics", "openAppSettings",
                        "clearStuckJobs", "resumePrinter", "printTestPage"])
    }

    func test_report_listsEveryCheckWithItsDetail_andItsMoreHelp() {
        let snapshot = healthyWindows()
        let checks = Troubleshooter.diagnose(snapshot)
        let report = Troubleshooter.report(snapshot, checks: checks)
        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Why isn't my printer listed?")
        XCTAssertEqual(lines[1], "1 printer found. Nothing here stops printers from appearing. The tips below cover the usual causes.")
        XCTAssertEqual(lines[2], "OK: Connected to a private network")
        XCTAssertEqual(lines[3], "  Network printers on this network can be found.")
        XCTAssertEqual(lines[lines.count - 4], "Tip: Still not listed?")
        XCTAssertEqual(lines[lines.count - 3], "  Restart the printer and close other printing apps.")
        XCTAssertEqual(lines[lines.count - 2], "  Turn the printer off and on. Close other printing apps. Some printers print only through their "
                       + "maker's app.")
        XCTAssertEqual(lines[lines.count - 1], "")
        XCTAssertEqual(lines.count, 2 + 2 * checks.count + checks.filter { !$0.more.isEmpty }.count + 1)
    }

    func test_combineNetworks() {
        XCTAssertEqual(Troubleshooter.combineNetworks([]), .offline)
        XCTAssertEqual(Troubleshooter.combineNetworks([.publicNetwork]), .publicNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.publicNetwork, .privateNetwork]), .publicNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.privateNetwork]), .privateNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.privateNetwork, .domainNetwork]), .domainNetwork)
        XCTAssertEqual(Troubleshooter.combineNetworks([.unknown]), .unknown)
        XCTAssertEqual(Troubleshooter.combineNetworks([.unknown, .publicNetwork]), .publicNetwork)
    }
}
