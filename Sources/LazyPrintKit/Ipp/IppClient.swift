import Foundation
import Security

// Twin of windows/LazyPrint.Core/Ipp/IppClient.cs: the same rules and tests (IppClientTests), on URLSession.
// Deliberate differences: the client builds its session and the trust delegate itself, where the C# one is
// handed an HttpMessageHandler; Print-Job goes out as `upload(fromFile:)` of a body file (the encoded request,
// then the document) made beside the document and removed after the request, since URLSession has no body
// stream of known length it will not chunk; the request timeout is URLSession's idle timeout, which restarts
// as bytes move, so a document's 120 s run from the last byte it sends. An `IppCertificateError` is thrown as
// it is, so the caller can ask the user, where every other failure is a `PrintError`; the contract's
// `PrintError.certificateChanged` is therefore never thrown by the client.

/// Timeouts, retry timing and transport of an `IppClient`. Twin of C# `IppClientOptions`.
public struct IppClientOptions {
    /// Every request but Print-Job: a printer that does not answer this soon is treated as gone.
    public var requestTimeout: TimeInterval
    /// Print-Job: counted from the last byte sent, since printers answer only once they have taken the whole document.
    public var printTimeout: TimeInterval
    /// Waits between busy answers.
    public var retryPolicy: IppRetryPolicy
    /// How a retry waits; nil = real time (tests pass a fake clock).
    public var delay: ((TimeInterval) async throws -> Void)?
    /// Starts a clock for one request's retries, giving the time since its first attempt; nil = real time.
    public var startClock: (() -> (() -> TimeInterval))?
    /// The configuration the client's session is copied from; nil = `URLSessionConfiguration.ephemeral`.
    public var configuration: URLSessionConfiguration?

    public init(requestTimeout: TimeInterval = 10, printTimeout: TimeInterval = 120,
                retryPolicy: IppRetryPolicy = .default) {
        self.requestTimeout = requestTimeout
        self.printTimeout = printTimeout
        self.retryPolicy = retryPolicy
        self.delay = nil
        self.startClock = nil
        self.configuration = nil
    }
}

/// The TLS check of an `IppClient`'s session: the server trust challenge of each connection goes to `validator`
/// (C#: `IppCertificateValidator.CreateHandler`). An accepted certificate is used as the credential; a refused
/// one cancels the connection before any request is sent, and the validator keeps the refusal for the client to
/// report. Without a validator the system decides. A redirect from HTTPS to plain HTTP is never followed.
final class IppTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let validator: IppCertificateValidator?

    init(validator: IppCertificateValidator?) {
        self.validator = validator
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              let validator else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        var certificateDER: Data?
        var subject = ""
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            certificateDER = SecCertificateCopyData(leaf) as Data
            if let summary = SecCertificateCopySubjectSummary(leaf) {
                subject = summary as String
            }
        }
        let url = task.currentRequest?.url ?? task.originalRequest?.url
        if validator.validate(url: url, certificateDER: certificateDER, subject: subject, systemTrusted: systemTrusted) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let from = task.originalRequest?.url?.scheme?.lowercased() ?? ""
        let to = request.url?.scheme?.lowercased() ?? ""
        completionHandler(from == "https" && to != "https" ? nil : request)
    }
}

/// IPP over HTTP for one printer: its capabilities, Print-Job, Get-Job-Attributes and Cancel-Job. URLSession with
/// an ephemeral configuration and no proxy. Failures are `PrintError`s, or an `IppCertificateError` when
/// `validator` refused the printer's certificate. Twin of C# `IppClient`. Its session is released with the client.
public final class IppClient: @unchecked Sendable {
    public let printerName: String
    public let validator: IppCertificateValidator?

    private let userName: String
    private let options: IppClientOptions
    private let session: URLSession
    private let lock = NSLock()
    private var current: PrinterAddress
    private var lastRequestId: Int32 = 0
    private var speaks11 = false
    private var plainFallback = false

