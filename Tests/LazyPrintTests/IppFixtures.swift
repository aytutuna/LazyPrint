import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppFixtures.cs: the Get-Printer-Attributes responses and golden requests in
// Tests/Fixtures/Ipp. Swift only reads them; the golden requests are written by the Windows tests.

enum IppFixtures {
    static let printerNames = ["hp-laserjet", "epson-ecotank", "brother-laser", "canon-pixma"]

    /// A TXT record in the shape HP all-in-ones advertise, one "key=value" entry per line.
    static let hpTxtFile = "txt-hp.txt"

    struct CertificateVector {
        let file: String
        let fingerprint: String
        let subject: String
    }

    /// Self-signed printer certificates (PEM) and the SHA-256 of their SubjectPublicKeyInfo.
    static let certificates = [
        CertificateVector(file: "certificate-rsa2048.pem",
                          fingerprint: "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c",
                          subject: "CN=Lazy Scan test scanner RSA-2048"),
        CertificateVector(file: "certificate-p256.pem",
                          fingerprint: "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4",
                          subject: "CN=Lazy Scan test scanner P-256"),
        CertificateVector(file: "certificate-p384.pem",
                          fingerprint: "c287be8b8476f2aaa5d6f61eee6f4a7b062c89222ad861abc1265383e5f8d9bb",
                          subject: "CN=Lazy Scan test scanner P-384"),
    ]

    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("Ipp")

    /// A fixture's file in Tests/Fixtures/Ipp.
    static func url(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A text fixture with LF line breaks, whatever a checkout did to them.
    static func text(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: url(name)), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// A text fixture's non-empty lines.
    static func lines(_ name: String) throws -> [String] {
        try text(name).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// The DER bytes of a PEM certificate fixture.
    static func certificateDER(_ name: String) throws -> Data {
        let body = try lines(name).filter { !$0.hasPrefix("-----") }.joined()
        return try XCTUnwrap(Data(base64Encoded: body), "\(name) is not a PEM certificate")
    }

    static func printer(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent("printers").appendingPathComponent(name + ".bin"))
    }

    static func capabilities(_ name: String) throws -> PrinterCapabilities {
        PrinterCapabilities.from(try IppMessage.decode(try printer(name)).message)
    }

    /// Compares bytes with the golden file Tests/Fixtures/Ipp/requests/name.bin.
    static func golden(_ name: String, _ actual: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try Data(contentsOf: folder.appendingPathComponent("requests").appendingPathComponent(name + ".bin"))
        XCTAssertEqual(actual, expected, name, file: file, line: line)
    }
}
