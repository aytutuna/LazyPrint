#if os(macOS)
import Foundation
import XCTest
@testable import LazyPrintKit
@testable import LazyPrintMac

// The Mac's phone link as AppState sees it: started when a phone is paired or the sheet opens, one copy of the app at a
// time. The server itself is tested in LazyPrintTests.

@MainActor
final class MacCompanionHostingTests: XCTestCase {
    private func pairAPhone(_ options: CompanionServiceOptions) throws {
        _ = try PairedDeviceStore(directory: options.settingsDirectory)
            .pair(id: "phone-0001", name: "Aytu's iPhone", platform: "ios", appVersion: "1.0", now: Date())
    }

    private func request() -> PairRequest {
        PairRequest(token: "token", phoneId: "phone-0001", phoneName: "Aytu's iPhone", platform: "ios", appVersion: "1.0")
    }

    func test_startIfPaired_startsNothingWhileNoPhoneIsPaired() throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))

        host.startIfPaired()

        XCTAssertNil(host.service)
    }

    func test_startIfPaired_startsTheLinkWhenAPhoneIsPaired() throws {
        let options = try CompanionServiceOptions.test(in: try tempFolder())
        try pairAPhone(options)
        let host = MacCompanionHosting(options: options)

        host.startIfPaired()

        XCTAssertNotNil(host.service)
    }

    func test_ensure_givesTheSameServiceEachTime() throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))

        let first = host.ensure()

        XCTAssertNotNil(first)
        XCTAssertTrue(host.ensure() === first)
    }

    func test_ensure_tellsTheStateToLookAtTheInbox() throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))
        var told = 0
        host.onChange = { told += 1 }

        host.ensure()

        XCTAssertEqual(told, 1)
    }

    func test_forgettingAPhone_tellsTheStateToLookAtTheInboxAgain() async throws {
        let options = try CompanionServiceOptions.test(in: try tempFolder())
        try pairAPhone(options)
        let host = MacCompanionHosting(options: options)
        let service = try XCTUnwrap(host.ensure())
        var told = 0
        host.onChange = { told += 1 }

        await service.removeDevice("phone-0001")

        let end: Date = Date().addingTimeInterval(5)
        while told == 0 && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(told, 0)
    }

    func test_anotherCopyOfTheApp_isToldItIsElsewhere() throws {
        let folder = try tempFolder()
        let first = MacCompanionHosting(options: try .test(in: folder))
        let second = MacCompanionHosting(options: try .test(in: folder))

        XCTAssertNotNil(first.ensure())

        XCTAssertNil(second.ensure())
        XCTAssertEqual(second.status.state, .elsewhere)
        XCTAssertNil(second.ensure())
        XCTAssertNotNil(first.service)
    }

    func test_beforeTheLinkStarts_noBatchIsWaiting() async throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))

        XCTAssertTrue(host.batches(now: Date()).isEmpty)
        let taken = await host.take(batch: "batch-0001")
        XCTAssertTrue(taken.isEmpty)
    }

    func test_aBatchThatIsNotThere_hasNoFiles() async throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))
        host.ensure()

        XCTAssertTrue(host.batches(now: Date()).isEmpty)
        let taken = await host.take(batch: "batch-0001")
        XCTAssertTrue(taken.isEmpty)
    }

    func test_theCloudFolder_isKeptOnceTheLinkRuns() throws {
        let folder = try tempFolder()
        let cloud = folder.appendingPathComponent("cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let host = MacCompanionHosting(options: try .test(in: folder))
        XCTAssertFalse(host.setSyncFolder(cloud))

        host.ensure()

        XCTAssertTrue(host.setSyncFolder(cloud))
        XCTAssertEqual(host.service?.syncFolder?.lastPathComponent, "cloud")
    }

    func test_aPairing_isDeclinedWhenNobodyIsThereToAsk() async throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))
        let service = try XCTUnwrap(host.ensure())

        let allowed = await service.router.approvePairing(request())

        XCTAssertFalse(allowed)
    }

    func test_aPairing_followsTheAnswerOfTheSheet() async throws {
        let host = MacCompanionHosting(options: try .test(in: try tempFolder()))
        let service = try XCTUnwrap(host.ensure())
        var asked: [String] = []
        host.confirmPairing = { pair in
            asked.append(pair.phoneName)
            return false
        }

        let allowed = await service.router.approvePairing(request())

        XCTAssertFalse(allowed)
        XCTAssertEqual(asked, ["Aytu's iPhone"])
    }
}
#endif
