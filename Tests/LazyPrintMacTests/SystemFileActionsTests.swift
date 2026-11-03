#if os(macOS)
import AppKit
import XCTest
@testable import LazyPrintMac

// How the URLs and menus are built. NSWorkspace itself is not wrapped or tested.

final class SystemFileActionsTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    func test_lazyScanURL_isTheSchemeAlone() {
        let url = SystemFileActions.lazyScanURL
        XCTAssertEqual(url.scheme, "lazyscan")
        XCTAssertNil(url.host)
        XCTAssertEqual(url.absoluteString, "lazyscan:")
    }

    func test_anchorPoint_atThePointerWhenItIsInside() {
        let pointer = NSPoint(x: 120, y: 450)
        XCTAssertEqual(SystemFileActions.anchorPoint(pointer: pointer, bounds: bounds), pointer)
    }

    func test_anchorPoint_centreWhenThePointerIsOutside() {
        for pointer in [NSPoint(x: -5, y: 300), NSPoint(x: 400, y: 900), NSPoint(x: 1200, y: -40)] {
            XCTAssertEqual(SystemFileActions.anchorPoint(pointer: pointer, bounds: bounds), NSPoint(x: 400, y: 300), "\(pointer)")
        }
    }

    func test_appTitle_marksTheDefault() {
        XCTAssertEqual(SystemFileActions.appTitle("Preview", isDefault: true), "Preview (default)")
        XCTAssertEqual(SystemFileActions.appTitle("Preview", isDefault: false), "Preview")
    }
}
#endif
