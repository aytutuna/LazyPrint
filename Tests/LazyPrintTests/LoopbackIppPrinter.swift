import Foundation
import Network
import Security
import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/LoopbackIppPrinter.cs: the same printer for the same cases. It listens on
// 127.0.0.1 only, plain HTTP and TLS on one port. Network.framework cannot take both from one listener, so the
// port is a relay that tells TLS from plain by the first byte (as the C# printer does) and hands the connection to
// a plain listener or to a TLS one; the TLS one serves the identity in Tests/Fixtures/Ipp (tls-printer-a.p12, a test
// key only). It records what it gets and answers from a script, else like a printer that is idle and takes
// everything. Every connection answers one request and closes.

/// One request as the printer received it. The body is de-chunked, but `headers` show whether it was.
struct LoopbackRequest {
    let method: String
    let path: String
    /// Header names in lowercase.
    let headers: [String: String]
    let body: Data
    let tls: Bool

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The IPP message the body starts with.
    func ipp() throws -> IppMessage {
        try IppMessage.decode(body).message
    }

    /// What follows the IPP message: the document of a Print-Job.
    func document() throws -> Data {
        let offset = try IppMessage.decode(body).documentOffset
        return Data(body[(body.startIndex + offset)...])
    }
}

/// What the printer answers: an HTTP status and body, after an optional wait.
struct LoopbackAnswer {
    var status: Int
    var body: Data
    var delay: TimeInterval = 0
    var retryAfter: String?

    /// An IPP response with the usual operation attributes, then `groups`.
    static func ipp(_ status: IppStatus, _ groups: IppGroup...) -> LoopbackAnswer {
        ipp(code: status.rawValue, groups)
    }

    static func ipp(code: UInt16, _ groups: [IppGroup]) -> LoopbackAnswer {
        let operation = IppGroup(tag: IppTag.operationAttributes, attributes: [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .language("en")),
        ])
        let message = IppMessage(version: .v20, code: code, requestId: 1, groups: [operation] + groups)
        return LoopbackAnswer(status: 200, body: message.encoded())
    }

    static func http(_ status: Int, retryAfter: String? = nil) -> LoopbackAnswer {
        LoopbackAnswer(status: status, body: Data(), retryAfter: retryAfter)
    }

    /// A job group with the attributes a printer reports for a job.
    static func job(_ id: Int, _ state: Int, _ reasons: String...) -> IppGroup {
        IppGroup(tag: IppTag.jobAttributes, attributes: [
            IppAttribute("job-id", .integer(Int32(id))),
            IppAttribute("job-state", .enumValue(Int32(state))),
            IppAttribute(name: "job-state-reasons", values: (reasons.isEmpty ? ["none"] : reasons).map { IppValue.keyword($0) }),
        ])
    }

    /// A job group as a Get-Jobs response lists a job.
    static func queuedJob(_ id: Int, _ state: Int, name: String, user: String, impressions: Int = 0) -> IppGroup {
        IppGroup(tag: IppTag.jobAttributes, attributes: [
            IppAttribute("job-id", .integer(Int32(id))),
            IppAttribute("job-name", .name(name)),
            IppAttribute("job-originating-user-name", .name(user)),
            IppAttribute("job-state", .enumValue(Int32(state))),
            IppAttribute("job-impressions-completed", .integer(Int32(impressions))),
        ])
    }

    /// A printer group with its printer-state-reasons.
    static func printerState(_ reasons: String...) -> IppGroup {
        IppGroup(tag: IppTag.printerAttributes, attributes: [
            IppAttribute(name: "printer-state-reasons", values: (reasons.isEmpty ? ["none"] : reasons).map { IppValue.keyword($0) }),
        ])
    }

    func after(_ seconds: TimeInterval) -> LoopbackAnswer {
        var copy = self
        copy.delay = seconds
        return copy
    }
}

enum LoopbackError: Error {
    case stopped
    case identity(String)
}

enum LoopbackIdentity {
    static let password = "LazyScan-test"

