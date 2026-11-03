import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppHostListTests.cs: the same cases. The printers added by
// address (ipp-hosts.json).

final class IppHostListTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAddsCanonicalAddressesOnce() throws {
        let hosts = IppHostList(directory: directory)
        XCTAssertTrue(hosts.load().isEmpty)
        XCTAssertTrue(hosts.add(try PrinterAddress.parse("ipp://192.168.1.50:631/ipp/print")))
        XCTAssertFalse(hosts.add(try PrinterAddress.parse("192.168.1.50")))
        XCTAssertTrue(hosts.add(try PrinterAddress.parse("ipps://10.0.0.7")))
        XCTAssertEqual(hosts.loadEntries(), ["192.168.1.50", "ipps://10.0.0.7"])
        XCTAssertTrue(hosts.remove(try PrinterAddress.parse("192.168.1.50")))
        XCTAssertFalse(hosts.remove(try PrinterAddress.parse("192.168.1.50")))
        XCTAssertEqual(hosts.loadEntries(), ["ipps://10.0.0.7"])
    }

    func testHandWrittenEntriesKeepWorking() throws {
        let hosts = IppHostList(directory: directory)
        try Data(#"["192.168.1.50", "epson.local:8631", "not an address", "192.168.1.50"]"#.utf8).write(to: hosts.fileURL)
        XCTAssertEqual(hosts.load().map { $0.description }, ["192.168.1.50", "epson.local:8631"])
        // Adding keeps the other entries, including the one that is not an address.
        XCTAssertTrue(hosts.add(try PrinterAddress.parse("10.0.0.9")))
        XCTAssertEqual(hosts.loadEntries(), ["192.168.1.50", "epson.local:8631", "not an address", "192.168.1.50", "10.0.0.9"])
    }

    func testAnUndecodableListIsKeptAside() throws {
        let hosts = IppHostList(directory: directory)
        try Data(#"{"hosts": ["192.168.1.50"]}"#.utf8).write(to: hosts.fileURL)
        XCTAssertTrue(hosts.load().isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ipp-hosts.unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(hosts.add(try PrinterAddress.parse("10.0.0.9")))
        XCTAssertEqual(hosts.loadEntries(), ["10.0.0.9"])
    }

    func testTheFileIsIppHostsJsonInTheDirectory() {
        XCTAssertEqual(IppHostList(directory: directory).fileURL, directory.appendingPathComponent("ipp-hosts.json"))
    }
}
