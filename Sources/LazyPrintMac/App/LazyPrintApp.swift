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
            // No File > New Window: a second window on the same state would show each sheet and alert twice.
            CommandGroup(replacing: .newItem) {}
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
