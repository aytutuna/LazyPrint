#if os(macOS)
import XCTest
@testable import LazyPrintMac

// The bookmark of the cloud folder: made of a folder, it opens the same folder again.

final class MacSyncFolderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func test_bookmark_opensTheSameFolder() throws {
        let kept = MacSyncFolder()
        defer { kept.close() }
        let bookmark = try MacSyncFolder.bookmark(of: folder)

        let opened = try XCTUnwrap(kept.resolve(bookmark))

        XCTAssertEqual(opened.folder.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
    }

    func test_resolve_nilForDataThatIsNotABookmark() {
        let kept = MacSyncFolder()
        XCTAssertNil(kept.resolve(Data([1, 2, 3])))
    }
}
#endif
