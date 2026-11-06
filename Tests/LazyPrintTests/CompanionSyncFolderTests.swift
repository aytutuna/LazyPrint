import Foundation
import Security
import XCTest
@testable import LazyPrintKit

// A cloud folder kept as a bookmark that does not open: the saved path is watched meanwhile, the problem is said, and the
// bookmark is tried again until it opens.

private final class NoIdentity: CompanionIdentity {
    func current(now: Date) throws -> SecIdentity { throw SelfSignedCertificateError("No identity in this test.") }
    func renew(now: Date) throws -> SecIdentity { throw SelfSignedCertificateError("No identity in this test.") }
}

final class CompanionSyncFolderTests: XCTestCase {
    private var directory: URL!
    private var service: CompanionService?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await service?.dispose()
        try? FileManager.default.removeItem(at: directory)
    }

    func testABookmarkThatDoesNotOpen_IsSaidAndTriedAgainUntilItDoes() async throws {
        let cloud = directory.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let bookmark = Data([1, 2, 3])
        let attempts = Guarded(0)
        var options = CompanionServiceOptions(settingsDirectory: directory.appendingPathComponent("Settings", isDirectory: true),
                                              dataDirectory: directory.appendingPathComponent("Data", isDirectory: true),
                                              identity: NoIdentity(), networks: FakeNetworkSource([]), desktopName: "TEST-MAC")
        // Opens from the third try on.
        options.resolveSyncFolder = { _ in
            attempts.value += 1
            return attempts.value >= 3 ? (folder: cloud, bookmark: bookmark) : nil
        }
        options.syncFolderRetryInterval = 0.02
        let service = CompanionService(options)
        self.service = service
        let problems = Guarded<[String?]>([])
        service.onSyncFolderProblem = { problems.value.append($0) }
        XCTAssertTrue(service.devices.setSyncFolder(cloud, bookmark: bookmark))

        await service.start()

        XCTAssertEqual(problems.value.first, CompanionService.syncFolderUnresolvedMessage)
        let deadline = Date().addingTimeInterval(10)
        while problems.value.last != .some(nil) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(problems.value.last, .some(nil))
        XCTAssertGreaterThanOrEqual(attempts.value, 3)
        // Once it opens, it is not tried again.
        let settled = attempts.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(attempts.value, settled)
    }

    func testABookmarkThatNeverOpens_StillWatchesTheSavedPath() async throws {
        let cloud = directory.appendingPathComponent("Cloud", isDirectory: true)
        var options = CompanionServiceOptions(settingsDirectory: directory.appendingPathComponent("Settings", isDirectory: true),
                                              dataDirectory: directory.appendingPathComponent("Data", isDirectory: true),
                                              identity: NoIdentity(), networks: FakeNetworkSource([]), desktopName: "TEST-MAC")
        options.resolveSyncFolder = { _ in nil }
        options.syncFolderRetryInterval = 60
        let service = CompanionService(options)
        self.service = service
        XCTAssertTrue(service.devices.setSyncFolder(cloud, bookmark: Data([1])))

        await service.start()

        XCTAssertEqual(service.syncFolder?.path, cloud.path)
    }
}
