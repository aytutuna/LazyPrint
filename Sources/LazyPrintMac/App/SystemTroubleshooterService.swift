#if os(macOS)
import AppKit
import Foundation
import LazyPrintKit
import Network

/// The macOS implementation of `TroubleshooterService`: NSWorkspace for System Settings, and the network's state read
/// once from an NWPathMonitor. It never changes a setting.
@MainActor
public final class SystemTroubleshooterService: TroubleshooterService {
    /// System Settings, Printers & Scanners.
    public static let printersAndScannersURL = URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension")!
    /// System Settings, Network.
    public static let networkSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!

    public init() {}

    public func open(_ action: TroubleshootAction) throws {
        let url: URL
        switch action {
        case .openPrinterSettings: url = Self.printersAndScannersURL
        case .openNetworkSettings: url = Self.networkSettingsURL
        default: throw PrintError.unreadable("\(action.rawValue) does not open anything here.")
        }
        guard NSWorkspace.shared.open(url) else {
            throw PrintError.unreadable("System Settings did not open.")
        }
    }

    /// The Mac has no public or private networks: connected is private.
    public func addSystemStatus(to snapshot: inout PrinterSnapshot) async {
        snapshot.network = await Self.network()
    }

    private final class Answered: @unchecked Sendable {
        var done = false
    }

    private static func network() async -> NetworkStatus {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = Answered()
            monitor.pathUpdateHandler = { path in
                // Updates come on the monitor's own queue, one at a time; the first is the answer.
                if answered.done { return }
                answered.done = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied ? .privateNetwork : .offline)
            }
            monitor.start(queue: DispatchQueue(label: "local.lazyprint.network"))
        }
    }
}
#endif
