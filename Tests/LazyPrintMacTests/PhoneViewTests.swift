#if os(macOS)
import AppKit
import CoreImage
import XCTest
@testable import LazyPrintKit
@testable import LazyPrintMac

// What the phone sheet and the bar above the tabs work out without a window: the pairing picture, the sentences, and the
// files a lazyprint: address names.

final class PhoneViewTests: XCTestCase {
    private let sample = "lazyprint://pair?v=1&id=desktop-0001&n=Test%20Mac&fp=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&a=192.168.1.20&p=52732&t=AAAAAAAAAAAAAAAAAAAAAA"

    /// The pixels of a gray picture, row by row.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        return data
    }

    func test_qrImage_isSquareAndReadsBack() throws {
        let image = try XCTUnwrap(PhoneView.qrImage(sample))

        XCTAssertEqual(image.width, image.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [sample])
    }

    func test_qrImage_hasAQuietZoneOfFourModules() throws {
        let image = try XCTUnwrap(PhoneView.qrImage(sample))
        let data = try pixels(image)

        let firstDark = try XCTUnwrap(data.firstIndex { $0 < 128 })
        // The first dark pixel is the top-left corner of the finder pattern: four modules in, and as many down.
        let scale = firstDark % image.width / 4
        XCTAssertEqual(firstDark / image.width, 4 * scale)
        XCTAssertEqual(firstDark % image.width, 4 * scale)
        let modules = image.width / scale - 8
        XCTAssertGreaterThanOrEqual(modules, 21)
        XCTAssertEqual((modules - 21) % 4, 0)
        XCTAssertEqual(image.width, (modules + 8) * scale)
        XCTAssertTrue(Set(data).isSubset(of: [0, 255]))
    }

    func test_qrImage_ofNothing_isNil() {
        XCTAssertNil(PhoneView.qrImage(""))
    }

    func test_whyNoCode_saysWhatToDo() {
        func why(_ state: CompanionListenState, error: String? = nil) -> String {
            PhoneView.whyNoCode(CompanionHostStatus(state: state, networks: [], endpoints: [], error: error))
        }

        XCTAssertEqual(why(.offline), "Connect this Mac to a network first, then choose Pair a phone again.")
        XCTAssertTrue(why(.noTrustedNetwork).contains("Turn on Allow receiving on this network"))
        XCTAssertEqual(why(.failed, error: "Address in use"), "Address in use")
        XCTAssertEqual(why(.failed), "Receiving from phones could not start.")
        XCTAssertEqual(why(.listening), "No pairing code could be made.")
    }

    func test_caption_saysWhenAPhonePairedAndWasSeen() {
        var device = PairedDevice()
        XCTAssertEqual(PhoneView.caption(device), "")

        device.lastSeen = Date()
        XCTAssertTrue(PhoneView.caption(device).hasPrefix("last seen today at "))

        device.paired = Date(timeIntervalSince1970: 1_700_000_000)
        device.lastSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let caption = PhoneView.caption(device)
        XCTAssertTrue(caption.hasPrefix("Paired "))
        XCTAssertTrue(caption.contains(" \u{00B7} last seen "))
        XCTAssertFalse(caption.contains("today"))
    }

    func test_syncFolderStatus_saysWhatIsWatched() throws {
        let folder = try tempFolder()

        XCTAssertEqual(PhoneView.syncFolderStatus(nil, running: false), "Not watching.")
        XCTAssertEqual(PhoneView.syncFolderStatus(nil, running: true), "Not watching: no folder chosen.")
        XCTAssertEqual(PhoneView.syncFolderStatus(folder, running: true), "Watching \(folder.path).")
        let missing = folder.appendingPathComponent("gone")
        XCTAssertEqual(PhoneView.syncFolderStatus(missing, running: true),
                       "Waiting for \(missing.path): the folder is not there now.")
    }

    func test_theBarsMessage_countsTheFilesAndNamesThePhone() {
        func message(arrived: Int, from: String) -> String {
            PhoneBarView.message(PhoneBatch(id: "batch-0001", from: from, count: arrived, arrived: arrived, lastReceived: Date()))
        }

        XCTAssertEqual(message(arrived: 3, from: "Aytu's iPhone"), "3 files from Aytu's iPhone")
        XCTAssertEqual(message(arrived: 1, from: "Aytu's iPhone"), "1 file from Aytu's iPhone")
        XCTAssertEqual(message(arrived: 2, from: ""), "2 files from a phone")
    }

    func test_theBarIsAnnouncedAgain_forAQueuedBatchThatReadsTheSame() {
        func key(_ id: String, arrived: Int) -> String {
            PhoneBarView.announcementKey(PhoneBatch(id: id, from: "Aytu's iPhone", count: arrived, arrived: arrived, lastReceived: Date()))
        }

        XCTAssertNotEqual(key("batch-0001", arrived: 2), key("batch-0002", arrived: 2))
        XCTAssertNotEqual(key("batch-0001", arrived: 2), key("batch-0001", arrived: 3))
        XCTAssertEqual(key("batch-0001", arrived: 2), key("batch-0001", arrived: 2))
    }

    func test_aLazyPrintAddress_namesTheFilesToAdd() {
        let url = URL(string: "lazyprint:open?file=%2Ftmp%2FScan%201.pdf&file=%2FUsers%2Fme%2Fb.pdf&x=1")!

        XCTAssertEqual(ContentView.files(in: url).map(\.path), ["/tmp/Scan 1.pdf", "/Users/me/b.pdf"])
    }

    func test_aLazyPrintAddress_refusesPathsThatAreNotAbsolute() {
        let url = URL(string: "lazyprint:open?file=scan.pdf&file=..%2Fscan.pdf&file=%2Ftmp%2Fok.pdf")!

        XCTAssertEqual(ContentView.files(in: url).map(\.path), ["/tmp/ok.pdf"])
    }

    func test_anAddressWithoutFiles_addsNothing() {
        XCTAssertTrue(ContentView.files(in: URL(string: "lazyprint:")!).isEmpty)
        XCTAssertTrue(ContentView.files(in: URL(string: "lazyprint:open")!).isEmpty)
        XCTAssertTrue(ContentView.files(in: URL(string: "lazyscan:open?file=%2Ftmp%2Fa.pdf")!).isEmpty)
    }

    func test_readable_setsAsideFilesThatCannotBeOpened() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("open-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let there = folder.appendingPathComponent("there.pdf")
        try Data("x".utf8).write(to: there)
        let missing = folder.appendingPathComponent("missing.pdf")

        let split = ContentView.readable([there, missing])

        XCTAssertEqual(split.readable, [there])
        XCTAssertEqual(split.refused, [missing])
    }
}
#endif
