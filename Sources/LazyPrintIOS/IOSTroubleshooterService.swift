#if os(iOS)
import LazyPrintKit
import Foundation
import Network
import UIKit

/// What the iPhone's troubleshooter can read about the network: whether it is on Wi-Fi or a wired network.
@MainActor
public protocol IOSNetworkStatusReading: AnyObject {
    /// `.privateNetwork` on Wi-Fi or a wired network (iOS has no public and private networks), `.offline` without one
    /// (cellular only included), `.unknown` until the system has said.
    var status: NetworkStatus { get }
}

/// `NWPathMonitor` on the main queue: watches the network path, reads nothing else and sends nothing.
@MainActor
public final class IOSNetworkPath: IOSNetworkStatusReading {
    public private(set) var status: NetworkStatus = .unknown
    private let monitor: NWPathMonitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] (path: NWPath) -> Void in
            // availableInterfaces, not usesInterfaceType: a Wi-Fi network without internet is not the default route
            let types: [NWInterface.InterfaceType] = path.availableInterfaces.map { (interface: NWInterface) -> NWInterface.InterfaceType in
                interface.type
            }
            let wifi: Bool = types.contains(NWInterface.InterfaceType.wifi)
            let wired: Bool = types.contains(NWInterface.InterfaceType.wiredEthernet)
            let status: NetworkStatus = IOSNetworkPath.status(wifi: wifi, wired: wired)
            MainActor.assumeIsolated {
                self?.status = status
            }
        }
        monitor.start(queue: DispatchQueue.main)
    }

    /// The troubleshooter's network for a path: a Wi-Fi or wired network is where printers are found, with or without
    /// internet on it.
    public nonisolated static func status(wifi: Bool, wired: Bool) -> NetworkStatus {
        if wifi || wired {
            return .privateNetwork
        }
        return .offline
    }
}

/// The iPhone's `TroubleshooterService`: opens the app's page in Settings, the only system page an app may open (it is
/// where Local Network access is turned on), and fills in the network the troubleshooter checks. iOS has no page of
/// its own for printers or the network, so those two actions open the same one. A refusal of Local Network access
/// reaches the troubleshooter through the network printers' `discovery` (`.denied`), not through this service. It
/// never changes a setting.
@MainActor
public final class IOSTroubleshooterService: TroubleshooterService {
    private let openURL: @MainActor (URL) -> Void
    private let network: (any IOSNetworkStatusReading)?

    /// The app's: UIApplication opens Settings, the network path is watched.
    public convenience init() {
        self.init(openURL: { (url: URL) -> Void in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }, network: IOSNetworkPath())
    }

    /// Tests pass their own opener and network.
    public init(openURL: @escaping @MainActor (URL) -> Void, network: (any IOSNetworkStatusReading)?) {
        self.openURL = openURL
        self.network = network
    }

    public func open(_ action: TroubleshootAction) throws {
        switch action {
        case .openAppSettings, .openPrinterSettings, .openNetworkSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                throw PrintError.unreadable("Settings did not open.")
            }
            openURL(url)
        default:
            throw PrintError.unreadable("\(action.rawValue) does not open anything here.")
        }
    }

    public func addSystemStatus(to snapshot: inout PrinterSnapshot) async {
        guard let network else { return }
        snapshot.network = network.status
    }
}
#endif
