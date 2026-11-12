import Foundation
import Network

// Twin of windows/LazyPrint.Core/Companion/CompanionRouter.cs: the same routes, statuses,
// headers and error bodies. The C# events are closures here, set by the host before it starts, and
// the C# `CompanionRequestBody` stream reads through a closure (`CompanionServer` gives the connection).

/// A request's body: exactly its Content-Length of bytes (none without one), from what was read with
/// the head and then the connection. A client that sent `Expect: 100-continue` is told to send its
/// body only when the body is first read, so a request refused before that never sends it. Read by
/// one task at a time.
public final class CompanionRequestBody: @unchecked Sendable {
    /// Reads at most the given number of bytes from the connection; empty once it is closed.
    public typealias Source = (Int) async throws -> Data

    /// The body's length.
    public let length: Int64
    /// The bytes not read yet.
    public private(set) var remaining: Int64
    /// Reading began (and "100 Continue" was sent when asked for).
    public private(set) var hasStarted = false

    private var buffered: Data
    private let sendContinue: (() async throws -> Void)?
    private let source: Source

    /// - Parameters:
    ///   - length: The body's length (Content-Length; 0 without one).
    ///   - prefix: Bytes of the body that arrived with the head.
    ///   - sendContinue: Sends "100 Continue"; nil when the client did not ask for it.
    ///   - source: The connection after the head (or the whole body in tests).
    public init(length: Int64, prefix: Data = Data(), sendContinue: (() async throws -> Void)? = nil,
                source: @escaping Source) {
        self.length = length
        remaining = length
        buffered = Int64(prefix.count) > length ? Data(prefix.prefix(Int(length))) : prefix
        self.sendContinue = sendContinue
        self.source = source
    }

    /// The client still holds its body back: it asked to wait and was not told to send it.
    public var isWithheld: Bool {
        sendContinue != nil && !hasStarted && remaining > 0
    }

    /// The next bytes of the body, at most `maxLength`; empty at its end or when the connection closed early.
    public func read(maxLength: Int) async throws -> Data {
        guard remaining > 0, maxLength > 0 else { return Data() }
        if !hasStarted {
            hasStarted = true
            if let sendContinue { try await sendContinue() }
        }
        let chunk: Data
        if !buffered.isEmpty {
            let count = min(maxLength, buffered.count)
            chunk = Data(buffered.prefix(count))
            buffered = Data(buffered.dropFirst(count))
        } else {
            chunk = try await source(Int(min(Int64(maxLength), remaining)))
            if chunk.isEmpty { return Data() }
        }
        remaining -= Int64(chunk.count)
        return chunk
    }

    /// Reads and drops the rest of the body when it is at most `maxBytes`, so the connection can be
    /// closed without cutting the client off mid-send; a withheld body needs no reading. Returns
    /// whether nothing is left unread.
    public func discard(maxBytes: Int64) async throws -> Bool {
        if isWithheld || remaining == 0 { return true }
        if remaining > maxBytes { return false }
        while remaining > 0 {
            if try await read(maxLength: 81920).isEmpty { return false }
        }
        return true
    }
}

/// One request to the companion server: its head, its body and where it came from.
public struct CompanionRequest {
    public var head: HttpRequestHead
    public var body: CompanionRequestBody
    public var remote: NWEndpoint.Host

    public init(head: HttpRequestHead, body: CompanionRequestBody, remote: NWEndpoint.Host) {
        self.head = head
        self.body = body
        self.remote = remote
    }
}

/// A response: its status, headers and body.
public struct CompanionResponse {
    public let status: Int
    /// Headers besides Content-Length and Connection, which the server adds.
    public let headers: [HttpHeader]
    public let body: Data
    /// Called once by the server with whether the response was written to the client.
    public var written: (@Sendable (Bool) -> Void)?

    public static func json(_ status: Int, _ json: String, headers: [HttpHeader] = []) -> CompanionResponse {
        let body = Data(json.utf8)
        return CompanionResponse(status: status, headers: [HttpHeader("Content-Type", CompanionProtocol.jsonContentType)] + headers,
                                 body: body)
    }

