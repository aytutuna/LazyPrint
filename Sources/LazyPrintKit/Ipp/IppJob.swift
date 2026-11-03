import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppJob.cs: a job as the printer reports it.

/// The job-state of RFC 8011 §5.3.7. A value the printer sends that is not listed reads as `unknown`.
public enum IppJobState: Int, Sendable {
    case unknown = 0
    case pending = 3
    case pendingHeld = 4
    case processing = 5
    case processingStopped = 6
    case canceled = 7
    case aborted = 8
    case completed = 9
}

/// A job on a printer: `reasons` are its job-state-reasons, `impressions` the sides printed so far.
public struct IppJob: Equatable, Sendable {
    public var id: Int
    public var state: IppJobState
    public var reasons: [String]
    public var impressions: Int

    public init(id: Int, state: IppJobState, reasons: [String], impressions: Int) {
        self.id = id
        self.state = state
        self.reasons = reasons
        self.impressions = impressions
    }

    /// The printer is done with it, one way or another.
    public var isFinished: Bool {
        state == .canceled || state == .aborted || state == .completed
    }

    /// The job a Print-Job or Get-Job-Attributes response describes; `id` is used when it names none.
    static func from(_ message: IppMessage, id: Int? = nil) -> IppJob? {
        var jobId = id
        if case .integer(let number)? = message["job-id"]?.values.first {
            jobId = Int(number)
        }
        guard let known = jobId else { return nil }
        var state = IppJobState.unknown
        if case .enumValue(let code)? = message["job-state"]?.values.first, let listed = IppJobState(rawValue: Int(code)) {
            state = listed
        }
        var reasons = [String]()
        for case .keyword(let reason) in message["job-state-reasons"]?.values ?? [] {
            reasons.append(reason)
        }
        var impressions = 0
        if case .integer(let done)? = message["job-impressions-completed"]?.values.first {
            impressions = Int(done)
        }
        return IppJob(id: known, state: state, reasons: reasons, impressions: impressions)
    }
}
