import Foundation
import Network
import Security
import XCTest
@testable import LazyPrintKit

// The Swift server end to end, the twin of the windows/LazyPrint.Core.Tests/CompanionLoopbackTests.cs
// cases about the server: CompanionServer on 127.0.0.1 (loopback only, nothing advertised) with a fixed
// identity from Tests/Fixtures/Companion, and the phone's CompanionClient pinned to that certificate's key,
// as the C# FakePhone is. The cases about the host (networks, advertising, listening only while wanted,
// Reset pairing) are in CompanionHostTests. The identity is imported to memory, so no keychain is needed:
// a runner's keychain refuses new keys (errSecMissingEntitlement).

extension CompanionFixtures {
    /// The desktop identities the loopback server serves: test fixtures only, no key ships in the app.
    static let desktopA = "tls-desktop-a.p12"
    static let desktopB = "tls-desktop-b.p12"

    /// The SHA-256 of the SubjectPublicKeyInfo of `desktopA` and `desktopB`.
    static let desktopAFingerprint = "9c42a3956a1a30612c1e2290b21c7a99ed3b2560e90c5416da675e6600bbf0e9"
    static let desktopBFingerprint = "b2b2c0802ae33febc2877d630ed144853d6da2de56cf0df765e0e21c49b54ce6"

    /// The password of the `desktopA` and `desktopB` files.
    static let loopbackPassword = "loopback-desktop"

    /// Tests/Fixtures/Companion in the repository.
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LazyPrintTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/Companion", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// The server identity of the tests: `desktopA`, and `desktopB` once renewed, so Reset pairing still
/// changes the key.
final class FixtureIdentity: CompanionIdentity {
    private var served: SecIdentity?

    func current(now: Date) throws -> SecIdentity {
        if let served { return served }
        let loaded = try FixtureIdentity.load(CompanionFixtures.desktopA)
        served = loaded
        return loaded
    }

    func renew(now: Date) throws -> SecIdentity {
        let loaded = try FixtureIdentity.load(CompanionFixtures.desktopB)
        served = loaded
        return loaded
    }

    /// A fixture identity, imported into memory only.
    static func load(_ file: String) throws -> SecIdentity {
        let data = try Data(contentsOf: CompanionFixtures.url(file))
        var options: [String: Any] = [kSecImportExportPassphrase as String: CompanionFixtures.loopbackPassword]
        #if os(macOS)
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            throw XCTSkip("Importing a test identity without a keychain needs macOS 15.")
        }
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw SelfSignedCertificateError("\(file) could not be imported (\(status)).")
        }
        return found as! SecIdentity
    }
}

