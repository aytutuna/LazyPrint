#if os(iOS)
import LazyPrintKit
import Foundation
import SwiftUI

/// The iPhone app. The Xcode project's app target (ios/project.yml) only starts it (`LazyPrintIOSApp.main()`). The
/// objects are made in `init`, so they are there before a URL arrives; the root view takes the files in (Open In, the
/// share sheet, the pickers).
public struct LazyPrintIOSApp: App {
    @StateObject private var state: AppState
    private let fileActions: IOSFileActions
    private let airPrint: IOSPrinterSystem?
    private let companion: IOSCompanionBrowser?
    private let inbox: IOSFileInbox
    private let fixture: IOSLaunchFixture?
    private let dark: Bool

    public init() {
        let process: ProcessInfo = ProcessInfo.processInfo
        let options: IOSLaunchOptions = IOSLaunchOptions(arguments: process.arguments, environment: process.environment)
        let files: IOSFileInbox = IOSFileInbox()
        files.empty()
        let actions: IOSFileActions = IOSFileActions()
        let printerSystem: IOSPrinterSystem = IOSPrinterSystem()
        let browser: IOSCompanionBrowser? = options.demoPrinterOnly ? nil : IOSCompanionBrowser()
        _state = StateObject(wrappedValue: AppState.makeForIOS(options: options, fileActions: actions,
                                                               printerSystem: printerSystem, companion: browser))
        fileActions = actions
        airPrint = options.demoPrinterOnly ? nil : printerSystem
        companion = browser
        inbox = files
        fixture = options.fixture
        dark = options.dark
    }

    public var body: some Scene {
        WindowGroup {
            IOSRootView(fileActions: fileActions, airPrint: airPrint, inbox: inbox, fixture: fixture, companion: companion)
                .environmentObject(state)
                .preferredColorScheme(dark ? .dark : nil)
        }
    }
}
#endif