    /// `address` is where the printer answers; `address` follows it to ipps or back to ipp. `userName` is
    /// requesting-user-name: the account name, "iPhone" on the iPhone, the same for every request or Cancel-Job is
    /// refused.
    public init(address: PrinterAddress, printerName: String, userName: String,
                validator: IppCertificateValidator? = nil, options: IppClientOptions = IppClientOptions()) {
        self.current = address
        self.printerName = printerName
        self.userName = userName
        self.validator = validator
        self.options = options
        session = URLSession(configuration: IppClient.makeConfiguration(options),
                             delegate: IppTrustDelegate(validator: validator), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Where requests go now: moved to ipps by an HTTP 426, or back to ipp when the TLS handshake failed.
    public var address: PrinterAddress {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The printer is reached over plain ipp because its ipps would not complete a handshake.
    public var notEncrypted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return plainFallback
    }

    /// Get-Printer-Attributes. Remembers a printer without IPP 2.0 as 1.1 for the session, and pins a certificate
    /// accepted for first use once the printer's UUID shows it is not another key for a printer trusted before
    /// (`IppCertificateValidator.rememberDevice`).
    public func capabilities() async throws -> PrinterCapabilities {
        let response = try await roundTrip(document: nil) { uri, id in
            IppRequests.getPrinterAttributes(printerUri: uri, userName: self.userName, requestId: id)
        }
        try IppClient.succeeded(response)
        let capabilities = PrinterCapabilities.from(response)
        if !capabilities.ippVersionsSupported.isEmpty && !capabilities.speaks20 {
            setSpeaks11()
        }
        try validator?.rememberDevice(capabilities.uuid)
        return capabilities
    }

    /// Print-Job: the encoded request, then the file at `document` (an `IppSpool`'s), in one body with a
    /// Content-Length. A busy printer is asked again with the file sent again. The file is the caller's to delete.
    public func print(_ document: URL, ticket: IppJobTicket) async throws -> IppJob {
        // A first-use certificate is pinned (or refused) before the document goes out over it.
        if let validator, validator.hasPendingFirstUse, address.secure {
            _ = try await capabilities()
        }
        let response = try await roundTrip(document: document) { uri, id in
            IppRequests.printJob(printerUri: uri, userName: self.userName, ticket: ticket, requestId: id)
        }
        try IppClient.succeeded(response)
        guard let job = IppJob.from(response) else { throw PrintError.badResponse }
        if job.reasons.contains("job-password-wait") {
            _ = try? await cancel(job.id)
            throw PrintError.needsSignIn
        }
        return job
    }

    /// Get-Job-Attributes. A printer that no longer knows an accepted job may have finished it or lost it: that is
    /// `PrintError.lostContact`, since nothing says it was printed.
    public func job(_ id: Int) async throws -> IppJob {
        let response = try await roundTrip(document: nil) { uri, requestId in
            IppRequests.getJobAttributes(printerUri: uri, userName: self.userName, jobId: id, requestId: requestId)
        }
        if response.code == IppStatus.clientErrorNotFound.rawValue {
            throw PrintError.lostContact(name: printerName)
        }
        try IppClient.succeeded(response)
        guard let job = IppJob.from(response, id: id) else { throw PrintError.badResponse }
        return job
    }

    /// The printer's printer-state-reasons, for saying why a job waits.
    public func printerReasons() async throws -> [String] {
        let response = try await roundTrip(document: nil) { uri, id in
            IppRequests.getPrinterReasons(printerUri: uri, userName: self.userName, requestId: id)
        }
        try IppClient.succeeded(response)
        var reasons = [String]()
        for case .keyword(let reason) in response["printer-state-reasons"]?.values ?? [] {
            reasons.append(reason)
        }
        return reasons
    }

    /// Cancel-Job. A job the printer does not know, or can no longer cancel, is already over.
    public func cancel(_ id: Int) async throws {
        let response = try await roundTrip(document: nil) { uri, requestId in
            IppRequests.cancelJob(printerUri: uri, userName: self.userName, jobId: id, requestId: requestId)
        }
        if response.code == IppStatus.clientErrorNotFound.rawValue || response.code == IppStatus.clientErrorNotPossible.rawValue {
            return
        }
        try IppClient.succeeded(response)
    }

    // MARK: - Requests

    /// Sends one request and returns the printer's answer, whatever its IPP status. Busy answers are retried; HTTP
    /// 426 moves to ipps, a failed handshake to ipp, and IPP 0x0503 to version 1.1, each once.
    private func roundTrip(document: URL?, build: (String, Int32) -> IppMessage) async throws -> IppMessage {
        var switched = false
        while true {
            let target = address
            validator?.takeRejection() // a refusal left by an earlier request is not this one's
            let checksBefore = validator?.checkCount ?? 0
            var request = build(target.printerUri, nextRequestId())
            if lockedSpeaks11() {
                request = IppRequests.downgraded(request)
            }
            let head = request.encoded()
            let reply: IppReply
            do {
                reply = try await sendWithRetry(head, document, target)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    validator?.takeRejection()
                    throw CancellationError()
                }
                if let rejection = validator?.takeRejection() {
                    throw rejection
                }
                guard let failure = error as? URLError else { throw error }
                let handshake = failure.code == .secureConnectionFailed
                // Only a handshake that failed before any certificate was seen, for a printer not trusted before,
                // means the printer has no usable TLS; anything else could be someone cutting the connection.
                if handshake && target.secure && !switched, let validator, validator.checkCount == checksBefore,
                   !validator.knows(authority: target.authority) {
                    move(to: target.withSecure(false), notEncrypted: true)
                    switched = true
                    continue
                }
                if failure.code == .timedOut {
                    throw PrintError.unreachable(name: printerName, reason: "it did not answer in time")
                }
                throw PrintError.unreachable(name: printerName, reason: handshake ? "no secure connection" : IppClient.reason(failure))
            }

            if reply.status == 426 && !target.secure && !switched {
                move(to: target.withSecure(true), notEncrypted: false)
                switched = true
                continue
            }
            if reply.status == 401 {
                throw PrintError.needsSignIn
            }
            if IppRetry.isRetryable(reply.status) {
                throw PrintError.busy
            }
            guard let message = try? IppMessage.decode(reply.data).message else {
                if (200..<300).contains(reply.status) {
                    throw PrintError.badResponse
                }
                throw PrintError.unreachable(name: printerName, reason: "it answered HTTP \(reply.status)")
            }
            if message.code == IppStatus.serverErrorVersionNotSupported.rawValue && !lockedSpeaks11() {
                setSpeaks11()
                continue
            }
            return message
        }
    }

    private func sendWithRetry(_ head: Data, _ document: URL?, _ target: PrinterAddress) async throws -> IppReply {
        let elapsed = options.startClock?()
        let body = try document.map { try IppClient.bodyFile(head, $0) }
        defer {
            if let body { try? FileManager.default.removeItem(at: body) }
        }
        return try await IppRetry.send({ try await self.post(head, body, to: target) },
                                       statusCode: { $0.status },
                                       retryAfter: { $0.retryAfter },
                                       isBusy: { IppClient.isBusy($0) },
                                       policy: options.retryPolicy, delay: options.delay, elapsed: elapsed)
    }

    // A printer's answer is a few hundred KB at most; a bigger one is refused before it is all read.
    private static let maxResponse = 8 * 1024 * 1024

    private func post(_ head: Data, _ body: URL?, to target: PrinterAddress) async throws -> IppReply {
        guard let url = target.requestURL else { throw URLError(.badURL) }
        let timeout = body == nil ? options.requestTimeout : options.printTimeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        let result: (Data, URLResponse)
        if let body {
            // Print-Job's answer is small and URLSession hands an upload's answer over whole, so it is checked after.
            result = try await session.upload(for: request, fromFile: body)
            guard result.0.count <= IppClient.maxResponse else { throw PrintError.badResponse }
        } else {
            request.httpBody = head
            let (bytes, response) = try await session.bytes(for: request)
            guard response.expectedContentLength <= Int64(IppClient.maxResponse) else { throw PrintError.badResponse }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= IppClient.maxResponse else { throw PrintError.badResponse }
            }
            result = (data, response)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var retryAfter: TimeInterval?
        if let text = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(text.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            retryAfter = TimeInterval(seconds)
        }
        return IppReply(status: http.statusCode, retryAfter: retryAfter, data: result.0)
    }

    /// The request body as a file: its length is known, so it is never chunked. One file serves every retry of a request.
    private static func bodyFile(_ head: Data, _ document: URL) throws -> URL {
        let body = document.deletingLastPathComponent().appendingPathComponent("lp-body-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: body.path, contents: head) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: body)
            defer { try? output.close() }
            try output.seekToEnd()
            let input = try FileHandle(forReadingFrom: document)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: body)
            throw error
        }
        return body
    }

