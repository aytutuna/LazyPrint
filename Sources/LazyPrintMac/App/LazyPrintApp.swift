#if os(macOS)
import AppKit
import LazyPrintKit
import SwiftUI

public struct LazyPrintApp: App {
    @StateObject private var state: AppState
    @StateObject private var phone: MacCompanionHosting
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {
        // No tabs: each would be another window over the same state.
        NSWindow.allowsAutomaticWindowTabbing = false
        CupsPrinter.removeStaleFiles()
        // Made here, so the state is there before any URL arrives.
        let host = MacCompanionHosting(options: MacCompanionHosting.standardOptions())
        _state = StateObject(wrappedValue: AppState.makeForMac(companion: host))
        _phone = StateObject(wrappedValue: host)
        host.startIfPaired()
    }

    public var body: some Scene {
        WindowGroup("Lazy Print") {
            ContentView()
                .environmentObject(state)
                .environmentObject(phone)
                .onAppear {
                    delegate.state = state
                    NSApp.activate(ignoringOtherApps: true)
                }
                // The printers are read, and read again, only while the window is open.
                .task { await MainActor.run { state.setActive(true) } }
                .onDisappear { state.setActive(false) }
        }
        .commands {
            PrintCommands(state: state)
        }
    }
}

extension Notification.Name {
    /// File > Add Files: the window opens its panel.
    static let addFilesRequested = Notification.Name("LazyPrintAddFilesRequested")
    /// View > Print, Jobs: the window shows the tab whose raw value is the notification's object.
    static let tabRequested = Notification.Name("LazyPrintTabRequested")
}

extension FocusedValues {
    /// True while one of the window's sheets is up; the window sets it.
    var sheetOpen: Bool? {
        get { self[SheetOpenKey.self] }
        set { self[SheetOpenKey.self] = newValue }
    }
}

private struct SheetOpenKey: FocusedValueKey {
    typealias Value = Bool
}

/// File > Add Files, Print and Cancel Printing, which do what the buttons in the window do.
private struct PrintCommands: Commands {
    @ObservedObject var state: AppState
    // The window's alerts and its open panel do not show over a sheet.
    @FocusedValue(\.sheetOpen) private var sheetOpen

    var body: some Commands {
        // No File > New Window: a second window on the same state would show each sheet and alert twice.
        CommandGroup(replacing: .newItem) {
            Button("Add Files\u{2026}") {
                NotificationCenter.default.post(name: .addFilesRequested, object: nil)
            }
            .keyboardShortcut("o")
            .disabled(state.isBusy || sheetOpen == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Print") { NotificationCenter.default.post(name: .tabRequested, object: ContentTab.print.rawValue) }
                .keyboardShortcut("1")
            Button("Jobs") { NotificationCenter.default.post(name: .tabRequested, object: ContentTab.jobs.rawValue) }
                .keyboardShortcut("2")
        }
        CommandGroup(replacing: .help) {
            Link("Lazy Print Help", destination: URL(string: "https://alazy.app/print/")!)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { Task { await state.print() } }
                .keyboardShortcut("p")
                .disabled(!state.canPrint || sheetOpen == true)
            Button("Cancel Printing") { state.cancelJob() }
                .keyboardShortcut(".")
                .disabled(!state.isBusy)
        }
    }
}

extension AppState {
    /// The Mac app's state: the queues macOS has set up, read with libcups, and the printers found on the network; jobs
    /// to a queue go through CUPS; the Mac's file actions, troubleshooter links and app lifecycle; the phone link `companion`.
    @MainActor
    static func makeForMac(companion: any CompanionHosting) -> AppState {
        AppState(printerSystem: CupsQueues(), network: NWBrowserPrinters(), systemPrinter: CupsPrinter(),
                 fileActions: SystemFileActions(), troubleshooter: SystemTroubleshooterService(),
                 lifecycle: AppKitLifecycle(), companion: companion)
    }
}
#endif
