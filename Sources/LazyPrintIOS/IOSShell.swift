#if os(iOS)
import LazyPrintKit
import Foundation

/// A file the UI tests hand the app at launch, as if it had been shared to it.
public struct IOSLaunchFixture: Equatable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// What the app was launched with. `-demoPrinter` (the UI tests') keeps the app on the demo printer alone: its settings
/// and its pictures are in a temp folder, and nothing is searched for on the network. `-openFixture` followed by a file
/// name (the next argument) opens that file at launch, as if it had been shared: a UI test cannot drive the system's
/// pickers, and the app cannot read the test bundle, so the test passes the file's bytes, base64, in the environment
/// variable `fixtureVariable`.
public struct IOSLaunchOptions: Equatable, Sendable {
    /// The launch argument for the demo printer alone.
    public static let demoPrinterArgument = "-demoPrinter"
    /// The launch argument that opens the file named by the next argument.
    public static let openFixtureArgument = "-openFixture"
    /// The launch argument that draws the app dark whatever the system's appearance (the screenshots' dark run).
    public static let darkArgument = "-darkAppearance"
    /// The launch argument that pairs the app with a computer that answers from inside the app (the UI tests').
    public static let pairedComputerArgument = "-pairedComputer"
    /// The environment variable holding that file's bytes, base64.
    public static let fixtureVariable = "LAZYPRINT_FIXTURE"

    /// Only the demo printer is offered.
    public let demoPrinterOnly: Bool
    /// The file to open at launch; nil when the app was not launched to open one.
    public let fixture: IOSLaunchFixture?
    /// The app is drawn dark whatever the system's appearance.
    public let dark: Bool
    /// A computer called Office PC is paired already, and answers in the app (`IOSDemoComputer`).
    public let pairedComputer: Bool

    public init(demoPrinterOnly: Bool = false, fixture: IOSLaunchFixture? = nil, dark: Bool = false,
                pairedComputer: Bool = false) {
        self.demoPrinterOnly = demoPrinterOnly
        self.fixture = fixture
        self.dark = dark
        self.pairedComputer = pairedComputer
    }

    /// The options in the process's launch arguments and environment (`ProcessInfo`).
    public init(arguments: [String], environment: [String: String]) {
        self.demoPrinterOnly = arguments.contains(IOSLaunchOptions.demoPrinterArgument)
        self.dark = arguments.contains(IOSLaunchOptions.darkArgument)
        self.pairedComputer = arguments.contains(IOSLaunchOptions.pairedComputerArgument)
        var fixture: IOSLaunchFixture?
        if let index = arguments.firstIndex(of: IOSLaunchOptions.openFixtureArgument), index + 1 < arguments.count,
           let text = environment[IOSLaunchOptions.fixtureVariable],
           let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]), !data.isEmpty {
            let name: String = URL(fileURLWithPath: arguments[index + 1]).lastPathComponent
            fixture = IOSLaunchFixture(name: name, data: data)
        }
        self.fixture = fixture
    }
}