    public static func error(_ status: Int, _ error: CompanionError, headers: [HttpHeader] = []) -> CompanionResponse {
        json(status, error.toJSON(), headers: headers)
    }

    public static func empty(_ status: Int) -> CompanionResponse {
        CompanionResponse(status: status, headers: [], body: Data())
    }

    /// The body as text (tests).
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// What the companion server does with each request (see `CompanionProtocol` for the endpoints).
/// Unpaired clients may only check reachability and pair with the open pairing session's token;
/// everything else needs a paired phone's id and secret, and a wrong secret gets 401. Every request
/// counts towards the sender's rate limit, every failed secret or token towards its failure limit.
/// The `on…` closures are called on the request's task.
public final class CompanionRouter: @unchecked Sendable {
    private let devices: PairedDeviceStore
    private let inbox: CompanionInbox
    private let limiter: CompanionRateLimiter
    private let clock: () -> Date
    private let lock = NSLock()
    private var awaiting = 0

    public init(devices: PairedDeviceStore, inbox: CompanionInbox, limiter: CompanionRateLimiter,
                clock: @escaping () -> Date = { Date() }) {
        self.devices = devices
        self.inbox = inbox
        self.limiter = limiter
        self.clock = clock
    }

    /// The name phones show for this desktop.
    public var desktopName: () -> String = { ProcessInfo.processInfo.hostName }

    /// The pairing session open now; nil when pairing is not open.
    public var currentPairing: () -> PairingSession? = { nil }

    /// Asks the user whether the phone that presented a valid token may pair. Without an answer within
    /// `approvalTimeout` the pairing is declined and the task asking is cancelled. The default declines
    /// too: a code is only shown where someone can answer.
    public var approvePairing: (PairRequest) async -> Bool = { _ in false }

    public var approvalTimeout: TimeInterval = 120

    public var onDevicePaired: ((PairedDevice) -> Void)?
    public var onPackageReceived: ((ReceivedPackage, PairedDevice) -> Void)?
    /// A phone forgot this desktop (`DELETE /v1/devices/self`).
    public var onDeviceRemoved: ((PairedDevice) -> Void)?
    /// A pairing request counted in `awaitingApproval` ended: paired, declined, refused or cut off.
    public var onApprovalSettled: (() -> Void)?

    /// Phones that presented a valid token and wait for the user's answer (their session is used
    /// already), and pairing requests whose token is being checked; the desktop keeps listening for
    /// them until the answer is in.
    public var awaitingApproval: Int {
        lock.lock()
        defer { lock.unlock() }
        return awaiting
    }

    public func handle(_ request: CompanionRequest) async -> CompanionResponse {
        let now = clock()
        guard limiter.tryRequest(request.remote, now: now) else {
            return .error(429, .rateLimited, headers: [HttpHeader("Retry-After", "60")])
        }
        let head = request.head
        let path = head.path
        switch path {
        case CompanionProtocol.healthPath:
            return head.method == "GET" ? health(request, now: now) : CompanionRouter.notAllowed("GET")
        case CompanionProtocol.pairPath:
            guard head.method == "POST" else { return CompanionRouter.notAllowed("POST") }
            return await pair(request, now: now)
        case CompanionProtocol.helloPath:
            return head.method == "GET" ? hello(request, now: now) : CompanionRouter.notAllowed("GET")
        case CompanionProtocol.deviceSelfPath:
            return head.method == "DELETE" ? removeSelf(request, now: now) : CompanionRouter.notAllowed("DELETE")
        default:
            break
        }
        if path.hasPrefix(CompanionProtocol.inboxPrefix) {
            guard head.method == "PUT" else { return CompanionRouter.notAllowed("PUT") }
            return await upload(request, packageId: String(path.dropFirst(CompanionProtocol.inboxPrefix.count)), now: now)
        }
        return .error(404, .notFound)
    }

