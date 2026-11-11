import Foundation

/// What asking a printer at an address came to: what it said, or why not. Twin of the Windows record.
public struct AddressCheck: Sendable {
    /// The address that answered, or the one tried last.
    public var address: PrinterAddress
    public var capabilities: PrinterCapabilities?
    /// The printer's certificate was refused and the user can decide.
    public var certificate: IppCertificateError?
    /// Why there was no answer, in words for the user; nil with capabilities or a certificate.
    public var error: String?

    public init(address: PrinterAddress, capabilities: PrinterCapabilities?, certificate: IppCertificateError?, error: String?) {
        self.address = address
        self.capabilities = capabilities
        self.certificate = certificate
        self.error = error
    }
}

/// Printers on the network: the ones DNS-SD announces and the addresses added by hand, and what they say of
/// themselves. `NWBrowserPrinters` is the one implementation; twin of the Windows `INetworkPrinters`.
@MainActor
public protocol NetworkPrinters: AnyObject {
    /// The services or the state of the search changed.
    var onChange: (() -> Void)? { get set }
    /// The services announced, and the listed addresses that answered.
    var services: [IppService] { get }
    var discovery: DiscoveryStatus { get }
    /// Why the search is unavailable, as the system put it; nil otherwise.
    var discoveryDetail: String? { get }
    /// The addresses in ipp-hosts.json, and whether each answers.
    var hosts: [ManualHostStatus] { get }
    /// Starts the search and the checks of the listed addresses.
    func start()
    /// Searches again where the search stopped, and checks the unanswered addresses now.
    func restart()
    /// Get-Printer-Attributes at the printer's addresses in order. A refused certificate, new or changed, is returned,
    /// not pinned or asked about; the answer of another address of the printer comes with it.
    func read(_ endpoint: IppEndpoint) async -> AddressCheck
    /// What the "Add printer" sheet checks.
    func check(_ address: PrinterAddress, firstUse: String?) async -> AddressCheck
    /// Lists an address that answered in ipp-hosts.json and among the printers.
    func add(_ address: PrinterAddress, capabilities: PrinterCapabilities)
    /// Pins a certificate the user accepted.
    func trust(_ certificate: IppCertificateError, deviceUuid: String?, name: String)
}

/// The network of an `AppState` whose app shell passed none: nothing is found and the search is unavailable.
@MainActor
final class NoNetworkPrinters: NetworkPrinters {
    var onChange: (() -> Void)?
    var services: [IppService] { [] }
    var discovery: DiscoveryStatus { .unavailable }
    var discoveryDetail: String? { nil }
    var hosts: [ManualHostStatus] { [] }

    func start() {}
    func restart() {}

    func read(_ endpoint: IppEndpoint) async -> AddressCheck {
        AddressCheck(address: endpoint.addresses[0], capabilities: nil, certificate: nil, error: "it did not answer")
    }

    func check(_ address: PrinterAddress, firstUse: String?) async -> AddressCheck {
        AddressCheck(address: address, capabilities: nil, certificate: nil, error: "it did not answer")
    }

    func add(_ address: PrinterAddress, capabilities: PrinterCapabilities) {}
    func trust(_ certificate: IppCertificateError, deviceUuid: String?, name: String) {}
}

/// What the alert about a certificate asks. `address` is set for a printer typed by address.
public struct CertificateRequest: Equatable, Sendable {
    public var certificate: IppCertificateError
    public var address: PrinterAddress?
    public var name: String
    public var deviceUuid: String?

    public init(certificate: IppCertificateError, address: PrinterAddress?, name: String, deviceUuid: String?) {
        self.certificate = certificate
        self.address = address
        self.name = name
        self.deviceUuid = deviceUuid
    }
}
