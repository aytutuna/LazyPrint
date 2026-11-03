import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppRequestsTests.cs: the same cases. The golden files are written by the
// Windows tests (LAZYPRINT_WRITE_GOLDEN=1); these only compare.

final class IppRequestsTests: XCTestCase {
    private let uri = "ipp://printer.local:631/ipp/print"

    private let a4Entry: [IppAttribute] = [
        IppAttribute("media-bottom-margin", .integer(300)),
        IppAttribute("media-left-margin", .integer(300)),
        IppAttribute("media-right-margin", .integer(300)),
        IppAttribute("media-size", .collection([
            IppAttribute("x-dimension", .integer(21000)),
            IppAttribute("y-dimension", .integer(29700)),
        ])),
        IppAttribute("media-source", .keyword("main")),
        IppAttribute("media-top-margin", .integer(300)),
        IppAttribute("media-type", .keyword("stationery")),
    ]

    private func ticket(_ name: String = "Report.pdf") -> IppJobTicket {
        IppJobTicket(jobName: name, documentFormat: "application/pdf", copies: 1, sides: "one-sided", colorMode: "color",
                     media: IppMediaChoice(entry: nil, name: "iso_a4_210x297mm"))
    }

    private func names(_ message: IppMessage, _ group: UInt8) -> [String] {
        message.groups.first(where: { $0.tag == group })?.attributes.map { $0.name } ?? []
    }

    func test_getPrinterAttributes_isTheGoldenRequest() throws {
        try IppFixtures.golden("get-printer-attributes", IppRequests.getPrinterAttributes(printerUri: uri, userName: "anna").encoded())
    }

    func test_getPrinterAttributes_asVersion11_isTheGoldenRequest() throws {
        let request = IppRequests.downgraded(IppRequests.getPrinterAttributes(printerUri: uri, userName: "anna"))
        XCTAssertEqual(request.version, .v11)
        try IppFixtures.golden("get-printer-attributes-11", request.encoded())
    }

