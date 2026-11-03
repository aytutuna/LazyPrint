import Foundation

/// What the app does with files and text through the system. The Mac's is `SystemFileActions` (LazyPrintMac).
@MainActor
public protocol FileActionService: AnyObject {
    func open(_ url: URL) throws
    /// Shows the file in Finder, selected.
    func reveal(_ url: URL) throws
    /// A menu of the apps that can open the file.
    func openWith(_ url: URL) throws
    func copyText(_ text: String) throws
    /// Lazy Scan is installed (it has registered the lazyscan: scheme).
    func lazyScanInstalled() -> Bool
    func openLazyScan() throws
}

/// The file actions of an `AppState` whose app shell passed none: every action is refused.
@MainActor
final class UnavailableFileActions: FileActionService {
    private static let reason = "Files cannot be opened here."

    func open(_ url: URL) throws {
        throw PrintError.unreadable(Self.reason)
    }

    func reveal(_ url: URL) throws {
        throw PrintError.unreadable(Self.reason)
    }

    func openWith(_ url: URL) throws {
        throw PrintError.unreadable(Self.reason)
    }

    func copyText(_ text: String) throws {
        throw PrintError.unreadable("The text cannot be copied here.")
    }

    func lazyScanInstalled() -> Bool { false }

    func openLazyScan() throws {
        throw PrintError.unreadable("Lazy Scan cannot be opened here.")
    }
}
