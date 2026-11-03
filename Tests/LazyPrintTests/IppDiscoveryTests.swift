import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppDiscoveryTests.cs: the same cases (the TXT record is the
// shared fixture Tests/Fixtures/Ipp/txt-hp.txt; a C# theory is one test here that loops over the same
// rows). Covers what discovery hands over: TXT records, the addresses users type, and how a printer's
// DNS-SD services become one endpoint. The request URL keeps an IPv6 zone here, written "%25" + zone.

final class IppDiscoveryTests: XCTestCase {
    // MARK: - TXT records

    /// A TXT record in the shape HP all-in-ones advertise.
    private func hpTxt() throws -> [String] {
        try IppFixtures.lines(IppFixtures.hpTxtFile)
    }

    func testTxtRecordReadsTheIppKeys() throws {
        let txt = IppTxtRecord.parse(try hpTxt())
        XCTAssertEqual(txt.resourcePath, "ipp/print")
        XCTAssertEqual(txt.model, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(txt.product, "(HP Color LaserJet MFP M479fdw)")
        XCTAssertEqual(txt.uuid, "564e4333-4230-3538-3930-a0b3cce51a2b")
        XCTAssertEqual(txt.adminUrl, "http://HPA1B2C3.local./#hId-pgAirPrint")
        XCTAssertEqual(txt.note, "Office")
        XCTAssertEqual(txt.color, true)
        XCTAssertEqual(txt.duplex, true)
        XCTAssertEqual(txt.documentFormats, ["application/octet-stream", "application/pdf", "image/jpeg", "image/urf", "image/pwg-raster"])
        XCTAssertEqual(txt.urf, ["CP1", "MT1-2-8-9-10-11", "OB10", "PQ3-4-5", "RS300-600", "SRGB24", "W8", "DM1", "IS1-4", "V1.4", "IFU0"])
        XCTAssertEqual(txt.tls, "1.2")
        XCTAssertEqual(txt.kind, ["document", "envelope", "photo"])
        XCTAssertEqual(txt.paperMax, "legal-A4")
    }

    func testTxtRecordDefaultsAndOddEntries() {
        let empty = IppTxtRecord.parse([])
        XCTAssertEqual(empty.resourcePath, "ipp/print")
        XCTAssertNil(empty.model)
        XCTAssertNil(empty.uuid)
        XCTAssertNil(empty.color)
        XCTAssertNil(empty.duplex)
        XCTAssertEqual(empty.documentFormats, [])
        XCTAssertEqual(empty.urf, [])

        let odd = IppTxtRecord.parse([
            "RP=/printers/office/",   // keys ignore case; slashes are trimmed
            "ty=First", "ty=Second",  // only the first occurrence counts
            "duplex=f", "flag", "=novalue", "kind=Document, PHOTO ,document",
            "URF=none",
        ])
        XCTAssertEqual(odd.resourcePath, "printers/office")
        XCTAssertEqual(odd.model, "First")
        XCTAssertEqual(odd.duplex, false)
        XCTAssertEqual(odd.kind, ["document", "photo"])
        XCTAssertEqual(odd.urf, [])

        // A present but empty rp means the root of the host.
        XCTAssertEqual(IppTxtRecord.parse(["rp="]).resourcePath, "")
        XCTAssertNil(IppTxtRecord.parse(["Color=maybe"]).color)
    }

    func testUuidKeysCompareTheFormsPrintersUse() {
        let key = "564e4333423035383930a0b3cce51a2b"
        XCTAssertEqual(IppTxtRecord.uuidKey("564E4333-4230-3538-3930-A0B3CCE51A2B"), key)
        XCTAssertEqual(IppTxtRecord.uuidKey("urn:uuid:564e4333-4230-3538-3930-a0b3cce51a2b"), key)
        XCTAssertEqual(IppTxtRecord.uuidKey("{564e4333-4230-3538-3930-a0b3cce51a2b}"), key)
        XCTAssertNil(IppTxtRecord.uuidKey("  "))
        XCTAssertNil(IppTxtRecord.uuidKey(nil))
    }

    // MARK: - Addresses users type

    private struct AddressRow {
        let text: String
        let secure: Bool
        let host: String
        let port: Int
        let path: String
        let canonical: String
        let printerUri: String
        let requestUri: String
    }

    func testAddressesParseAndNormalize() throws {
        let rows = [
            AddressRow(text: "192.168.1.50", secure: false, host: "192.168.1.50", port: 631, path: "ipp/print", canonical: "192.168.1.50", printerUri: "ipp://192.168.1.50:631/ipp/print", requestUri: "http://192.168.1.50:631/ipp/print"),
            AddressRow(text: " 192.168.001.050 ", secure: false, host: "192.168.1.50", port: 631, path: "ipp/print", canonical: "192.168.1.50", printerUri: "ipp://192.168.1.50:631/ipp/print", requestUri: "http://192.168.1.50:631/ipp/print"),
            AddressRow(text: "Printer.Local", secure: false, host: "printer.local", port: 631, path: "ipp/print", canonical: "printer.local", printerUri: "ipp://printer.local:631/ipp/print", requestUri: "http://printer.local:631/ipp/print"),
            AddressRow(text: "epson.local:8631", secure: false, host: "epson.local", port: 8631, path: "ipp/print", canonical: "epson.local:8631", printerUri: "ipp://epson.local:8631/ipp/print", requestUri: "http://epson.local:8631/ipp/print"),
            AddressRow(text: "ipp://192.168.1.50", secure: false, host: "192.168.1.50", port: 631, path: "ipp/print", canonical: "192.168.1.50", printerUri: "ipp://192.168.1.50:631/ipp/print", requestUri: "http://192.168.1.50:631/ipp/print"),
            AddressRow(text: "ipps://10.0.0.7", secure: true, host: "10.0.0.7", port: 631, path: "ipp/print", canonical: "ipps://10.0.0.7", printerUri: "ipps://10.0.0.7:631/ipp/print", requestUri: "https://10.0.0.7:631/ipp/print"),
            AddressRow(text: "ipps://10.0.0.7:8443/ipp/print/", secure: true, host: "10.0.0.7", port: 8443, path: "ipp/print", canonical: "ipps://10.0.0.7:8443", printerUri: "ipps://10.0.0.7:8443/ipp/print", requestUri: "https://10.0.0.7:8443/ipp/print"),
            AddressRow(text: "ipp://host:8631/printers/Office", secure: false, host: "host", port: 8631, path: "printers/Office", canonical: "ipp://host:8631/printers/Office", printerUri: "ipp://host:8631/printers/Office", requestUri: "http://host:8631/printers/Office"),
            AddressRow(text: "http://10.0.0.7", secure: false, host: "10.0.0.7", port: 80, path: "ipp/print", canonical: "10.0.0.7:80", printerUri: "ipp://10.0.0.7:80/ipp/print", requestUri: "http://10.0.0.7/ipp/print"),
            AddressRow(text: "https://10.0.0.7", secure: true, host: "10.0.0.7", port: 443, path: "ipp/print", canonical: "ipps://10.0.0.7:443", printerUri: "ipps://10.0.0.7:443/ipp/print", requestUri: "https://10.0.0.7/ipp/print"),
            AddressRow(text: "http://host:9090/printers/a%20b", secure: false, host: "host", port: 9090, path: "printers/a b", canonical: "ipp://host:9090/printers/a%20b", printerUri: "ipp://host:9090/printers/a%20b", requestUri: "http://host:9090/printers/a%20b"),
            AddressRow(text: "10.0.0.7/ipp/print", secure: false, host: "10.0.0.7", port: 631, path: "ipp/print", canonical: "10.0.0.7", printerUri: "ipp://10.0.0.7:631/ipp/print", requestUri: "http://10.0.0.7:631/ipp/print"),
            // The request URL spells the zone "%25" + zone (RFC 6874); System.Uri leaves it out of its text.
            AddressRow(text: "[fe80::1%12]:8631", secure: false, host: "fe80::1%12", port: 8631, path: "ipp/print", canonical: "[fe80::1%12]:8631", printerUri: "ipp://[fe80::1]:8631/ipp/print", requestUri: "http://[fe80::1%2512]:8631/ipp/print"),
            AddressRow(text: "2001:DB8::5", secure: false, host: "2001:db8::5", port: 631, path: "ipp/print", canonical: "[2001:db8::5]", printerUri: "ipp://[2001:db8::5]:631/ipp/print", requestUri: "http://[2001:db8::5]:631/ipp/print"),
            AddressRow(text: "[2001:db8::5]", secure: false, host: "2001:db8::5", port: 631, path: "ipp/print", canonical: "[2001:db8::5]", printerUri: "ipp://[2001:db8::5]:631/ipp/print", requestUri: "http://[2001:db8::5]:631/ipp/print"),
            AddressRow(text: "ipps://[2001:db8::5]", secure: true, host: "2001:db8::5", port: 631, path: "ipp/print", canonical: "ipps://[2001:db8::5]", printerUri: "ipps://[2001:db8::5]:631/ipp/print", requestUri: "https://[2001:db8::5]:631/ipp/print"),
            AddressRow(text: "https://[2001:db8::5]:9443", secure: true, host: "2001:db8::5", port: 9443, path: "ipp/print", canonical: "ipps://[2001:db8::5]:9443", printerUri: "ipps://[2001:db8::5]:9443/ipp/print", requestUri: "https://[2001:db8::5]:9443/ipp/print"),
        ]
        for row in rows {
            var error = ""
            let address = try XCTUnwrap(PrinterAddress.tryParse(row.text, error: &error), "\(row.text): \(error)")
            XCTAssertEqual(address.secure, row.secure, row.text)
            XCTAssertEqual(address.host, row.host, row.text)
            XCTAssertEqual(address.port, row.port, row.text)
            XCTAssertEqual(address.resourcePath, row.path, row.text)
            XCTAssertEqual(address.description, row.canonical, row.text)
            XCTAssertEqual(address.printerUri, row.printerUri, row.text)
            XCTAssertEqual(address.requestURLText, row.requestUri, row.text)
            XCTAssertNotNil(address.requestURL, row.text)
            // The canonical text reads back as the same address.
            XCTAssertEqual(address, try PrinterAddress.parse(row.canonical), row.text)
        }
    }

    func testZonedIPv6AddressesStayUsable() throws {
        let address = try PrinterAddress.parse("[fe80::1%12]:8631")
        XCTAssertEqual(address.host, "fe80::1%12")
        XCTAssertEqual(address.port, 8631)
        XCTAssertEqual(address.authority, "[fe80::1%12]:8631")
        XCTAssertEqual(IppUrlText.authority(address.requestURLText), "[fe80::1%12]:8631")
    }

    /// The loopback interface's name, as the system's interface-name lookup takes it.
    private let loopbackName = "lo0"

    func testNamedZonesReadAsTheirInterfaceIndex() throws {
        let index = if_nametoindex(loopbackName)
        XCTAssertGreaterThan(index, 0)
        let address = try PrinterAddress.parse("[fe80::1%\(loopbackName)]:8631")
        XCTAssertEqual(address.host, "fe80::1%\(index)")
        XCTAssertEqual(address.description, "[fe80::1%\(index)]:8631")
        XCTAssertEqual(address, try PrinterAddress.parse(address.description))
        XCTAssertEqual(try PrinterAddress.parse("ipp://[fe80::1%\(loopbackName)]:8631").host, "fe80::1%\(index)")
        // A zone of 0 or none at all is no zone; one that names no interface is refused, not dropped.
        XCTAssertEqual(try PrinterAddress.parse("[2001:db8::1%0]").host, "2001:db8::1")
        XCTAssertEqual(try PrinterAddress.parse("[2001:db8::1%]").host, "2001:db8::1")
        var error = ""
        XCTAssertNil(PrinterAddress.tryParse("[fe80::1%nosuch0]", error: &error))
    }

    func testBadAddressesSayWhatIsWrong() {
        let linkLocal = "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12."
        let scheme = "Use an address that starts with ipp://, ipps://, http:// or https://, or just the IP address or host name."
        let port = "The port must be a number from 1 to 65535."
        let rows: [(String, String)] = [
            ("", "Enter the printer's IP address or host name."),
            ("   ", "Enter the printer's IP address or host name."),
            ("192.168.1", "\"192.168.1\" is not a valid IP address or host name."),
            ("300.1.1.1", "\"300.1.1.1\" is not a valid IP address or host name."),
            ("printer:0", port),
            ("printer:70000", port),
            ("printer:ipp", port),
            ("my printer", "An address cannot contain spaces."),
            ("ftp://10.0.0.7", scheme),
            ("socket://10.0.0.7:9100", scheme),
            ("ipp://user:pw@10.0.0.7", "Leave out the user name and password; printers do not need them."),
            ("[fe80::1", "An IPv6 address in brackets needs its closing \"]\"."),
            ("[fe80::1]x", "That is not a valid address."),
            ("bad_host!", "\"bad_host!\" is not a valid IP address or host name."),
            ("[fe80::1%nosuch0]", "\"fe80::1%nosuch0\" is not a valid IP address or host name."),
            ("fe80::1%99999999999", "\"fe80::1%99999999999\" is not a valid IP address or host name."),
            ("ipp://[fe80::1%nosuch0]:8631", "That is not a valid address."),
            ("fe80::1a2b:3c4d:5e6f:7a8b", linkLocal),
            ("[fe80::1%0]:8631", linkLocal),
            ("ipp://[fe80::1]", linkLocal),
        ]
        for (text, message) in rows {
            var error = ""
            XCTAssertNil(PrinterAddress.tryParse(text, error: &error), text)
            XCTAssertEqual(error, message, text)
            XCTAssertThrowsError(try PrinterAddress.parse(text), text) { thrown in
                XCTAssertEqual((thrown as? PrinterAddressError)?.message, message, text)
            }
        }
    }

    func testAddressesCompareByTheirCanonicalForm() throws {
        XCTAssertEqual(try PrinterAddress.parse("ipp://PRINTER.local:631/ipp/print"), try PrinterAddress.parse("printer.local"))
        XCTAssertNotEqual(try PrinterAddress.parse("ipps://printer.local"), try PrinterAddress.parse("printer.local"))
        XCTAssertNotEqual(try PrinterAddress.parse("printer.local:8631"), try PrinterAddress.parse("printer.local"))
        XCTAssertNotEqual(try PrinterAddress.parse("printer.local/printers/a"), try PrinterAddress.parse("printer.local"))
        XCTAssertNil(PrinterAddress.create(secure: false, host: "host", port: 0, resourcePath: "ipp/print"))
        XCTAssertNil(PrinterAddress.create(secure: false, host: "not a host", port: 631, resourcePath: "ipp/print"))
        XCTAssertEqual(PrinterAddress.create(secure: false, host: "host", port: 631, resourcePath: "")?.printerUri, "ipp://host:631/")
    }

    func testABareHostThatDidNotAnswerIsTriedOverIpps() throws {
        let plain = try PrinterAddress.parse("192.168.1.50")
        XCTAssertEqual(plain.httpsFallback(typed: "192.168.1.50")?.description, "ipps://192.168.1.50")
        XCTAssertNil(plain.httpsFallback(typed: "ipp://192.168.1.50"))
        XCTAssertNil(plain.httpsFallback(typed: "192.168.1.50/ipp/print"))
        XCTAssertNil(try PrinterAddress.parse("192.168.1.50:8631").httpsFallback(typed: "192.168.1.50:8631"))
        XCTAssertNil(try PrinterAddress.parse("ipps://192.168.1.50").httpsFallback(typed: "ipps://192.168.1.50"))
        XCTAssertNil(try PrinterAddress.parse("192.168.1.50/printers/a").httpsFallback(typed: "192.168.1.50"))
    }

    // MARK: - Services to endpoints

    private func service(_ instance: String, secure: Bool, _ addresses: [String], _ txt: [String],
                         port: Int = 631, host: String? = "HPA1B2C3.local") -> IppService {
        IppService(id: "id-\(instance)-\(secure)", instanceName: instance, secure: secure, hostName: host,
                   addresses: addresses, port: port, textAttributes: txt)
    }

    func testBothServicesOfOnePrinterMergeIppsFirst() throws {
        let hp = try hpTxt()
        let endpoints = IppEndpoint.choose([
            service("HP M479 (A1B2C3)", secure: false, ["fe80::1", "192.168.1.20", "2001:db8::20"], hp),
            service("HP M479 (A1B2C3)", secure: true, ["192.168.1.20"], hp),
        ])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.key, "uuid:564e4333423035383930a0b3cce51a2b")
        XCTAssertEqual(endpoint.name, "HP Color LaserJet MFP M479fdw")
        XCTAssertEqual(endpoint.uuid, "564e4333-4230-3538-3930-a0b3cce51a2b")
        // ipps first; IPv4, then the host name, then IPv6; link-local without a zone skipped.
        XCTAssertEqual(endpoint.addresses.map { $0.description }, [
            "ipps://192.168.1.20", "ipps://hpa1b2c3.local",
            "192.168.1.20", "hpa1b2c3.local", "[2001:db8::20]",
        ])
    }

    func testEndpointsKeepTheResourcePathPortAndZonedAddresses() throws {
        let endpoints = IppEndpoint.choose([
            service("Canon", secure: false, ["fe80::5%7"], ["rp=/printers/Canon", "ty=Canon MF743C"], port: 8631, host: nil),
        ])
        XCTAssertEqual(endpoints.count, 1)
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoint.key, "name:canon")
        XCTAssertNil(endpoint.uuid)
        XCTAssertEqual(endpoint.addresses.count, 1)
        let address = try XCTUnwrap(endpoint.addresses.first)
        XCTAssertEqual(address.printerUri, "ipp://[fe80::5]:8631/printers/Canon")
        XCTAssertEqual(address.host, "fe80::5%7")
    }

    func testAddressesWhoseZoneNamesNoInterfaceAreSkipped() throws {
        let endpoints = IppEndpoint.choose([
            service("Canon", secure: false, ["fe80::5%nosuch0", "2001:db8::9%nosuch0", "fe80::6%\(loopbackName)"],
                    ["ty=Canon MF743C"], host: nil),
        ])
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0].addresses.map { $0.description }, ["[fe80::6%\(if_nametoindex(loopbackName))]"])
    }

    func testPrintersStayApartAndUnusableServicesAreDropped() throws {
        let other = ["ty=Epson ET-4850", "UUID=cfe92100-67c4-11d4-a45f-f8d0273e1a0b"]
        let endpoints = IppEndpoint.choose([
            service("HP", secure: false, ["192.168.1.20"], try hpTxt()),
            service("Epson", secure: false, ["192.168.1.30"], other),
            service("Broken port", secure: false, ["192.168.1.40"], ["ty=X"], port: 70000),
            service("No address", secure: false, ["fe80::9"], ["ty=Y"], host: nil),
            // The _ipps service of the HP without a UUID of its own: the instance name ties it.
            service("HP", secure: true, ["192.168.1.20"], ["ty=HP Color LaserJet MFP M479fdw"]),
        ])
        XCTAssertEqual(endpoints.map { $0.name }, ["HP Color LaserJet MFP M479fdw", "Epson ET-4850"])
        XCTAssertEqual(endpoints[0].addresses[0].description, "ipps://192.168.1.20")
        XCTAssertEqual(endpoints[1].key, "uuid:cfe9210067c411d4a45ff8d0273e1a0b")
    }

    func testWithoutAModelTheInstanceNameIsTheName() throws {
        let endpoints = IppEndpoint.choose([service("Office printer", secure: false, ["10.0.0.9"], [])])
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0].name, "Office printer")
        XCTAssertEqual(endpoints[0].txt.resourcePath, "ipp/print")
    }
}
