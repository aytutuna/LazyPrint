#if os(iOS)
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintIOS

// The document loader tells a picture by its extension, so a photo from the library is named with its type's.

final class PhotoNamesTests: XCTestCase {
    func test_aPhoto_isNamedByItsNumberAndType() {
        XCTAssertEqual(PhotoNames.make(number: 1, type: .heic), "Photo 1.heic")
        XCTAssertEqual(PhotoNames.make(number: 12, type: .png), "Photo 12.png")
    }

    func test_aPhotoOfAnUnknownType_isAJpeg() {
        XCTAssertEqual(PhotoNames.make(number: 3, type: nil), "Photo 3.jpg")
    }

    func test_aPhotoWithADate_isNamedByIt() {
        let date = DateComponents(calendar: Calendar.current, year: 2026, month: 11, day: 11, hour: 14, minute: 3, second: 22).date!
        XCTAssertEqual(PhotoNames.make(date: date, type: .heic), "Photo 2026-11-11 14.03.22.heic")
    }

    func test_numbering_goesOnPastTheHighestPhotoInTheList() {
        XCTAssertEqual(PhotoNames.highest(in: []), 0)
        XCTAssertEqual(PhotoNames.highest(in: ["Scan.pdf", "Photo 2.jpg", "Photo 11.heic", "Photo 3.png"]), 11)
        XCTAssertEqual(PhotoNames.highest(in: ["Photo 2026-11-11 14.03.22.heic", "Photo.jpg"]), 0)
    }

    func test_theNames_areOnesTheLoaderReadsAsPictures() {
        for type in [UTType.jpeg, .heic, .png] {
            let name = PhotoNames.make(number: 1, type: type)
            let read = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
            XCTAssertEqual(read?.conforms(to: .image), true, name)
        }
    }
}
#endif
