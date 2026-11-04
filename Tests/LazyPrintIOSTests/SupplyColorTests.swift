#if os(iOS)
import XCTest
@testable import LazyPrintIOS

// The colors printers report for their ink and toner, as the supply bars read them.

final class SupplyColorTests: XCTestCase {
    func test_hexColor_isReadAsThreeChannels() throws {
        let cyan = try XCTUnwrap(SupplyColor.components("#00AEEF"))

        XCTAssertEqual(cyan.red, 0, accuracy: 0.001)
        XCTAssertEqual(cyan.green, 174.0 / 255, accuracy: 0.001)
        XCTAssertEqual(cyan.blue, 239.0 / 255, accuracy: 0.001)
    }

    func test_anythingElse_isNotAColor() {
        XCTAssertNil(SupplyColor.components(nil))
        XCTAssertNil(SupplyColor.components(""))
        XCTAssertNil(SupplyColor.components("00AEEF"))
        XCTAssertNil(SupplyColor.components("#00AEE"))
        XCTAssertNil(SupplyColor.components("#00AEEFFF"))
        XCTAssertNil(SupplyColor.components("#GGGGGG"))
        XCTAssertNil(SupplyColor.components("cyan"))
    }

    func test_blackInk_isNearBlack_andYellowIsNot() throws {
        XCTAssertTrue(SupplyColor.isNearBlack(try XCTUnwrap(SupplyColor.components("#231F20"))))
        XCTAssertFalse(SupplyColor.isNearBlack(try XCTUnwrap(SupplyColor.components("#FFF200"))))
        XCTAssertFalse(SupplyColor.isNearBlack(try XCTUnwrap(SupplyColor.components("#EC008C"))))
    }
}
#endif
