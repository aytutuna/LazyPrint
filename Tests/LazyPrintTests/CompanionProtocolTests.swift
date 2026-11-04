import XCTest
import Foundation
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/CompanionProtocolTests.cs (same JSON, byte for byte).

final class CompanionProtocolTests: XCTestCase {
    private let desktopId = "0123456789abcdef0123456789abcdef"

    private func utf8(_ text: String) -> Data { Data(text.utf8) }

    func testBase64Url_EncodesAndDecodes() {
        let cases = [("", ""), ("f", "Zg"), ("fo", "Zm8"), ("foo", "Zm9v"), ("foob", "Zm9vYg"), ("fooba", "Zm9vYmE"),
                     ("foobar", "Zm9vYmFy")]
        for (plain, encoded) in cases {
            XCTAssertEqual(CompanionProtocol.encodeBase64Url(Data(plain.utf8)), encoded)
            XCTAssertEqual(CompanionProtocol.decodeBase64Url(encoded), Data(plain.utf8))
        }
    }

    func testBase64Url_UsesTheUrlAlphabet() {
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(Data([0xFB, 0xFF, 0xBF])), "-_-_")
        XCTAssertEqual(CompanionProtocol.decodeBase64Url("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(CompanionVectors.secret), CompanionVectors.secretText)
        XCTAssertEqual(CompanionProtocol.encodeBase64Url(CompanionVectors.token), CompanionVectors.tokenText)
    }

    func testBase64Url_RefusesAnythingElse() {
        for text in ["Zg==", "Zh", "Z", "Zm9v+", "Zm9v/A", "Zm 9v", nil] as [String?] {
            XCTAssertNil(CompanionProtocol.decodeBase64Url(text), text ?? "nil")
        }
    }

    func testIsValidId_AllowsSafeNamesOnly() {
        let cases: [(String?, Bool)] = [("abcdefgh", true), ("ABC-def_123", true), ("abcdefg", false), ("abc/defgh", false),
                                        ("abc defgh", false), ("abcdéfgh", false), ("..\\..\\abc", false), (nil, false)]
        for (id, valid) in cases {
            XCTAssertEqual(CompanionProtocol.isValidId(id), valid, id ?? "nil")
        }
    }

    func testIsValidId_AllowsUpTo64Characters() {
        XCTAssertTrue(CompanionProtocol.isValidId(String(repeating: "a", count: 64)))
        XCTAssertFalse(CompanionProtocol.isValidId(String(repeating: "a", count: 65)))
    }

    func testConstants_AreTheProtocols() {
        XCTAssertEqual(CompanionProtocol.version, 1)
        XCTAssertEqual(CompanionProtocol.serviceType, "_lazyprint._tcp")
        XCTAssertEqual(CompanionProtocol.defaultPort, 52732)
        XCTAssertEqual(CompanionProtocol.maxUploadBytes, 536_936_460)
        XCTAssertEqual(CompanionProtocol.packageContentType, "application/vnd.lazyprint.package")
    }

    func testMessages_HaveTheirExactJson() {
        XCTAssertEqual(CompanionError(code: "unauthorized", message: "x \"y\"").toJSON(), #"{"error":"unauthorized","message":"x \"y\""}"#)
        XCTAssertEqual(
            PairRequest(token: CompanionVectors.tokenText, phoneId: "phone-0001", phoneName: "Aytu's iPhone", platform: "ios",
                        appVersion: "1.0").toJSON(),
            #"{"token":"AAECAwQFBgcICQoLDA0ODw","phoneId":"phone-0001","phoneName":"Aytu's iPhone","platform":"ios","appVersion":"1.0"}"#)
        XCTAssertEqual(
            PairResponse(desktopId: desktopId, desktopName: "AYTU-PC", deviceSecret: CompanionVectors.secretText, protocolVersion: 1).toJSON(),
            #"{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","deviceSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#)
        XCTAssertEqual(
            PairResponse(desktopId: desktopId, desktopName: "AYTU-PC", deviceSecret: CompanionVectors.secretText, protocolVersion: 1,
                         syncKey: CompanionVectors.secretText).toJSON(),
            #"{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","deviceSecret":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","syncKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#)
        XCTAssertEqual(HealthResponse(protocolVersion: 1, paired: false).toJSON(),
                       #"{"service":"lazyprint","protocolVersion":1,"paired":false}"#)
        XCTAssertEqual(
            HelloResponse(desktopId: desktopId, desktopName: "AYTU-PC", protocolVersion: 1, maxUploadBytes: 536_936_460).toJSON(),
            #"{"protocolVersion":1,"desktopId":"0123456789abcdef0123456789abcdef","desktopName":"AYTU-PC","maxUploadBytes":536936460}"#)
        XCTAssertEqual(InboxResponse(packageId: "package-0001", duplicate: true).toJSON(),
                       #"{"packageId":"package-0001","duplicate":true}"#)
    }

    func testMessages_RoundTrip() {
        let error = CompanionError(code: "busy", message: "Wait.")
        XCTAssertEqual(CompanionError.fromJSON(utf8(error.toJSON())), error)
        let pair = PairRequest(token: CompanionVectors.tokenText, phoneId: "phone-0001", phoneName: "naïve 日本 \u{1}", platform: "ios",
                               appVersion: "1.0")
        XCTAssertEqual(PairRequest.fromJSON(utf8(pair.toJSON())), pair)
        let response = PairResponse(desktopId: desktopId, desktopName: "AYTU-PC", deviceSecret: CompanionVectors.secretText, protocolVersion: 1)
        XCTAssertEqual(PairResponse.fromJSON(utf8(response.toJSON())), response)
        var withKey = response
        withKey.syncKey = CompanionVectors.secretText
        XCTAssertEqual(PairResponse.fromJSON(utf8(withKey.toJSON())), withKey)
        let health = HealthResponse(protocolVersion: 1, paired: true)
        XCTAssertEqual(HealthResponse.fromJSON(utf8(health.toJSON())), health)
        let hello = HelloResponse(desktopId: desktopId, desktopName: "AYTU-PC", protocolVersion: 1,
                                  maxUploadBytes: CompanionProtocol.maxUploadBytes)
        XCTAssertEqual(HelloResponse.fromJSON(utf8(hello.toJSON())), hello)
        let inbox = InboxResponse(packageId: "package-0001", duplicate: false)
        XCTAssertEqual(InboxResponse.fromJSON(utf8(inbox.toJSON())), inbox)
    }

    func testMessages_AreReadLeniently() {
        // Wrong types and unknown keys: only those fields fall back.
        XCTAssertEqual(PairRequest.fromJSON(utf8(#"{"token":5,"phoneId":"phone-0001","phoneName":null,"extra":[1]}"#)),
                       PairRequest(token: "", phoneId: "phone-0001", phoneName: "", platform: "", appVersion: ""))
        XCTAssertEqual(HelloResponse.fromJSON(utf8(#"{"protocolVersion":1,"desktopId":"d","desktopName":5,"maxUploadBytes":-5}"#)),
                       HelloResponse(desktopId: "d", desktopName: "", protocolVersion: 1, maxUploadBytes: -5))
        XCTAssertEqual(InboxResponse.fromJSON(utf8("{}")), InboxResponse(packageId: "", duplicate: false))
        // A desktop from before the sync folder sends no key.
        let old = PairResponse.fromJSON(utf8(#"{"protocolVersion":1,"desktopId":"d","desktopName":"PC","deviceSecret":"s"}"#))
        XCTAssertEqual(old, PairResponse(desktopId: "d", desktopName: "PC", deviceSecret: "s", protocolVersion: 1))
        XCTAssertNil(old?.syncKey)
        XCTAssertNil(PairResponse.fromJSON(utf8(#"{"deviceSecret":"s","syncKey":5}"#))?.syncKey)
        // Not an object at all.
        XCTAssertNil(PairRequest.fromJSON(utf8("[]")))
        XCTAssertNil(PairRequest.fromJSON(utf8("null")))
        XCTAssertNil(PairRequest.fromJSON(utf8("not json")))
        XCTAssertNil(PairRequest.fromJSON(Data()))
        // An error needs its code; a health answer must be Lazy Print's.
        XCTAssertNil(CompanionError.fromJSON(utf8(#"{"message":"x"}"#)))
        XCTAssertNil(HealthResponse.fromJSON(utf8(#"{"service":"other","protocolVersion":1}"#)))
        XCTAssertNil(HealthResponse.fromJSON(utf8(#"{"service":"lazyscan","protocolVersion":1}"#)))
        XCTAssertEqual(HealthResponse.fromJSON(utf8(#"{"service":"lazyprint"}"#)), HealthResponse(protocolVersion: 0, paired: false))
    }
}
