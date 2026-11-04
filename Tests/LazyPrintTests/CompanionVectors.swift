import Foundation

// Values both suites use for the phone link, as in windows/LazyPrint.Core.Tests/CompanionVectors.cs: the P-256
// certificate of Tests/Fixtures/Ipp and the secret and token made of the bytes 0, 1, 2, ...
enum CompanionVectors {
    static let certificateFile = "certificate-p256.pem"
    static let fingerprintHex = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4"
    static let fingerprintText = "gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ"
    static let checkCode = "218140"

    static var certificate: Data { (try? IppFixtures.certificateDER(certificateFile)) ?? Data() }
    static var fingerprint: Data { hexData(fingerprintHex) }

    /// The bytes 0, 1, 2, ... as a device secret, its SHA-256 and its text.
    static var secret: Data { Data((0..<32).map { UInt8($0) }) }
    static let secretHash = "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
    static let secretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    /// The bytes 0...15 as a pairing token, and its text.
    static var token: Data { Data((0..<16).map { UInt8($0) }) }
    static let tokenText = "AAECAwQFBgcICQoLDA0ODw"

    static func hexData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}
