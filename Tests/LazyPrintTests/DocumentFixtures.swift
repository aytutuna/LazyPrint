import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit

// Mirrors DocumentFixtures and Pixels in windows/LazyPrint.App.Tests/DocumentLoaderTests.cs.

enum DocumentFixtures {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("Documents")

    /// A file in Tests/Fixtures/Documents.
    static func url(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    static func open(_ name: String) throws -> OpenedDocument {
        try DocumentLoader().load(url(name))
    }
}

typealias Rgb = (r: Int, g: Int, b: Int)

enum Pixels {
    static let red: Rgb = (255, 0, 0)
    static let green: Rgb = (0, 153, 0)
    static let blue: Rgb = (0, 0, 255)
    static let yellow: Rgb = (255, 255, 0)
    static let white: Rgb = (255, 255, 255)
    static let black: Rgb = (0, 0, 0)

    static func at(_ bitmap: SheetBitmap, _ x: Int, _ y: Int) -> Rgb {
        let row = bitmap.row(y)
        if bitmap.bytesPerPixel == 1 { return (Int(row[x]), Int(row[x]), Int(row[x])) }
        return (Int(row[x * 3]), Int(row[x * 3 + 1]), Int(row[x * 3 + 2]))
    }

    static func assertColor(_ expected: Rgb, _ bitmap: SheetBitmap, _ x: Int, _ y: Int, tolerance: Int = 16,
                            file: StaticString = #filePath, line: UInt = #line) {
        let actual = at(bitmap, x, y)
        let close = abs(actual.r - expected.r) <= tolerance && abs(actual.g - expected.g) <= tolerance
            && abs(actual.b - expected.b) <= tolerance
        XCTAssertTrue(close, "Pixel (\(x), \(y)) is \(actual), expected \(expected)", file: file, line: line)
    }
}

extension XCTestCase {
    /// A path in the temp folder that is removed when the test ends.
    func tempURL(_ ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazyprint-\(UUID().uuidString).\(ext)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A one-colour picture.
    func solidImage(_ color: Rgb, width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// A picture file of the given type with one frame per colour.
    func writePicture(_ type: UTType, ext: String, colors: [Rgb]) throws -> URL {
        let url = tempURL(ext)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, colors.count, nil))
        for color in colors {
            CGImageDestinationAddImage(destination, try solidImage(color, width: 40, height: 20), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A one-page PDF of the given size, filled with one colour.
    func writePDF(width: Double, height: Double, color: Rgb) throws -> URL {
        let url = tempURL("pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