    private static func notAllowed(_ allow: String) -> CompanionResponse {
        .error(405, .methodNotAllowed, headers: [HttpHeader("Allow", allow)])
    }

    private static func unauthorized() -> CompanionResponse {
        .error(401, .unauthorized, headers: [HttpHeader("WWW-Authenticate", "Bearer")])
    }

    /// The paired phone the request comes from; nil (a failure counted) when its id and secret do not match one.
    private func authenticate(_ request: CompanionRequest, now: Date) -> PairedDevice? {
        let result = devices.authenticateFirstUse(id: request.head.header(CompanionProtocol.deviceIdHeader),
                                                  secret: request.head.bearerToken, now: now)
        guard let result else {
            limiter.recordFailure(request.remote, now: now)
            return nil
        }
        if result.firstUse { onDevicePaired?(result.device) }
        return result.device
    }

    private func health(_ request: CompanionRequest, now: Date) -> CompanionResponse {
        var paired = false
        if request.head.bearerToken != nil || request.head.header(CompanionProtocol.deviceIdHeader) != nil {
            guard authenticate(request, now: now) != nil else { return CompanionRouter.unauthorized() }
            paired = true
        }
        return .json(200, HealthResponse(protocolVersion: CompanionProtocol.version, paired: paired).toJSON())
    }

    private func hello(_ request: CompanionRequest, now: Date) -> CompanionResponse {
        guard authenticate(request, now: now) != nil else { return CompanionRouter.unauthorized() }
        return .json(200, HelloResponse(desktopId: devices.desktopId, desktopName: desktopName(),
                                        protocolVersion: CompanionProtocol.version,
                                        maxUploadBytes: CompanionProtocol.maxUploadBytes).toJSON())
    }

    private func pair(_ request: CompanionRequest, now: Date) async -> CompanionResponse {
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Int64(CompanionProtocol.maxJsonBodyBytes) else { return .error(413, .tooLarge) }
        // Before the body is read: a body is only worth waiting for while a code is shown.
        guard let session = currentPairing() else { return .error(403, .pairingClosed) }
        guard let body = await CompanionRouter.readAll(request.body, length: length),
              var pair = PairRequest.fromJSON(body), CompanionProtocol.isValidId(pair.phoneId)
        else { return .error(400, .badRequest) }
        // Counted from before the token is used until the phone is stored (or refused), so the desktop
        // never stops listening in between: once the session is used it no longer keeps the link on.
        changeAwaiting(by: 1)
        var settleWhenWritten = false
        defer {
            if !settleWhenWritten { settleApproval() }
        }
        switch session.redeem(pair.token, now: now, peer: LocalSubnet.bytes(request.remote) ?? []) {
        case .wrongToken:
            limiter.recordFailure(request.remote, now: now)
            return .error(403, .tokenInvalid)
        case .expired:
            return .error(403, .tokenExpired)
        case .alreadyUsed:
            return .error(403, .tokenUsed)
        case .closed:
            return .error(403, .pairingClosed)
        case .accepted:
            break
        }
        let name = PairedDeviceStore.cleanName(pair.phoneName)
        pair.phoneName = name.isEmpty ? "Phone" : name
        let response = await approveAndPair(pair)
        settleWhenWritten = response.written != nil
        return response
    }

    private func settleApproval() {
        changeAwaiting(by: -1)
        onApprovalSettled?()
    }

