import Foundation

/// What the troubleshooter does outside the app: open a Settings page and say how the network is. It never changes a
/// setting. Twin of the Windows `ISystemDiagnostics`, which also reads the Print Spooler service.
@MainActor
public protocol TroubleshooterService: AnyObject {
    /// Opens what `action` names (`openPrinterSettings`, `openNetworkSettings`, `openAppSettings`); throws when the
    /// system refuses.
    func open(_ action: TroubleshootAction) throws
    /// Fills in what the system says: the network (and on the iPhone, Local Network access). The spooler stays unknown.
    func addSystemStatus(to snapshot: inout PrinterSnapshot) async
}

/// The troubleshooter's system side of an `AppState` whose app shell passed none.
@MainActor
final class UnavailableTroubleshooterService: TroubleshooterService {
    func open(_ action: TroubleshootAction) throws {
        throw PrintError.unreadable("Settings cannot be opened here.")
    }

    func addSystemStatus(to snapshot: inout PrinterSnapshot) async {}
}
