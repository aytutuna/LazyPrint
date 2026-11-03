import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/SpkiFingerprintTests.cs: the same vectors, from the
// certificates in Tests/Fixtures/Ipp. The Windows-only case that makes certificates with .NET's
// CertificateRequest has no twin here, and the SubjectPublicKeyInfo of a certificate is checked
// against the fingerprint rather than against a platform call.

final class SpkiFingerprintTests: XCTestCase {
    private let p256File = "certificate-p256.pem"
    private let p256Fingerprint = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4"
    private let p256Text = "gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ"
    private let p256CheckCode = "218140"

    private var fingerprint: Data {
        var bytes: [UInt8] = []
        var index = p256Fingerprint.startIndex
        while index < p256Fingerprint.endIndex {
            let next = p256Fingerprint.index(index, offsetBy: 2)
            bytes.append(UInt8(p256Fingerprint[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    func testSharedCertificates_HaveTheSharedFingerprints() throws {
        // RSA-2048, P-256 and P-384, the key types printers use.
        for vector in IppFixtures.certificates {
            let der = try IppFixtures.certificateDER(vector.file)
            let digest = try XCTUnwrap(SpkiFingerprint.of(der), vector.file)
            XCTAssertEqual(SpkiFingerprint.hex(digest), vector.fingerprint, vector.file)
            let spki = try XCTUnwrap(SpkiFingerprint.subjectPublicKeyInfo(der), vector.file)
            XCTAssertEqual(SpkiFingerprint.hex(SpkiFingerprint.ofSubjectPublicKeyInfo(spki)), vector.fingerprint, vector.file)
            XCTAssertEqual(IppCertificates.fingerprint(certificateDER: der), vector.fingerprint, vector.file)
        }
    }

    func testFingerprint_HasItsHexAndTextForms() throws {
        let der = try IppFixtures.certificateDER(p256File)
        let spki = try XCTUnwrap(SpkiFingerprint.subjectPublicKeyInfo(der))
        let digest = try XCTUnwrap(SpkiFingerprint.of(der))
        XCTAssertEqual(digest.count, SpkiFingerprint.byteCount)
        XCTAssertEqual(SpkiFingerprint.hex(digest), p256Fingerprint)
        XCTAssertEqual(SpkiFingerprint.text(digest), p256Text)
        XCTAssertEqual(SpkiFingerprint.hex(SpkiFingerprint.ofSubjectPublicKeyInfo(spki)), p256Fingerprint)
    }

    func testP256Point_RebuildsTheSubjectPublicKeyInfo() throws {
        let spki = try XCTUnwrap(SpkiFingerprint.subjectPublicKeyInfo(try IppFixtures.certificateDER(p256File)))
        let point = Data(spki.suffix(SpkiFingerprint.p256PointByteCount))
        XCTAssertEqual(SpkiFingerprint.p256SubjectPublicKeyInfo(point), spki)
        XCTAssertEqual([UInt8](spki.prefix(26)), SpkiFingerprint.p256Prefix)
        XCTAssertNil(SpkiFingerprint.p256SubjectPublicKeyInfo(Data(point.prefix(64))))
        var compressed = [UInt8](point)
        compressed[0] = 0x02
        XCTAssertNil(SpkiFingerprint.p256SubjectPublicKeyInfo(Data(compressed)))
    }

    func testCheckCode_IsSixDigitsOfTheFingerprint() {
        XCTAssertEqual(SpkiFingerprint.checkCode(fingerprint), p256CheckCode)
        XCTAssertEqual(SpkiFingerprint.formatCheckCode(p256CheckCode), "218 140")
        XCTAssertEqual(SpkiFingerprint.checkCode(Data(count: 32)), "000000")
        // 0x000F4240 = 1,000,000 gives 0; 0x000F4241 gives 1, with leading zeros.
        XCTAssertEqual(SpkiFingerprint.checkCode(Data([0x00, 0x0F, 0x42, 0x41] + [UInt8](repeating: 0, count: 28))), "000001")
        XCTAssertEqual(SpkiFingerprint.checkCode(Data([1, 2, 3])), "")
        XCTAssertEqual(SpkiFingerprint.formatCheckCode("12345"), "12345")
    }

    func testMatches_ComparesWholeFingerprints() {
        let digest = fingerprint
        XCTAssertTrue(SpkiFingerprint.matches(digest, Data(digest)))
        var other = [UInt8](digest)
        other[31] ^= 1
        XCTAssertFalse(SpkiFingerprint.matches(digest, Data(other)))
        XCTAssertFalse(SpkiFingerprint.matches(Data(digest.prefix(31)), Data(digest.prefix(31))))
        XCTAssertFalse(SpkiFingerprint.matches(Data(), Data()))
    }

    func testMalformedCertificates_HaveNoFingerprint() throws {
        let good = [UInt8](try IppFixtures.certificateDER(p256File))
        func with(_ index: Int, _ value: UInt8) -> Data {
            var copy = good
            copy[index] = value
            return Data(copy)
        }
        XCTAssertNil(SpkiFingerprint.of(Data()))
        XCTAssertNil(SpkiFingerprint.of(Data([0x30])))
        XCTAssertNil(SpkiFingerprint.of(Data(good.prefix(100))))
        XCTAssertNil(SpkiFingerprint.of(Data(good.dropLast())))
        XCTAssertNil(SpkiFingerprint.of(Data(good + [0x00])))
        XCTAssertNil(SpkiFingerprint.of(with(0, 0x31)))                                // not a SEQUENCE
        XCTAssertNil(SpkiFingerprint.of(with(1, 0x80)))                                // indefinite length
        XCTAssertNil(SpkiFingerprint.of(with(1, 0x85)))                                // a length of five bytes
        XCTAssertNil(SpkiFingerprint.of(Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])))   // longer than the data
        XCTAssertNil(SpkiFingerprint.of(with(4, 0x31)))                                // tbsCertificate not a SEQUENCE
        XCTAssertNil(SpkiFingerprint.of(with(8, 0xBF)))                                // a high tag number
    }
}
