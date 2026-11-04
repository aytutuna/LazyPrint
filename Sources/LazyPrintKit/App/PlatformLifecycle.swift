import Foundation

/// When the app is about to end and when it comes to the front, as the platform reports it. `AppState` writes the
/// settings when the app may end and reads the printers again when it comes back. Each app shell passes its own;
/// tests pass a stand-in that sends the events by hand. Twin of Lazy Scan's.
@MainActor
public protocol PlatformLifecycle: AnyObject {
    /// Runs `handler` on the main actor when the app may end now: it is about to quit (and, where the system ends apps
    /// in the background without telling them, it has gone to the background).
    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void)
    /// Runs `handler` on the main actor each time the app comes to the front.
    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void)
}

/// Time the system gives the app to finish a piece of work once it has gone to the background: the iPhone's is
/// `UIKitBackgroundActivity` (LazyPrintIOS); the Mac passes none, since a Mac app keeps running. A pass of a print job
/// asks for it while it runs. Twin of Lazy Scan's.
@MainActor
public protocol BackgroundActivity: AnyObject {
    /// Asks for time to finish `name` should the app go to the background. When that time is nearly up, `expired` runs
    /// on the main actor (once) and the work must stop; the few seconds left are for it to wind down, and it gives the
    /// time back with `endActivity` as usual. Returns the token `endActivity` takes, or nil when the system gives no time
    /// now.
    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int?
    /// The work is done (or stopped): gives the time back. A token that has ended already is ignored.
    func endActivity(_ token: Int)
}

/// The background time of an `AppState` whose app shell passed none: none is asked for.
@MainActor
final class NoBackgroundActivity: BackgroundActivity {
    func beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? { nil }
    func endActivity(_ token: Int) {}
}