    func test_getPrinterAttributes_asksForAllAndTheMediaDatabase() {
        let request = IppRequests.getPrinterAttributes(printerUri: uri, userName: "anna")
        XCTAssertEqual(names(request, IppTag.operationAttributes),
                       ["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "requested-attributes"])
        XCTAssertEqual(request["requested-attributes"]?.values, [.keyword("all"), .keyword("media-col-database")])
        XCTAssertEqual(request.code, 0x000B)
        XCTAssertEqual(request.version, .v20)
    }

    func test_printJob_withAName_isTheGoldenRequest() throws {
        try IppFixtures.golden("print-job-pdf", IppRequests.printJob(printerUri: uri, userName: "anna", ticket: ticket()).encoded())
    }

    func test_printJob_withEveryChoice_isTheGoldenRequest() throws {
        let sheets = IppJobTicket(jobName: "Sheets", documentFormat: "image/pwg-raster", copies: 3, sides: "two-sided-long-edge",
                                  colorMode: "monochrome", media: IppMediaChoice(entry: a4Entry, name: "iso_a4_210x297mm"),
                                  quality: 5, scaling: "none", collatedCopies: true)
        try IppFixtures.golden("print-job-media-col", IppRequests.printJob(printerUri: uri, userName: "iPhone", ticket: sheets).encoded())
    }

    func test_printJob_longNonAsciiName_isTheGoldenRequest() throws {
        let long = ticket(String(repeating: "日", count: 100))
        try IppFixtures.golden("print-job-long-name", IppRequests.printJob(printerUri: uri, userName: "anna", ticket: long).encoded())
    }

    func test_printJob_attributeOrder_followsTheContract() {
        let sheets = IppJobTicket(jobName: "Sheets", documentFormat: "image/pwg-raster", copies: 3, sides: "two-sided-long-edge",
                                  colorMode: "monochrome", media: IppMediaChoice(entry: a4Entry, name: "iso_a4_210x297mm"),
                                  quality: 4, scaling: "none", collatedCopies: true)
        let request = IppRequests.printJob(printerUri: uri, userName: "anna", ticket: sheets)
        XCTAssertEqual(names(request, IppTag.operationAttributes),
                       ["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-name", "document-format"])
        XCTAssertEqual(names(request, IppTag.jobAttributes),
                       ["copies", "sides", "print-color-mode", "media-col", "print-quality", "print-scaling", "multiple-document-handling"])
        XCTAssertEqual(request.groups.map { $0.tag }, [IppTag.operationAttributes, IppTag.jobAttributes])
        XCTAssertEqual(request["print-quality"]?.values[0], .enumValue(4))
        XCTAssertEqual(request["multiple-document-handling"]?.values[0], .keyword("separate-documents-collated-copies"))
    }

    func test_printJob_defaults_leaveOutTheOptionalAttributes() {
        let request = IppRequests.printJob(printerUri: uri, userName: "anna", ticket: ticket())
        XCTAssertEqual(names(request, IppTag.jobAttributes), ["sides", "print-color-mode", "media"])
        XCTAssertEqual(request["media"]?.values[0], .keyword("iso_a4_210x297mm"))
        XCTAssertEqual(request.code, 0x0002)
    }

    func test_printJob_mediaEntry_isSentVerbatimAsMediaCol() {
        var withEntry = ticket()
        withEntry.media = IppMediaChoice(entry: a4Entry, name: "iso_a4_210x297mm")
        let request = IppRequests.printJob(printerUri: uri, userName: "anna", ticket: withEntry)
        XCTAssertNil(request["media"])
        XCTAssertEqual(request["media-col"]?.values[0], .collection(a4Entry))
    }

    func test_getJobAttributes_isTheGoldenRequest() throws {
        let request = IppRequests.getJobAttributes(printerUri: uri, userName: "anna", jobId: 42)
        XCTAssertEqual(names(request, IppTag.operationAttributes),
                       ["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-id", "requested-attributes"])
        try IppFixtures.golden("get-job-attributes", request.encoded())
    }

    func test_cancelJob_isTheGoldenRequest() throws {
        let request = IppRequests.cancelJob(printerUri: uri, userName: "anna", jobId: 42)
        XCTAssertEqual(names(request, IppTag.operationAttributes),
                       ["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-id"])
        try IppFixtures.golden("cancel-job", request.encoded())
    }

    func test_printerUri_isAlwaysIppOrIpps() {
        let cases = [
            ("http://printer.local/ipp/print", "ipp://printer.local/ipp/print"),
            ("HTTPS://printer.local:443/ipp/print", "ipps://printer.local:443/ipp/print"),
            ("ipp://printer.local:631/ipp/print", "ipp://printer.local:631/ipp/print"),
            ("ipps://printer.local/ipp/print", "ipps://printer.local/ipp/print"),
        ]
        for (typed, sent) in cases {
            let request = IppRequests.cancelJob(printerUri: typed, userName: "anna", jobId: 1)
            XCTAssertEqual(request["printer-uri"]?.values[0], .uri(sent), typed)
        }
    }

    func test_truncated_cutsAt255BytesWithoutSplittingACharacter() {
        XCTAssertEqual(IppRequests.truncated("short"), "short")
        XCTAssertEqual(IppRequests.truncated(String(repeating: "a", count: 300)).utf8.count, 255)

        let cjk = IppRequests.truncated(String(repeating: "日", count: 100))
        XCTAssertEqual(cjk.count, 85)
        XCTAssertEqual(cjk.utf8.count, 255)

        let emoji = IppRequests.truncated("a" + String(repeating: "\u{1F600}", count: 100))
        XCTAssertEqual(emoji.unicodeScalars.count, 1 + 63)
        XCTAssertEqual(emoji.utf8.count, 253)
    }

    func test_names_areCutInTheRequest() {
        let request = IppRequests.printJob(printerUri: uri, userName: String(repeating: "u", count: 400),
                                           ticket: ticket(String(repeating: "n", count: 400)))
        XCTAssertEqual(request["job-name"]?.values[0], .name(String(repeating: "n", count: 255)))
        XCTAssertEqual(request["requesting-user-name"]?.values[0], .name(String(repeating: "u", count: 255)))
    }
}
