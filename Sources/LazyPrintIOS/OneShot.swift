#if os(iOS)
import Foundation

/// Resumes a wait once, whichever of the callers that may answer it comes first; the others are ignored. An answer that
/// comes before the continuation is handed over (`arm`) is kept for it.
final class OneShot<Value, Failure: Error>: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var continuation: CheckedContinuation<Value, Failure>?
    private var early: Result<Value, Failure>?
    private var finished: Bool = false

    init() {}

    init(_ continuation: CheckedContinuation<Value, Failure>) {
        self.continuation = continuation
    }

    func arm(_ continuation: CheckedContinuation<Value, Failure>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning value: Value) {
        finish(.success(value))
    }

    func resume(throwing error: Failure) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Failure>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        if let waiting = continuation {
            continuation = nil
            lock.unlock()
            waiting.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
    }
}
#endif