    /// The test identity, imported into memory only. On macOS that needs macOS 15, and earlier systems skip.
    static func load() throws -> SecIdentity {
        let data = try Data(contentsOf: IppFixtures.url("tls-printer-a.p12"))
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
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
            throw LoopbackError.identity("tls-printer-a.p12 could not be imported (\(status)).")
        }
        return found as! SecIdentity
    }

    /// The SPKI fingerprint of an identity's certificate.
    static func fingerprint(_ identity: SecIdentity) throws -> String {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let found = certificate,
              let print = IppCertificates.fingerprint(certificateDER: SecCertificateCopyData(found) as Data) else {
            throw LoopbackError.identity("The identity has no usable certificate.")
        }
        return print
    }
}

private final class LoopbackOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done {
            return false
        }
        done = true
        return true
    }
}

final class LoopbackIppPrinter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LoopbackIppPrinter")
    private let lock = NSLock()
    private let fixture: Data
    private let identity: SecIdentity?
    private let upgradeRequired: Bool
    private var listeners: [NWListener] = []
    private var connections: [NWConnection] = []
    private var queued: [LoopbackAnswer] = []
    private var log: [LoopbackRequest] = []
    private var plainPort: UInt16?
    private var tlsPort: UInt16?
    private var frontPort: UInt16 = 0
    private var plain = 0
    private var secure = 0

    /// `fixture` is the Get-Printer-Attributes response this printer answers with (Tests/Fixtures/Ipp/printers).
    /// With an `identity` it serves TLS, without one a TLS hello is closed on; `upgradeRequired` answers every
    /// plain request HTTP 426 (upgrade required), as a printer that wants ipps does.
    init(fixture: String = "hp-laserjet", identity: SecIdentity? = nil, upgradeRequired: Bool = false) throws {
        self.fixture = try IppFixtures.printer(fixture)
        self.identity = identity
        self.upgradeRequired = upgradeRequired
    }

    /// Starts listening; returns once the port is known.
    func start() async throws {
        let plainListener = try await listen(identity: nil) { [weak self] connection in
            self?.serve(connection, tls: false)
        }
        lock.lock()
        plainPort = plainListener.port?.rawValue
        lock.unlock()
        if let identity {
            let tlsListener = try await listen(identity: identity) { [weak self] connection in
                self?.serve(connection, tls: true)
            }
            lock.lock()
            tlsPort = tlsListener.port?.rawValue
            lock.unlock()
        }
        let front = try await listen(identity: nil) { [weak self] connection in
            self?.accept(connection)
        }
        lock.lock()
        frontPort = front.port?.rawValue ?? 0
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let open = connections
        let all = listeners
        connections = []
        listeners = []
        lock.unlock()
        for listener in all {
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        for connection in open {
            connection.cancel()
        }
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return frontPort
    }

    var plainConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return plain
    }

    var tlsConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return secure
    }

    /// The requests received, whatever they were answered with.
    var requests: [LoopbackRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func address(secure: Bool = false) throws -> PrinterAddress {
        try PrinterAddress.parse("\(secure ? "ipps" : "ipp")://127.0.0.1:\(port)")
    }

    /// Answers the next requests with these, in order, before falling back to the printer's own answers.
    func script(_ answers: LoopbackAnswer...) {
        scriptEach(answers)
    }

    func scriptEach(_ answers: [LoopbackAnswer]) {
        lock.lock()
        queued.append(contentsOf: answers)
        lock.unlock()
    }

    // MARK: - Listening

    private func listen(identity: SecIdentity?, handler: @escaping (NWConnection) -> Void) async throws -> NWListener {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            guard let local = sec_identity_create(identity) else {
                throw LoopbackError.identity("The test identity cannot be used for TLS.")
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            // Every connection makes a full handshake, so every one is checked by the client.
            sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
            sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }
        // The loopback interface only: nothing on the network can reach it.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port.any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = handler
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = LoopbackOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume() }
                case .failed(let error):
                    if once.first() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.first() { continuation.resume(throwing: LoopbackError.stopped) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.lock()
        listeners.append(listener)
        lock.unlock()
        return listener
    }

    private func track(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    // MARK: - The relay

    /// The first byte of a connection tells TLS (0x16, a hello) from plain HTTP.
    private func accept(_ client: NWConnection) {
        track(client)
        client.start(queue: queue)
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                client.cancel()
                return
            }
            let tls = data[data.startIndex] == 0x16
            self.lock.lock()
            if tls {
                self.secure += 1
            } else {
                self.plain += 1
            }
            let backend = tls ? self.tlsPort : self.plainPort
            self.lock.unlock()
            guard let number = backend, let target = NWEndpoint.Port(rawValue: number) else {
                client.cancel()
                return
            }
            let server = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: target, using: .tcp)
            self.track(server)
            server.start(queue: self.queue)
            server.send(content: data, completion: .contentProcessed { _ in
                self.pump(from: client, to: server)
                self.pump(from: server, to: client)
            })
        }
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            let finished = isComplete || error != nil
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { _ in
                    if finished {
                        sink.cancel()
                        source.cancel()
                    } else {
                        self?.pump(from: source, to: sink)
                    }
                })
            } else if finished {
                sink.cancel()
                source.cancel()
            } else {
                self?.pump(from: source, to: sink)
            }
        }
    }

    // MARK: - Serving

    private func serve(_ connection: NWConnection, tls: Bool) {
        track(connection)
        connection.start(queue: queue)
        receive(connection, tls: tls, buffer: [])
    }

    private func receive(_ connection: NWConnection, tls: Bool, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var collected = buffer
            if let data {
                collected.append(contentsOf: data)
            }
            if let request = LoopbackIppPrinter.parse(collected, tls: tls) {
                self.answer(request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, tls: tls, buffer: collected)
        }
    }

    private func answer(_ request: LoopbackRequest, on connection: NWConnection) {
        lock.lock()
        log.append(request)
        var scripted: LoopbackAnswer?
        if !(upgradeRequired && !request.tls) && !queued.isEmpty {
            scripted = queued.removeFirst()
        }
        lock.unlock()
        let reply = scripted ?? ownAnswer(request)
        let send = {
            var head = "HTTP/1.1 \(reply.status) Status\r\nContent-Type: application/ipp\r\n"
            head += "Content-Length: \(reply.body.count)\r\nConnection: close\r\n"
            if let after = reply.retryAfter {
                head += "Retry-After: \(after)\r\n"
            }
            head += "\r\n"
            var payload = Data(head.utf8)
            payload.append(reply.body)
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        if reply.delay > 0 {
            queue.asyncAfter(deadline: .now() + reply.delay, execute: send)
        } else {
            send()
        }
    }

    private func ownAnswer(_ request: LoopbackRequest) -> LoopbackAnswer {
        if upgradeRequired && !request.tls {
            return LoopbackAnswer.http(426)
        }
        guard let message = try? request.ipp() else {
            return LoopbackAnswer.http(400)
        }
        switch IppOperation(rawValue: message.code) {
        case .getPrinterAttributes?:
            return LoopbackAnswer(status: 200, body: fixture)
        case .printJob?:
            return LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 3))
        case .getJobAttributes?:
            return LoopbackAnswer.ipp(.successfulOk, LoopbackAnswer.job(42, 9, "job-completed-successfully"))
        default:
            return LoopbackAnswer.ipp(.successfulOk)
        }
    }

    // MARK: - Parsing

    /// A request once its head and all of its body (the whole of a chunked one) have arrived; nil before.
    private static func parse(_ bytes: [UInt8], tls: Bool) -> LoopbackRequest? {
        guard let end = find(bytes, [13, 10, 13, 10], from: 0) else { return nil }
        let head = String(decoding: bytes[0..<end], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].components(separatedBy: " ")
        guard start.count >= 2 else { return nil }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = end + 4
        var body = [UInt8]()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var position = bodyStart
            while true {
                guard let lineEnd = find(bytes, [13, 10], from: position) else { return nil }
                let sizeText = String(decoding: bytes[position..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let size = Int(sizeText, radix: 16) ?? 0
                position = lineEnd + 2
                if size == 0 {
                    guard bytes.count >= position + 2 else { return nil }
                    break
                }
                guard bytes.count >= position + size + 2 else { return nil }
                body.append(contentsOf: bytes[position..<position + size])
                position += size + 2
            }
        } else {
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard bytes.count >= bodyStart + length else { return nil }
            body = Array(bytes[bodyStart..<bodyStart + length])
        }
        return LoopbackRequest(method: start[0], path: start[1], headers: headers, body: Data(body), tls: tls)
    }

    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0] && Array(bytes[index..<index + pattern.count]) == pattern {
                return index
            }
            index += 1
        }
        return nil
    }
}
