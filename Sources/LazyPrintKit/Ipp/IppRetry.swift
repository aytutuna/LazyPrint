import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppRetry.cs: the same policy and retry loop. The C# loop sends
// HttpClient requests; this one sends whatever the caller's closure sends (URLSession in the app) and
// reads the status and Retry-After through two more closures, so it stays free of any HTTP stack and
// is tested with a fake clock as the C# one is.

/// How long to keep retrying an IPP request a printer answers as busy (HTTP 503, or the IPP status
/// server-error-busy): the wait starts at `initialDelay`, grows by `multiplier` up to `maxDelay`, and
/// retrying stops once another wait would pass `giveUpAfter` since the first attempt. Times are in
/// seconds.
public struct IppRetryPolicy: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var giveUpAfter: TimeInterval

    public init(initialDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval, giveUpAfter: TimeInterval) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.giveUpAfter = giveUpAfter
    }

    public static let `default` = IppRetryPolicy(initialDelay: 0.5, multiplier: 1.5, maxDelay: 5, giveUpAfter: 60)

    /// The wait before retry number `retry` (0-based). A Retry-After the printer sent replaces the
    /// computed wait, kept within [initialDelay, maxDelay].
    public func delayBefore(_ retry: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let asked = retryAfter {
            return min(max(asked, initialDelay), maxDelay)
        }
        let seconds = initialDelay * pow(multiplier, Double(max(0, retry)))
        return seconds >= maxDelay ? maxDelay : seconds
    }
}

public enum IppRetry {
    /// The HTTP status that is retried: 503 Service Unavailable.
    public static func isRetryable(_ statusCode: Int) -> Bool {
        statusCode == 503
    }

    /// The IPP status that is retried: server-error-busy (0x0507).
    public static func isRetryable(_ status: IppStatus) -> Bool {
        status == .serverErrorBusy
    }

    /// Sends a request, repeating it while the printer says it is busy, per `policy`. Returns the
    /// first other response, or the last busy one once the policy gives up. `request` must send a
    /// fresh request each time; `statusCode` and `retryAfter` (the Retry-After header in seconds, nil
    /// when there is none) read its response. Busy is HTTP 503, or, when `isBusy` is given, whatever
    /// it says of the response (it may read the IPP status from the body). `delay` and `elapsed`
    /// (time since the first attempt) default to real time and exist so tests can run without
    /// waiting. Cancelling the task stops the retries with `CancellationError`.
    public static func send<Response>(_ request: () async throws -> Response,
                                      statusCode: (Response) -> Int,
                                      retryAfter: (Response) -> TimeInterval?,
                                      isBusy: ((Response) async throws -> Bool)? = nil,
                                      policy: IppRetryPolicy = .default,
                                      delay: ((TimeInterval) async throws -> Void)? = nil,
                                      elapsed: (() -> TimeInterval)? = nil) async throws -> Response {
        let start = ProcessInfo.processInfo.systemUptime
        var retry = 0
        while true {
            try Task.checkCancellation()
            let response = try await request()
            let busy: Bool
            if let isBusy {
                busy = try await isBusy(response)
            } else {
                busy = isRetryable(statusCode(response))
            }
            if !busy {
                return response
            }
            let wait = policy.delayBefore(retry, retryAfter: retryAfter(response))
            let spent = elapsed?() ?? ProcessInfo.processInfo.systemUptime - start
            if spent + wait > policy.giveUpAfter {
                return response
            }
            if let pause = delay {
                try await pause(wait)
            } else {
                try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            }
            retry += 1
        }
    }
}
