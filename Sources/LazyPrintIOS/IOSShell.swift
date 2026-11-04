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
    /// The environment variable holding that file's bytes, base64.
    public static let fixtureVariable = "LAZYPRINT_FIXTURE"

    /// Only the demo printer is offered.
    public let demoPrinterOnly: Bool
    /// The file to open at launch; nil when the app was not launched to open one.
    public let fixture: IOSLaunchFixture?
    /// The app is drawn dark whatever the system's appearance.
    public let dark: Bool

    public init(demoPrinterOnly: Bool = false, fixture: IOSLaunchFixture? = nil, dark: Bool = false) {
        self.demoPrinterOnly = demoPrinterOnly
        self.fixture = fixture
        self.dark = dark
    }

    /// The options in the process's launch arguments and environment (`ProcessInfo`).
    public init(arguments: [String], environment: [String: String]) {
        self.demoPrinterOnly = arguments.contains(IOSLaunchOptions.demoPrinterArgument)
        self.dark = arguments.contains(IOSLaunchOptions.darkArgument)
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
/// lifecycle and its background time.
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
}

extension AppState {
    /// The iPhone's state: the AirPrint printer `printerSystem` keeps and the printers found on the network (printed to
    /// over IPP), the iOS file actions, troubleshooter service, lifecycle and background time (`platform` `.ios`). Under
    /// `-demoPrinter` only the demo printer is offered and nothing is browsed.
    @MainActor
    public static func makeForIOS(options: IOSLaunchOptions, fileActions: IOSFileActions,
                                  printerSystem: IOSPrinterSystem) -> AppState {
        let files: AppStateFiles = IOSShell.files(for: options)
        var system: (any PrinterSystem)?
        var network: (any NetworkPrinters)?
        var sheets: (any SheetPrinter)?
        if !options.demoPrinterOnly {
            system = printerSystem
            network = NWBrowserPrinters(directory: files.settingsDirectory, platform: .ios)
            sheets = IOSAirPrintPrinter(system: printerSystem)
        }
        return AppState(printerSystem: system, network: network, systemPrinter: sheets, fileActions: fileActions,
                        troubleshooter: IOSTroubleshooterService(), lifecycle: UIKitLifecycle(),
                        background: UIKitBackgroundActivity(), platform: .ios, files: files)
    }
}
#endif
