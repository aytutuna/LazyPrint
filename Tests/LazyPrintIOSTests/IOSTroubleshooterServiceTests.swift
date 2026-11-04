#if os(iOS)
import LazyPrintKit
import UIKit
import XCTest
@testable import LazyPrintIOS

// The iPhone's troubleshooter service: Settings opens at the app's page and nothing else opens; the network comes from
// the path it is given. Tests pass their own opener and network, so no Settings app is started.

/// The addresses the service was asked to open.
@MainActor
private final class OpenedAddresses {
    var urls: [URL] = []
}

/// A network that says what the test says.
@MainActor
private final class FakeNetwork: IOSNetworkStatusReading {
    var status: NetworkStatus

    init(_ status: NetworkStatus) {
        self.status = status
    }
}

final class IOSTroubleshooterServiceTests: XCTestCase {
    @MainActor
    private func makeService(_ opened: OpenedAddresses, network: (any IOSNetworkStatusReading)? = nil) -> IOSTroubleshooterService {
        IOSTroubleshooterService(openURL: { (url: URL) -> Void in
            opened.urls.append(url)
        }, network: network)
    }

    @MainActor
    func test_everySettingsAction_opensTheAppsPageInSettings() throws {
        let opened = OpenedAddresses()
        let service = makeService(opened)

        try service.open(.openAppSettings)
        try service.open(.openPrinterSettings)
        try service.open(.openNetworkSettings)

        let settings = try XCTUnwrap(URL(string: UIApplication.openSettingsURLString))
        XCTAssertEqual(opened.urls, [settings, settings, settings])
    }

    @MainActor
    func test_anActionThatOpensNothing_isRefused() {
        let opened = OpenedAddresses()
        let service = makeService(opened)

        for action in [TroubleshootAction.refresh, .addByAddress, .copyDiagnostics, .clearStuckJobs, .resumePrinter, .printTestPage] {
            XCTAssertThrowsError(try service.open(action), action.rawValue)
        }
        XCTAssertEqual(opened.urls, [])
    }

    @MainActor
    func test_theNetwork_isFilledInFromThePath() async {
        let service = makeService(OpenedAddresses(), network: FakeNetwork(.privateNetwork))
        var snapshot = PrinterSnapshot(platform: .ios)

        await service.addSystemStatus(to: &snapshot)

        XCTAssertEqual(snapshot.network, .privateNetwork)
        XCTAssertEqual(snapshot.spooler, .unknown)
    }

    @MainActor
    func test_withoutAPath_theSnapshotIsLeftAsItWas() async {
        let service = makeService(OpenedAddresses())
        var snapshot = PrinterSnapshot(platform: .ios, network: .offline)

        await service.addSystemStatus(to: &snapshot)

        XCTAssertEqual(snapshot.network, .offline)
    }

    func test_wifiAndWired_areThePrivateNetwork_anythingElseIsOffline() {
        XCTAssertEqual(IOSNetworkPath.status(wifi: true, wired: false), .privateNetwork)
        XCTAssertEqual(IOSNetworkPath.status(wifi: false, wired: true), .privateNetwork)
        XCTAssertEqual(IOSNetworkPath.status(wifi: true, wired: true), .privateNetwork)
        XCTAssertEqual(IOSNetworkPath.status(wifi: false, wired: false), .offline)
    }

    func test_localNetworkDenied_isReadFromThePathsReason() {
        XCTAssertTrue(IOSLocalNetworkProbe.isDenied(.localNetworkDenied))
        XCTAssertFalse(IOSLocalNetworkProbe.isDenied(.notAvailable))
        XCTAssertFalse(IOSLocalNetworkProbe.isDenied(nil))
    }
}
#endif
