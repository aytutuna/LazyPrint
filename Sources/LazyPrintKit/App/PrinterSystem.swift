import Foundation

/// The printers the operating system has set up. The Mac's is `CupsQueues` (LazyPrintMac); twin of the Windows
/// `IPrinterSystem`.
@MainActor
public protocol PrinterSystem: AnyObject {
    /// The queues as they are now, the virtual ones included (the merge leaves them out).
    func queues() async -> [SystemPrinter]
    /// What a queue can do, or nil when its driver would not say.
    func capabilities(ofQueue name: String) async -> PrinterCapabilities?
    /// Removes every job waiting in the queue.
    func clearJobs(ofQueue name: String) async throws
    /// Resumes a paused queue.
    func resume(queue name: String) async throws
    /// The jobs the queue holds, whoever sent them; none for a system that cannot list them.
    func jobs(ofQueue name: String) async throws -> [QueuedJob]
    /// Cancels one of the queue's jobs.
    func cancel(job id: Int, ofQueue name: String) async throws
}

extension PrinterSystem {
    public func jobs(ofQueue name: String) async throws -> [QueuedJob] { [] }
    public func cancel(job id: Int, ofQueue name: String) async throws {}
}

/// The printer system of an `AppState` whose app shell passed none: no queues.
@MainActor
final class NoPrinterSystem: PrinterSystem {
    func queues() async -> [SystemPrinter] { [] }
    func capabilities(ofQueue name: String) async -> PrinterCapabilities? { nil }
    func clearJobs(ofQueue name: String) async throws {}
    func resume(queue name: String) async throws {}
}
