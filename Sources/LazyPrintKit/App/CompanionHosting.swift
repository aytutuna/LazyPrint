import Foundation

/// The Mac's side of the phone link as `AppState` sees it: the files paired phones sent, waiting to be added to a job.
/// The Mac shell passes the one that runs the server (`CompanionService`, with the keychain, interfaces and DNS-SD it
/// provides), so the Kit has none of those.
@MainActor
public protocol CompanionHosting: AnyObject {
    /// Set by `AppState`; called when a file arrived or a batch was taken.
    var onChange: (@MainActor () -> Void)? { get set }
    /// The batches in the inbox, oldest first, whole or not.
    func batches(now: Date) -> [PhoneBatch]
    /// Moves the batch's files out of the inbox, off the main actor (a file can be large), and gives their paths in
    /// the order the phone sent them. The ones that could not be moved stay in the inbox.
    func take(batch: String) async -> [URL]
    /// Deletes the batch's files that wait in the inbox.
    func discard(batch: String)
}

/// The phone link of an `AppState` whose app shell passed none: nothing ever arrives.
@MainActor
final class NoCompanionHosting: CompanionHosting {
    var onChange: (@MainActor () -> Void)?
    func batches(now: Date) -> [PhoneBatch] { [] }
    func take(batch: String) async -> [URL] { [] }
    func discard(batch: String) {}
}