/// The time the router and the server read, moved by the tests.
private final class LoopbackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A hand-written client: plain TCP, or TLS that takes any certificate.
private final class RawConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(port: Int, tls: Bool) {
        let queue: DispatchQueue = DispatchQueue(label: "CompanionLoopbackTests.raw")
        self.queue = queue
        var options: NWProtocolTLS.Options?
        if tls {
            let made: NWProtocolTLS.Options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(made.securityProtocolOptions, {
                (_: sec_protocol_metadata_t, _: sec_trust_t, complete: @escaping sec_protocol_verify_complete_t) in
                complete(true)
            }, queue)
            options = made
        }
        let parameters: NWParameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                  using: parameters)
    }

    /// Connects (and makes the TLS handshake); false when that fails within 10 s.
    func open() async -> Bool {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        let flag: Guarded<Bool> = Guarded(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: (Bool) -> Void = { (ready: Bool) in
                guard !flag.value else { return }
                flag.value = true
                continuation.resume(returning: ready)
            }
            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled, .waiting: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 10) { finish(false) }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async {
        let connection: NWConnection = self.connection
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed({ (_: NWError?) in
                continuation.resume()
            }))
        }
    }

    /// The next bytes; empty once the server closed, on an error or after `timeout`.
    func receive(timeout: TimeInterval) async -> Data {
        let connection: NWConnection = self.connection
        let queue: DispatchQueue = self.queue
        let flag: Guarded<Bool> = Guarded(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let finish: (Data) -> Void = { (data: Data) in
                guard !flag.value else { return }
                flag.value = true
                continuation.resume(returning: data)
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(Data()) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                (data: Data?, _: NWConnection.ContentContext?, _: Bool, _: NWError?) in
                finish(data ?? Data())
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

final class CompanionLoopbackTests: XCTestCase {
    private var directory: URL!
    private var clock: LoopbackClock!
    private var devices: PairedDeviceStore!
    private var inbox: CompanionInbox!
    private var server: CompanionServer?
    private let session = Guarded<PairingSession?>(nil)
    private let received = Guarded<[ReceivedPackage]>([])
    private var port = 0
    private var pin = Data()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionLoopbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // To the second, as packages write dates.
        let clock = LoopbackClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        self.clock = clock
        let serverIdentity = try FixtureIdentity().current(now: clock.now)
        pin = try XCTUnwrap(SelfSignedCertificate.der(of: serverIdentity).flatMap { SpkiFingerprint.of($0) })

        devices = PairedDeviceStore(directory: directory.appendingPathComponent("Settings", isDirectory: true))
        let data = directory.appendingPathComponent("Data", isDirectory: true)
        inbox = CompanionInbox(directory: data.appendingPathComponent("Inbox", isDirectory: true))
        let limiter = CompanionRateLimiter()
        let router = CompanionRouter(devices: devices, inbox: inbox, limiter: limiter, clock: { clock.now })
        router.desktopName = { "TEST-MAC" }
        router.approvePairing = { _ in true }
        let session = self.session
        router.currentPairing = { session.value }
        let received = self.received
        router.onPackageReceived = { package, _ in received.value.append(package) }
        var options: CompanionServerOptions = CompanionServerOptions()
        options.discardTimeout = 1
        options.bodyTimeout = 2
        let server = CompanionServer(identity: serverIdentity, router: router, limiter: limiter, options: options,
                                     clock: { clock.now })
        self.server = server
        let bound = try await server.start([NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)])
        if case .hostPort(_, let actual) = bound[0] {
            port = Int(actual.rawValue)
        }
        XCTAssertNotEqual(port, 0)
    }

    override func tearDown() async throws {
        await server?.stop()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Helpers

    /// A phone pinned to `pin` (the server's by default), paired already when it has a secret.
    private func phone(_ id: String = "phone-0001", pin: Data? = nil, secret: Data? = nil) -> CompanionClient {
        let desktop = PairedDesktop(id: "", name: "", fingerprint: SpkiFingerprint.text(pin ?? self.pin),
                                    addresses: ["127.0.0.1"], port: port, phoneId: id)
        return CompanionClient(desktop: desktop, secret: secret)
    }

    private func openPairing() throws -> PairingSession {
        let opened = try PairingSession(opened: clock.now)
        session.value = opened
        return opened
    }

    private func pair(_ client: CompanionClient, _ token: String, _ id: String = "phone-0001") async throws -> PairResponse {
        try await client.pair(token: token, phoneId: id, phoneName: "Test phone", platform: "ios", appVersion: "1.0")
    }

    /// A paired phone and its secret.
    private func pairedPhone(_ id: String = "phone-0001") async throws -> (client: CompanionClient, secret: String) {
        let opened = try openPairing()
        let client = phone(id)
        let answer = try await pair(client, opened.token, id)
        // The phone is stored at its first request with the secret.
        _ = try await client.hello()
        return (client, answer.deviceSecret)
    }

    /// The status and error code of a refusal; nil when `body` did not fail with one.
    private func refusal(_ body: () async throws -> Void) async -> (status: Int, code: String)? {
        do {
            try await body()
            return nil
        } catch CompanionClientError.refused(let status, let error) {
            return (status, error.code)
        } catch {
            return nil
        }
    }

    private func isUnauthorized(_ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            return false
        } catch CompanionClientError.unauthorized {
            return true
        } catch {
            return false
        }
    }

    /// Sends a hand-written request over TLS (any certificate) and reads the status and the whole answer.
    private func raw(_ head: String, body: Data? = nil, waitForContinue: Bool = false) async throws -> (status: Int, text: String) {
        let connection = RawConnection(port: port, tls: true)
        defer { connection.cancel() }
        guard await connection.open() else {
            XCTFail("The TLS connection did not open.")
            return (0, "")
        }
        await connection.send(Data(head.utf8))
        if let body {
            if waitForContinue {
                let interim = await connection.receive(timeout: 10)
                XCTAssertEqual(String(decoding: interim, as: UTF8.self), "HTTP/1.1 100 Continue\r\n\r\n")
            }
            await connection.send(body)
        }
        var answer = Data()
        while true {
            let chunk = await connection.receive(timeout: 10)
            if chunk.isEmpty { break }
            answer.append(chunk)
        }
        let text = String(decoding: answer, as: UTF8.self)
        let parts = text.split(separator: " ")
        return (parts.count > 1 ? Int(parts[1]) ?? 0 : 0, text)
    }

    // MARK: - Cases

    func testTheFixtureIdentitiesHaveTheirFingerprints() throws {
        let pinned = [CompanionFixtures.desktopA: CompanionFixtures.desktopAFingerprint,
                      CompanionFixtures.desktopB: CompanionFixtures.desktopBFingerprint]
        for (file, fingerprint) in pinned {
            // Loaded outside the assertion, so the XCTSkip of earlier systems skips the test.
            let identity = try FixtureIdentity.load(file)
            let der = try XCTUnwrap(SelfSignedCertificate.der(of: identity), file)
            let digest = try XCTUnwrap(SpkiFingerprint.of(der), file)
            XCTAssertEqual(SpkiFingerprint.hex(digest), fingerprint, file)
        }
        XCTAssertEqual(SpkiFingerprint.hex(pin), CompanionFixtures.desktopAFingerprint)
    }

    func testPair_ThenSend_ReceivesTheBatchOnce() async throws {
        let opened = try openPairing()
        let client = phone()
        let answer = try await pair(client, opened.token)
        XCTAssertEqual(devices.count, 0)
        XCTAssertTrue(devices.hasPending(now: clock.now))
        let hello = try await client.hello()
        XCTAssertEqual(devices.count, 1)
        let device = try XCTUnwrap(devices.devices.first)
        XCTAssertEqual(device.name, "Test phone")
        let secret = try XCTUnwrap(CompanionProtocol.decodeBase64Url(answer.deviceSecret))
        XCTAssertEqual(device.secretHash, PairedDeviceStore.hashSecret(secret))

        XCTAssertEqual(hello.desktopName, "TEST-MAC")
        let health = try await client.health()
        XCTAssertEqual(health, HealthResponse(protocolVersion: 1, paired: true))

        let first = try CompanionFixtures.package(batch: "batch-0001", index: 0, count: 2, name: "Report.pdf")
        let last = try CompanionFixtures.package(batch: "batch-0001", index: 1, count: 2, name: "Report.pdf")
        let created = try await client.send(packageId: "package-0001", data: first)
        XCTAssertEqual(created, InboxResponse(packageId: "package-0001", duplicate: false))
        let again = try await client.send(packageId: "package-0001", data: first)
        XCTAssertEqual(again, InboxResponse(packageId: "package-0001", duplicate: true))
        XCTAssertEqual(received.value.count, 1)
        let waiting = try XCTUnwrap(inbox.batches(now: clock.now).first)
        XCTAssertFalse(waiting.isWhole(now: clock.now))

        let second = try await client.send(packageId: "package-0002", data: last)
        XCTAssertEqual(second, InboxResponse(packageId: "package-0002", duplicate: false))
        XCTAssertEqual(received.value.count, 2)
        let batches = inbox.batches(now: clock.now)
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].isWhole(now: clock.now))
        XCTAssertEqual(batches[0].from, "Aytu's iPhone")
        let folder = directory.appendingPathComponent("Data/Inbox/batch-0001", isDirectory: true)
        let files = inbox.take(batch: "batch-0001", now: clock.now)
        XCTAssertEqual(files.map(\.path), [folder.appendingPathComponent("Report.pdf").path,
                                           folder.appendingPathComponent("Report (2).pdf").path])
        XCTAssertEqual(try Data(contentsOf: files[1]), CompanionFixtures.pdf)
        XCTAssertTrue(inbox.batches(now: clock.now).isEmpty)
    }

    func testWrongFingerprint_IsRefusedBeforeAnythingIsSent() async throws {
        let opened = try openPairing()
        var other = pin
        other[other.startIndex] ^= 0xFF
        do {
            _ = try await pair(phone(pin: other), opened.token)
            XCTFail("A desktop with another key was paired.")
        } catch CompanionClientError.wrongCertificate {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(devices.count, 0)
        XCTAssertEqual(opened.state(at: clock.now), .open)
        // The right pin still pairs with the same code.
        let right = phone()
        _ = try await pair(right, opened.token)
        _ = try await right.hello()
        XCTAssertEqual(devices.count, 1)
    }

    func testAnApprovedPhoneThatNeverComesBack_IsNotStored() async throws {
        let opened = try openPairing()
        let client = phone()
        _ = try await pair(client, opened.token)
        XCTAssertEqual(devices.count, 0)
        clock.advance(PairedDeviceStore.pendingLifetime)
        XCTAssertFalse(devices.hasPending(now: clock.now))
        let late = await isUnauthorized { _ = try await client.hello() }
        XCTAssertTrue(late)
        XCTAssertEqual(devices.count, 0)
        XCTAssertTrue(PairedDeviceStore(directory: directory.appendingPathComponent("Settings", isDirectory: true)).devices.isEmpty)
    }

    func testExpiredAndReusedTokens_AreRefused() async throws {
        let opened = try openPairing()
        let first = phone("phone-0001")
        _ = try await pair(first, opened.token, "phone-0001")
        _ = try await first.hello()
        let second = phone("phone-0002")
        let reused = await refusal { _ = try await self.pair(second, opened.token, "phone-0002") }
        XCTAssertEqual(reused?.status, 403)
        XCTAssertEqual(reused?.code, CompanionErrorCode.tokenUsed)

        let fresh = try openPairing()
        clock.advance(PairingSession.lifetime)
        let expired = await refusal { _ = try await self.pair(second, fresh.token, "phone-0002") }
        XCTAssertEqual(expired?.code, CompanionErrorCode.tokenExpired)
        let wrong = await refusal { _ = try await self.pair(second, CompanionVectors.tokenText, "phone-0002") }
        XCTAssertEqual(wrong?.status, 403)
        XCTAssertEqual(devices.count, 1)
    }

    func testRemovedPhone_Gets401AndOthersKeepWorking() async throws {
        let kept = try await pairedPhone("phone-0001").client
        let removed = try await pairedPhone("phone-0002").client
        _ = try await removed.hello()
        devices.remove("phone-0002")
        inbox.removeDevice("phone-0002")
        let hello = await isUnauthorized { _ = try await removed.hello() }
        XCTAssertTrue(hello)
        let package = try CompanionFixtures.package()
        let upload = await isUnauthorized { _ = try await removed.send(packageId: "package-0001", data: package) }
        XCTAssertTrue(upload)
        XCTAssertTrue(received.value.isEmpty)
        _ = try await kept.hello()
        // The phone forgetting the desktop works the same way.
        try await kept.unpair()
        XCTAssertEqual(devices.count, 0)
    }

    func testMaliciousPackages_AreRefusedAndNotKept() async throws {
        let client = try await pairedPhone().client
        var damaged = try CompanionFixtures.package()
        damaged[0] ^= 0xFF
        var notAPdf = try CompanionFixtures.package()
        notAPdf[try PrintPackage.read(notAPdf).dataOffset] ^= 0xFF
        let traversal = CompanionFixtures.raw(
            #"{"name":"../../evil.pdf","contentType":"application/pdf","batch":"batch-0001","index":0,"count":1,"from":"x"}"#)
        let uploads: [(String, Data)] = [("package-0001", traversal), ("package-0002", damaged), ("package-0003", notAPdf),
                                         ("package-0004", Data("PK not really".utf8))]
        for (id, bytes) in uploads {
            do {
                _ = try await client.send(packageId: id, data: bytes)
                XCTFail("\(id) was received.")
            } catch CompanionClientError.invalidPackage(let error) {
                XCTAssertEqual(error.code, CompanionErrorCode.invalidPackage)
            } catch {
                XCTFail("\(id): \(error)")
            }
        }
        XCTAssertTrue(received.value.isEmpty)
        XCTAssertTrue(inbox.batches(now: clock.now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Data/evil.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("evil.pdf").path))
    }

    func testOversizeAndChunkedUploads_AreRefusedWithoutTheirBody() async throws {
        let secret = try await pairedPhone().secret
        let auth = "Authorization: Bearer \(secret)\r\n\(CompanionProtocol.deviceIdHeader): phone-0001\r\n"
        let tooLarge = CompanionProtocol.maxUploadBytes + 1
        var (status, text) = try await raw(
            "PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(tooLarge)\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertEqual(status, 413)
        XCTAssertFalse(text.contains("100 Continue"))
        XCTAssertTrue(text.contains("\"tooLarge\""))
        (status, _) = try await raw("PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(tooLarge)\r\n\r\n")
        XCTAssertEqual(status, 413)
        (status, _) = try await raw("PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n\(auth)Transfer-Encoding: chunked\r\n\r\n")
        XCTAssertEqual(status, 501)
        (status, _) = try await raw("GET /v1/health HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n")
        XCTAssertEqual(status, 400)
        // An upload that asks to wait gets "100 Continue", then its answer.
        let package = try CompanionFixtures.package()
        (status, text) = try await raw(
            "PUT /v1/inbox/package-0009 HTTP/1.1\r\nHost: x\r\n\(auth)Content-Length: \(package.count)\r\nExpect: 100-continue\r\n\r\n",
            body: package, waitForContinue: true)
        XCTAssertEqual(status, 201, text)
        XCTAssertEqual(received.value.count, 1)
    }

    func testRefusedRequest_WithABodyThatTrickles_IsClosedAfterTheDiscardTimeout() async throws {
        _ = try await pairedPhone()
        session.value = nil
        let started: Date = Date()
        let (status, _) = try await raw("POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 8192\r\n\r\n", body: Data(count: 1))
        XCTAssertEqual(status, 403)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testPairBody_ThatTricklesPastTheBodyTimeout_IsCutOff() async throws {
        _ = try openPairing()
        let connection: RawConnection = RawConnection(port: port, tls: true)
        defer { connection.cancel() }
        let opened = await connection.open()
        XCTAssertTrue(opened)
        await connection.send(Data("POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 200\r\n\r\n{".utf8))
        let started: Date = Date()
        // Each byte comes inside the idle timeout, but the body as a whole does not.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            await connection.send(Data(" ".utf8))
        }
        let answer = await connection.receive(timeout: 10)
        XCTAssertTrue(answer.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    // Only the refusal: a Mac has no 127.0.0.2 to come from, so the C# test also shows another address getting in.
    func testOneAddress_LeavesRoomForTheOthers() async throws {
        _ = try openPairing()
        // TLS, as a plain connection is also ready when the server then drops it.
        let held: [RawConnection] = (0..<CompanionServerOptions().maxConnectionsPerPeer).map { _ in RawConnection(port: port, tls: true) }
        defer { held.forEach { $0.cancel() } }
        for connection in held {
            let opened = await connection.open()
            XCTAssertTrue(opened)
        }
        let refused = RawConnection(port: port, tls: false)
        defer { refused.cancel() }
        _ = await refused.open()
        let started: Date = Date()
        let answer = await refused.receive(timeout: 8)
        XCTAssertTrue(answer.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testPlainHttp_GetsNoAnswer() async throws {
        _ = try openPairing()
        let connection = RawConnection(port: port, tls: false)
        defer { connection.cancel() }
        let opened = await connection.open()
        XCTAssertTrue(opened)
        await connection.send(Data("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let answer = await connection.receive(timeout: 15)
        XCTAssertFalse(String(decoding: answer, as: UTF8.self).hasPrefix("HTTP/"))
    }

    func testRepeatedWrongSecrets_AreCutOff() async throws {
        let good = try await pairedPhone().client
        let bad = phone(secret: CompanionVectors.secret)
        for _ in 0..<CompanionRateLimiter.maxFailures {
            let refused = await isUnauthorized { _ = try await bad.hello() }
            XCTAssertTrue(refused)
        }
        // Blocked: the connection is closed before TLS, even with the right secret.
        do {
            _ = try await good.hello()
            XCTFail("A blocked address was answered.")
        } catch CompanionClientError.unreachable {
        } catch {
            XCTFail("\(error)")
        }
        clock.advance(CompanionRateLimiter.window)
        _ = try await good.hello()
    }
}
