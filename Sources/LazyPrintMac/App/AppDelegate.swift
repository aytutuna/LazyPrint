#if os(macOS)
import AppKit
import Combine
import LazyPrintKit

/// The app's delegate (`LazyPrintApp`'s `@NSApplicationDelegateAdaptor`): Quit asks first while a job is going out or a
/// two-sided job waits for its backs, since the sheets still to be drawn are lost with the app. There is no `application(_:open:)`: once the delegate implements it
/// AppKit sends it every URL and `.onOpenURL` never fires.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when the window appears.
    weak var state: AppState? {
        didSet { watchPhoneBatches() }
    }
    private var batchWatch: AnyCancellable?

    // The bar that announces a batch is in the window, which may be closed while the phone link runs on.
    private func watchPhoneBatches() {
        batchWatch = state?.$phoneBatches
            .map { $0.map(\.id) }
            .removeDuplicates()
            .scan(([String](), [String]())) { ($0.1, $1) }
            .sink { (old, new) in
                guard new.contains(where: { !old.contains($0) }) else { return }
                if !NSApp.windows.contains(where: { $0.isVisible }) {
                    _ = NSApp.requestUserAttention(.informationalRequest)
                }
            }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        if !state.isBusy {
            guard state.hasBacksWaiting else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The backs are not printed yet"
            alert.informativeText = "Quitting now leaves the two-sided job half done."
            let quit = alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            quit.keyEquivalent = ""
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop it and quit?"
        alert.informativeText = "A job is still being sent to the printer."
        let quit = alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        // Return does not quit.
        quit.keyEquivalent = ""
        // Quit from the Dock or at logout can come while the app is in the background.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // The queue is told to drop the job before the app goes.
        Task {
            await state.cancelJobAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Closing the window leaves the app, and the phone link, running; a Dock click opens the window again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
#endif
