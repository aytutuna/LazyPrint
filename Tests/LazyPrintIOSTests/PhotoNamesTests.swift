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

    func test_theNames_areOnesTheLoaderReadsAsPictures() {
        for type in [UTType.jpeg, .heic, .png] {
            let name = PhotoNames.make(number: 1, type: type)
            let read = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)
            XCTAssertEqual(read?.conforms(to: .image), true, name)
        }
    }
}
#endif