    private func approveAndPair(_ pair: PairRequest) async -> CompanionResponse {
        guard await approve(pair) else { return .error(403, .declined) }
        let secret: String
        do {
            secret = try devices.prepare(id: pair.phoneId, name: pair.phoneName, platform: pair.platform,
                                         appVersion: pair.appVersion, now: clock())
        } catch PairedDeviceStoreError.tooManyDevices {
            return .error(409, .tooManyDevices)
        } catch {
            return .error(500, .serverError)
        }
        var response = CompanionResponse.json(200, PairResponse(desktopId: devices.desktopId, desktopName: desktopName(), deviceSecret: secret,
                                                                protocolVersion: CompanionProtocol.version,
                                                                syncKey: (try? devices.syncKey(for: pair.phoneId)).map(CompanionProtocol.encodeBase64Url)).toJSON())
        // The phone is only approved until it comes back with its secret (see authenticate); one that
        // never got the reply is dropped at once.
        let phoneId = pair.phoneId
        response.written = { [self] delivered in
            if !delivered { devices.discard(phoneId) }
            settleApproval()
        }
        return response
    }

    /// The user's answer; false when none came within `approvalTimeout` or the request was cut off.
    private func approve(_ pair: PairRequest) async -> Bool {
        let ask = approvePairing
        let timeout = approvalTimeout
        let (answers, answer) = AsyncStream.makeStream(of: Bool.self)
        let asking = Task {
            answer.yield(await ask(pair))
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            answer.yield(false)
        }
        var approved = false
        for await value in answers {
            approved = value
            break
        }
        answer.finish()
        asking.cancel()
        timer.cancel()
        return approved
    }

    private func upload(_ request: CompanionRequest, packageId: String, now: Date) async -> CompanionResponse {
        guard let device = authenticate(request, now: now) else { return CompanionRouter.unauthorized() }
        guard CompanionProtocol.isValidId(packageId) else { return .error(400, .badRequest) }
        guard let length = request.head.contentLength else { return .error(411, .lengthRequired) }
        guard length <= Int64(CompanionProtocol.maxUploadBytes) else { return .error(413, .tooLarge) }
        if let duplicate = await duplicate(request, deviceId: device.id, packageId: packageId) { return duplicate }
        guard inbox.tryBegin(deviceId: device.id, packageId: packageId) else { return .error(409, .busy) }
        defer { inbox.end(deviceId: device.id, packageId: packageId) }
        // It may have been received while this request waited.
        if let late = await duplicate(request, deviceId: device.id, packageId: packageId) { return late }
        do {
            let package = try await inbox.receive(deviceId: device.id, packageId: packageId, body: request.body,
                                                  length: length, now: now)
            onPackageReceived?(package, device)
            return .json(201, InboxResponse(packageId: packageId, duplicate: false).toJSON())
        } catch let error as PrintPackageError {
            return .error(422, CompanionError(code: CompanionErrorCode.invalidPackage, message: error.message))
        } catch CompanionInboxError.endedEarly {
            return .error(400, .badRequest)
        } catch CompanionInboxError.full {
            return .error(409, .inboxFull)
        } catch {
            return .error(500, .serverError)
        }
    }

    /// The answer for a package received before; nil when it was not. Its body is not needed again (a
    /// withheld one is never sent).
    private func duplicate(_ request: CompanionRequest, deviceId: String, packageId: String) async -> CompanionResponse? {
        guard inbox.find(deviceId: deviceId, packageId: packageId) != nil else { return nil }
        _ = try? await request.body.discard(maxBytes: Int64.max)
        return .json(200, InboxResponse(packageId: packageId, duplicate: true).toJSON())
    }

    private func removeSelf(_ request: CompanionRequest, now: Date) -> CompanionResponse {
        guard let device = authenticate(request, now: now) else { return CompanionRouter.unauthorized() }
        inbox.removeDevice(device.id)
        devices.remove(device.id)
        onDeviceRemoved?(device)
        return .empty(204)
    }

    private func changeAwaiting(by delta: Int) {
        lock.lock()
        awaiting += delta
        lock.unlock()
    }

    /// The whole body (small ones only); nil when it ended early or the connection broke.
    private static func readAll(_ body: CompanionRequestBody, length: Int64) async -> Data? {
        var bytes = Data()
        while Int64(bytes.count) < length {
            guard let chunk = try? await body.read(maxLength: Int(length) - bytes.count), !chunk.isEmpty else { return nil }
            bytes.append(chunk)
        }
        return bytes
    }
}
