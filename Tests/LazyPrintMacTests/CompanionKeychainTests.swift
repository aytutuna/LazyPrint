#if os(macOS)
import Foundation
import Security
import XCTest
@testable import LazyPrintKit
@testable import LazyPrintMac

// The certificate and the sync keys in the login keychain. Every item has a label, tag or account of the test's own, so the
// key of the app on the same Mac is never touched, and all of them are deleted again.

final class CompanionKeychainTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func makeStore() -> CompanionCertificateStore {
        let name = "Lazy Print test " + UUID().uuidString
        let tag = Data(("test." + name).utf8)
        addTeardownBlock {
            var found: CFTypeRef?
            SecItemCopyMatching([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                                 kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &found)
            for key in found as? [[String: Any]] ?? [] {
                guard let hash = key[kSecAttrApplicationLabel as String] as? Data else { continue }
                SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrPublicKeyHash as String: hash] as CFDictionary)
            }
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        }
        return CompanionCertificateStore(hostName: "Test-Mac", label: name, keyTag: tag)
    }

    private func pin(_ identity: SecIdentity) throws -> Data {
        let der = try XCTUnwrap(SelfSignedCertificate.der(of: identity))
        return try XCTUnwrap(SpkiFingerprint.of(der))
    }

    func test_theIdentity_isMadeOnceAndThenKept() throws {
        let store = makeStore()
        let now = Date()

        let first = try store.current(now: now)
        let second = try store.current(now: now.addingTimeInterval(day))

        XCTAssertEqual(SelfSignedCertificate.der(of: first), SelfSignedCertificate.der(of: second))
    }

    func test_aCertificateNearItsEnd_isRenewedWithTheSameKey() throws {
        let store = makeStore()
        let now = Date()
        let first = try store.current(now: now)
        // The certificate is valid for 825 days and renewed 60 days before its end.
        let later = now.addingTimeInterval(800 * day)

        let renewed = try store.current(now: later)

        XCTAssertNotEqual(SelfSignedCertificate.der(of: first), SelfSignedCertificate.der(of: renewed))
        XCTAssertEqual(try pin(first), try pin(renewed))
    }

    func test_renew_makesANewKey() throws {
        let store = makeStore()
        let now = Date()
        let first = try store.current(now: now)

        let renewed = try store.renew(now: now)

        XCTAssertNotEqual(try pin(first), try pin(renewed))
        XCTAssertEqual(try pin(try store.current(now: now)), try pin(renewed))
    }

    func test_aSyncKey_isSavedLoadedAndDeleted() throws {
        let keys = MacCompanionSyncKeys()
        let phone = "test-" + UUID().uuidString
        addTeardownBlock { try? keys.delete(for: phone) }
        XCTAssertNil(try keys.load(for: phone))

        try keys.save(Data(repeating: 7, count: 32), for: phone)
        XCTAssertEqual(try keys.load(for: phone), Data(repeating: 7, count: 32))

        try keys.save(Data(repeating: 9, count: 32), for: phone)
        XCTAssertEqual(try keys.load(for: phone), Data(repeating: 9, count: 32))

        try keys.delete(for: phone)
        XCTAssertNil(try keys.load(for: phone))
    }
}
#endif