    private static func isBusy(_ reply: IppReply) -> Bool {
        if IppRetry.isRetryable(reply.status) {
            return true
        }
        guard let message = try? IppMessage.decode(reply.data).message, let status = IppStatus(rawValue: message.code) else {
            return false
        }
        return IppRetry.isRetryable(status)
    }

    private static func reason(_ failure: URLError) -> String {
        switch failure.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return "it did not answer"
        default:
            return failure.localizedDescription
        }
    }

    private static func succeeded(_ response: IppMessage) throws {
        if response.isSuccess {
            return
        }
        let code = response.code
        if code == IppStatus.clientErrorNotAuthenticated.rawValue || code == IppStatus.clientErrorNotAuthorized.rawValue {
            throw PrintError.needsSignIn
        }
        if code == IppStatus.serverErrorBusy.rawValue {
            throw PrintError.busy
        }
        var detail = ""
        if code == IppStatus.serverErrorNotAcceptingJobs.rawValue {
            detail = "The printer is not accepting jobs"
        } else if case .text(let message)? = response["status-message"]?.values.first {
            detail = message
        }
        throw PrintError.refused(status: code, detail: detail)
    }

    private static func makeConfiguration(_ options: IppClientOptions) -> URLSessionConfiguration {
        var configuration = URLSessionConfiguration.ephemeral
        if let given = options.configuration, let copy = given.copy() as? URLSessionConfiguration {
            configuration = copy
        }
        // Each request sets its own timeout; this one must not cut the longer ones short.
        configuration.timeoutIntervalForRequest = max(options.requestTimeout, options.printTimeout)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldUsePipelining = false
        return configuration
    }

    // MARK: - State

    private func nextRequestId() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        lastRequestId += 1
        return lastRequestId
    }

    private func lockedSpeaks11() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return speaks11
    }

    private func setSpeaks11() {
        lock.lock()
        speaks11 = true
        lock.unlock()
    }

    private func move(to address: PrinterAddress, notEncrypted: Bool) {
        lock.lock()
        current = address
        if notEncrypted {
            plainFallback = true
        }
        lock.unlock()
    }
}

/// An answer: its status, the Retry-After it asked for, and its body.
private struct IppReply {
    let status: Int
    let retryAfter: TimeInterval?
    let data: Data
}
