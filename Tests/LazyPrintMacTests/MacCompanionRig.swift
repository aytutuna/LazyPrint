#if os(macOS)
import Foundation
import Network
import Security
import XCTest
@testable import LazyPrintKit
@testable import LazyPrintMac

// What the phone link tests of the Mac share: an identity from a fixture instead of the keychain, networks that are
// given, and options with folders of their own.

/// Tests/Fixtures/Companion in the repository.
func companionFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LazyPrintMacTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/Companion", isDirectory: true)
        .appendingPathComponent(name)
}

/// The server identity of the tests: a fixture imported into memory only, so no key lands in the keychain.
final class FixtureIdentity: CompanionIdentity {
    func current(now: Date) throws -> SecIdentity {
        try load("tls-desktop-a.p12")
    }

    func renew(now: Date) throws -> SecIdentity {
        try load("tls-desktop-b.p12")
    }

    private func load(_ file: String) throws -> SecIdentity {
        let data = try Data(contentsOf: companionFixture(file))
        var options: [String: Any] = [kSecImportExportPassphrase as String: "loopback-desktop"]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw XCTSkip("Importing a test identity without a keychain needs macOS 15.")
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw SelfSignedCertificateError("\(file) could not be imported (\(status)).")
        }
        return found as! SecIdentity
    }
}

/// The networks the test says the Mac is on.
final class GivenNetworks: CompanionNetworkSource, @unchecked Sendable {
    var onChange: (() -> Void)?
    private let given: [CompanionNetwork]

    init(_ networks: [CompanionNetwork] = []) {
        given = networks
    }

    func networks() -> [CompanionNetwork] {
        given
    }

    /// A private network whose only address is the loopback one, so the server can listen on it anywhere.
    static func loopback() -> CompanionNetwork {
        let subnet = LocalSubnet(address: .ipv4(.loopback), prefixLength: 8)
        return CompanionNetwork(id: "{loopback}", name: "Test network", category: .privateNetwork,
                                interfaces: [CompanionNetworkInterface(index: 1, adapterId: "adapter-1", addresses: [subnet])])
    }
}

extension CompanionServiceOptions {
    /// Options with the settings and the inbox in `folder`.
    static func test(in folder: URL, networks: [CompanionNetwork] = [], name: String = "Test Mac") throws -> CompanionServiceOptions {
        let settings = folder.appendingPathComponent("settings", isDirectory: true)
        let data = folder.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return CompanionServiceOptions(settingsDirectory: settings, dataDirectory: data, identity: FixtureIdentity(),
                                       networks: GivenNetworks(networks), desktopName: name)
    }
}

extension XCTestCase {
    /// A folder that is removed when the test ends.
    func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-mac-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
#endif
