#if os(iOS)
import LazyPrintKit
import Foundation

/// The computer `-pairedComputer` pairs the app with, for the UI tests: "Office PC", which answers from inside the app (a
/// `URLProtocol` on the phone link's session, so no network is used) with what a paired computer says to health, hello,
/// a file sent and being forgotten.
enum IOSDemoComputer {
    static let id = "demo-computer-0001"
    static let name = "Office PC"

    static func desktop() -> PairedDesktop {
        PairedDesktop(id: id, name: name, fingerprint: CompanionProtocol.encodeBase64Url(Data(repeating: 0x2A, count: 32)),
                      addresses: ["127.0.0.1"], port: CompanionProtocol.defaultPort, phoneId: PairedDesktop.makePhoneId())
    }
}

/// Secrets in memory, for the demo computer: nothing of it reaches the Keychain.
final class IOSDemoSecrets: CompanionSecretStore, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var secrets: [String: Data] = [:]

    func save(_ secret: Data, for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = secret
        lock.unlock()
    }

    func load(for desktopId: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[desktopId]
    }

    func delete(for desktopId: String) throws {
        lock.lock()
        secrets[desktopId] = nil
        lock.unlock()
    }
}

final class IOSDemoComputerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method: String = request.httpMethod ?? "GET"
        var status: Int = 404
        var body: String = ""
        if method == "GET", url.path == CompanionProtocol.healthPath {
            status = 200
            body = HealthResponse(protocolVersion: CompanionProtocol.version, paired: true).toJSON()
        } else if method == "GET", url.path == CompanionProtocol.helloPath {
            status = 200
            body = HelloResponse(desktopId: IOSDemoComputer.id, desktopName: IOSDemoComputer.name,
                                 protocolVersion: CompanionProtocol.version,
                                 maxUploadBytes: CompanionProtocol.maxUploadBytes).toJSON()
        } else if method == "PUT", url.path.hasPrefix(CompanionProtocol.inboxPrefix) {
            drainBody()
            status = 201
            body = InboxResponse(packageId: url.lastPathComponent, duplicate: false).toJSON()
        } else if method == "DELETE", url.path == CompanionProtocol.deviceSelfPath {
            status = 200
            body = "{}"
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": CompanionProtocol.jsonContentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands the body of a request to a protocol as a stream: read it to the end.
    private func drainBody() {
        guard let stream = request.httpBodyStream else { return }
        stream.open()
        defer { stream.close() }
        var buffer: [UInt8] = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable, stream.read(&buffer, maxLength: buffer.count) > 0 {}
    }
}
#endif
