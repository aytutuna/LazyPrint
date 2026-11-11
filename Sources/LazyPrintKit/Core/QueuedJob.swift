import Foundation

// Twin of windows/LazyPrint.Core/Core/QueuedJob.cs: a job a printer or the system's queue holds, whoever sent it.

public enum QueuedJobState: Sendable {
    case waiting
    case held
    case printing
    case stopped
}

/// A job in a printer's queue. `pages` is 0 when the queue does not say; `canCancel` is set when the queue would let
/// this user cancel it: the job is theirs.
public struct QueuedJob: Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var owner: String
    public var state: QueuedJobState
    public var pages: Int
    public var canCancel: Bool

    public init(id: Int, name: String, owner: String, state: QueuedJobState, pages: Int, canCancel: Bool) {
        self.id = id
        self.name = name
        self.owner = owner
        self.state = state
        self.pages = pages
        self.canCancel = canCancel
    }

    /// The jobs of a Get-Jobs response that are still to print, in the printer's order. A job the user does not own
    /// cannot be cancelled.
    static func from(_ response: IppMessage, userName: String) -> [QueuedJob] {
        var jobs = [QueuedJob]()
        for group in response.groups where group.tag == IppTag.jobAttributes {
            func value(_ name: String) -> IppValue? { group.attributes.first(where: { $0.name == name })?.values.first }
            func text(_ name: String) -> String? {
                switch value(name) {
                case .name(let text)?, .text(let text)?: return text
                default: return nil
                }
            }
            func number(_ name: String) -> Int? {
                switch value(name) {
                case .integer(let number)?, .enumValue(let number)?: return Int(number)
                default: return nil
                }
            }
            guard let id = number("job-id") else { continue }
            let state: QueuedJobState
            switch number("job-state") {
            case IppJobState.pending.rawValue?: state = .waiting
            case IppJobState.pendingHeld.rawValue?: state = .held
            case IppJobState.processing.rawValue?: state = .printing
            case IppJobState.processingStopped.rawValue?: state = .stopped
            default: continue
            }
            let owner = text("job-originating-user-name") ?? ""
            jobs.append(QueuedJob(id: id, name: text("job-name") ?? "", owner: owner, state: state,
                                  pages: number("job-impressions-completed") ?? 0,
                                  canCancel: owner.caseInsensitiveCompare(userName) == .orderedSame))
        }
        return jobs
    }
}
