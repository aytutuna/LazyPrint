import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppCodecTests.cs: the same cases.

final class IppCodecTests: XCTestCase {

    private func roundtrip(_ message: IppMessage) throws -> IppMessage {
        try IppMessage.decode(message.encoded()).message
    }

    private func single(_ attributes: IppAttribute...) -> IppMessage {
        IppMessage(version: .v20, code: 0, requestId: 7, groups: [IppGroup(tag: IppTag.printerAttributes, attributes: attributes)])
    }

    private func assertBadResponse(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try IppMessage.decode(data), file: file, line: line) { error in
            XCTAssertEqual(error as? PrintError, .badResponse, file: file, line: line)
        }
    }

    func test_encoded_smallRequest_isTheBytesOfRfc8010() {
        let message = IppMessage(version: .v20, code: 0x000B, requestId: 1,
                                 groups: [IppGroup(tag: IppTag.operationAttributes,
                                                   attributes: [IppAttribute("attributes-charset", .charset("utf-8"))])])
        var expected: [UInt8] = [0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x01, 0x01, 0x47, 0x00, 0x12]
        expected += Array("attributes-charset".utf8)
        expected += [0x00, 0x05]
        expected += Array("utf-8".utf8)
        expected.append(0x03)
        XCTAssertEqual([UInt8](message.encoded()), expected)
    }

    func test_roundtrip_everyValueType_isKept() throws {
        let message = single(
            IppAttribute("i", .integer(-5), .integer(70000)),
            IppAttribute("b", .boolean(true), .boolean(false)),
            IppAttribute("e", .enumValue(4)),
            IppAttribute("o", .octets(Data([0, 1, 2, 255]))),
            IppAttribute("d", .dateTime(Data([0x07, 0xEA, 11, 3, 10, 20, 30, 4, UInt8(ascii: "+"), 1, 0]))),
            IppAttribute("r", .resolution(x: 600, y: 300, units: 3)),
            IppAttribute("g", .range(1, 999)),
            IppAttribute("t", .text("Grüße 日本")),
            IppAttribute("n", .name("job")),
            IppAttribute("k", .keyword("one-sided"), .keyword("two-sided-long-edge")),
            IppAttribute("u", .uri("ipp://printer.local:631/ipp/print")),
            IppAttribute("s", .uriScheme("ipp")),
            IppAttribute("c", .charset("utf-8")),
            IppAttribute("l", .language("en")),
            IppAttribute("m", .mimeType("application/pdf")),
            IppAttribute("x", .outOfBand(IppTag.unsupported)),
            IppAttribute("y", .outOfBand(IppTag.unknown)),
            IppAttribute("z", .outOfBand(IppTag.noValue)))
        XCTAssertEqual(try roundtrip(message), message)
    }

    func test_roundtrip_collections_keepMembersNestingAndAdditionalValues() throws {
        let size = IppValue.collection([
            IppAttribute("x-dimension", .integer(21000)),
            IppAttribute("y-dimension", .integer(29700)),
        ])
        let first = IppValue.collection([
            IppAttribute("media-size", size),
            IppAttribute("media-type", .keyword("stationery"), .keyword("labels")),
        ])
        let second = IppValue.collection([IppAttribute("media-top-margin", .integer(0))])
        let message = single(IppAttribute("media-col-database", first, second), IppAttribute("after", .integer(1)))
        XCTAssertEqual(try roundtrip(message), message)
    }

    func test_encoded_collection_hasMemberNamesAndEndCollectionAsRfc8010() {
        let collection = IppValue.collection([IppAttribute("x-dimension", .integer(5))])
        let bytes = [UInt8](single(IppAttribute("c", collection)).encoded())
        var body: [UInt8] = [0x34, 0x00, 0x01, UInt8(ascii: "c"), 0x00, 0x00, 0x4A, 0x00, 0x00, 0x00, 0x0B]
        body += Array("x-dimension".utf8)
        body += [0x21, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05]
        body += [0x37, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(Array(bytes[9..<(bytes.count - 1)]), body)
    }

    func test_roundtrip_unknownTagsAndOddLengths_areKeptAsTheyCame() throws {
        let message = single(
            IppAttribute("a", .unknown(tag: 0x7F, Data([1, 2, 3]))),
            IppAttribute("b", .unknown(tag: IppTag.integer, Data([1, 2, 3]))),
            IppAttribute("c", .unknown(tag: 0x15, Data())),
            IppAttribute("d", .unknown(tag: IppTag.boolean, Data())))
        XCTAssertEqual(try roundtrip(message), message)
    }

    func test_roundtrip_anyDelimiterGroup_isKept() throws {
        let message = IppMessage(version: .v11, code: 0x0402, requestId: 99, groups: [
            IppGroup(tag: IppTag.operationAttributes, attributes: [IppAttribute("a", .integer(1))]),
            IppGroup(tag: 0x07, attributes: [IppAttribute("b", .integer(2))]),
            IppGroup(tag: IppTag.unsupportedAttributes, attributes: [IppAttribute("c", .outOfBand(IppTag.unsupported))]),
            IppGroup(tag: IppTag.jobAttributes, attributes: []),
        ])
        XCTAssertEqual(try roundtrip(message), message)
    }

    func test_decode_textAndNameWithLanguage_dropTheLanguage() throws {
        var raw: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x35, 0x00, 0x01]
        raw += Array("t".utf8)
        raw += [0x00, 0x09, 0x00, 0x02]
        raw += Array("en".utf8)
        raw += [0x00, 0x03]
        raw += Array("abc".utf8)
        raw += [0x36, 0x00, 0x01]
        raw += Array("n".utf8)
        raw += [0x00, 0x09, 0x00, 0x02]
        raw += Array("de".utf8)
        raw += [0x00, 0x03]
        raw += Array("xyz".utf8)
        raw += [0x03, 0xAA, 0xBB]
        let data = Data(raw)
        let (message, offset) = try IppMessage.decode(data)
        XCTAssertEqual(message["t"]?.values[0], .text("abc"))
        XCTAssertEqual(message["n"]?.values[0], .name("xyz"))
        XCTAssertEqual(offset, data.count - 2)
        XCTAssertEqual(message.version, IppVersion(major: 1, minor: 1))
    }

    func test_decode_requestFollowedByDocument_givesTheDocumentOffset() throws {
        let message = single(IppAttribute("a", .integer(1)))
        let bytes = message.encoded() + Data("%PDF-1.7".utf8)
        let (decoded, offset) = try IppMessage.decode(bytes)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(String(decoding: bytes.suffix(from: bytes.startIndex + offset), as: UTF8.self), "%PDF-1.7")
    }

    func test_decode_everyCutOfAFixture_isABadResponse() throws {
        let data = try IppFixtures.printer("epson-ecotank")
        for length in 0..<data.count {
            assertBadResponse(data.prefix(length))
        }
    }

    func test_decode_notIpp_isABadResponse() {
        assertBadResponse(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        assertBadResponse(Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03]))
    }

    func test_decode_valueWithoutAName_isABadResponseWhenNothingPrecedesIt() {
        assertBadResponse(Data([0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x21, 0x00, 0x00, 0x00, 0x04, 0, 0, 0, 1, 0x03]))
    }

    func test_isSuccess_codesBelow0x0100() {
        func with(_ code: UInt16) -> IppMessage { IppMessage(version: .v20, code: code, requestId: 1, groups: []) }
        XCTAssertTrue(with(0x0000).isSuccess)
        XCTAssertTrue(with(0x0001).isSuccess)
        XCTAssertTrue(with(0x0002).isSuccess)
        XCTAssertFalse(with(0x0400).isSuccess)
        XCTAssertFalse(with(0x0507).isSuccess)
    }

    func test_subscript_findsTheFirstAttributeOutsideTheUnsupportedGroup() {
        let message = IppMessage(version: .v20, code: 0x040B, requestId: 1, groups: [
            IppGroup(tag: IppTag.operationAttributes, attributes: [IppAttribute("x", .integer(1))]),
            IppGroup(tag: IppTag.unsupportedAttributes,
                     attributes: [IppAttribute("copies", .integer(9)), IppAttribute("sides", .outOfBand(IppTag.unsupported))]),
            IppGroup(tag: IppTag.jobAttributes,
                     attributes: [IppAttribute("copies", .integer(2)), IppAttribute("copies", .integer(3))]),
        ])
        XCTAssertEqual(message["copies"]?.values[0], .integer(2))
        XCTAssertNil(message["sides"])
        XCTAssertNil(message["missing"])
    }

    func test_decode_everyPrinterFixture_readsToTheEndAndEncodesBack() throws {
        for name in IppFixtures.printerNames {
            let data = try IppFixtures.printer(name)
            let (message, offset) = try IppMessage.decode(data)
            XCTAssertTrue(message.isSuccess, name)
            XCTAssertEqual(offset, data.count, name)
            XCTAssertEqual(try IppMessage.decode(message.encoded()).message, message, name)
            // The fixtures come from the separate Python encoder. Brother's has values with a language, which the codec drops.
            if name != "brother-laser" {
                XCTAssertEqual(message.encoded(), data, name)
            }
        }
    }
}