/// What the iPhone's app shell passes `AppState`: its AirPrint printer, its file actions, its troubleshooter service, its
/// lifecycle, its background time and the phone link.
public enum IOSShell {
    /// Where the state keeps its files: the app's own places, with the demo printer's pictures in Caches (nothing on the
    /// phone shows Documents, and they are not worth a backup), or a folder of its own in the temporary folder under
    /// `-demoPrinter`, so a test starts from nothing.
    public static func files(for options: IOSLaunchOptions) -> AppStateFiles {
        guard options.demoPrinterOnly else {
            var files: AppStateFiles = AppStateFiles.standard
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                files.demoPrints = caches.appendingPathComponent("Lazy Print", isDirectory: true)
                    .appendingPathComponent("Demo prints", isDirectory: true)
            }
            return files
        }
        let folder: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-demo-" + UUID().uuidString.lowercased(), isDirectory: true)
        return AppStateFiles.all(in: folder)
    }

    /// Where the phone link keeps its files: Companion in the settings folder, out of backups.
    static func companionFolder(for files: AppStateFiles) -> URL {
        var folder: URL = files.settingsDirectory.appendingPathComponent("Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values: URLResourceValues = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    /// The phone link: its files in `folder`, the device secret in `secrets` (the Keychain), whether a computer that does not
    /// answer is on the network and where it is now from `browser`'s DNS-SD browse. Each time the app comes to the front
    /// with a computer paired, it is checked, browsing while the check runs and, when it did not answer, a few seconds more
    /// before it is checked again, and what waits in the outbox is sent. A computer that did not answer and is found at new
    /// addresses is checked there.
    @MainActor
    static func setUpCompanion(_ state: AppState, folder: URL, secrets: any CompanionSecretStore,
                               browser: IOSCompanionBrowser?, lifecycle: any PlatformLifecycle) {
        state.setUpCompanion(in: folder, secrets: secrets)
        if let browser {
            state.companionDesktopSeenOnNetwork = { [weak browser] (desktopId: String) -> Bool in
                browser?.isSeen(desktopId) ?? false
            }
            state.companionAccessDenied = { [weak browser] () -> Bool in
                browser?.accessDenied ?? false
            }
            browser.onFound = { [weak state] (desktopId: String, addresses: [String], port: Int) -> Void in
                guard let state else { return }
                Task { @MainActor in
                    if await state.desktopFound(id: desktopId, addresses: addresses, port: port),
                       case .unreachable = state.companionStatus {
                        await state.checkDesktop()
                        await state.drainOutbox()
                    }
                }
            }
        }
        lifecycle.observeDidBecomeActive { [weak state] in
            guard let state, state.companionDesktop != nil else { return }
            Task { @MainActor in
                browser?.begin()
                await state.checkDesktop()
                if browser != nil, case .unreachable = state.companionStatus {
                    // A refusal comes sooner than the browse: let it see the computer, or find it elsewhere.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .unreachable = state.companionStatus {
                        await state.checkDesktop()
                    }
                }
                browser?.end()
                await state.drainOutbox()
            }
        }
    }
}

extension AppState {
    /// The iPhone's state: the AirPrint printer `printerSystem` keeps and the printers found on the network (printed to
    /// over IPP), the iOS file actions, troubleshooter service, lifecycle and background time (`platform` `.ios`), and the
    /// phone link (`IOSShell.setUpCompanion`) with its secrets in the Keychain and its cloud folder opened through
    /// `IOSSyncFolder`; `companion` browses for the computers (none: not browsed). Under `-demoPrinter` only the demo printer
    /// is offered and nothing is browsed; under `-pairedComputer` the link is to `IOSDemoComputer`.
    @MainActor
    public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions, printerSystem: IOSPrinterSystem,
                                  companion: IOSCompanionBrowser? = nil) -> AppState {
        let files: AppStateFiles = IOSShell.files(for: options)
        var system: (any PrinterSystem)?
        var network: (any NetworkPrinters)?
        var sheets: (any SheetPrinter)?
        if !options.demoPrinterOnly {
            system = printerSystem
            network = NWBrowserPrinters(directory: files.settingsDirectory, platform: .ios)
            sheets = IOSAirPrintPrinter(system: printerSystem)
        }
        let lifecycle: UIKitLifecycle = UIKitLifecycle()
        let state: AppState = AppState(printerSystem: system, network: network, systemPrinter: sheets, fileActions: fileActions,
                                       troubleshooter: IOSTroubleshooterService(), lifecycle: lifecycle,
                                       background: UIKitBackgroundActivity(), platform: .ios, files: files)
        state.resolveSyncFolderBookmark = { (bookmark: Data) -> (folder: URL, bookmark: Data)? in
            IOSSyncFolder.resolve(bookmark)
        }
        let folder: URL = IOSShell.companionFolder(for: files)
        if options.pairedComputer {
            let secrets: IOSDemoSecrets = IOSDemoSecrets()
            try? PairedDesktopStore(directory: folder, secrets: secrets)
                .save(IOSDemoComputer.desktop(), secret: Data(repeating: 3, count: PairedDeviceStore.secretByteCount))
            IOSShell.setUpCompanion(state, folder: folder, secrets: secrets, browser: nil, lifecycle: lifecycle)
            state.companionProtocolClasses = [IOSDemoComputerProtocol.self]
        } else {
            IOSShell.setUpCompanion(state, folder: folder, secrets: IOSCompanionSecrets(), browser: companion,
                                    lifecycle: lifecycle)
        }
        return state
    }
}
#endif
