#if os(macOS)
import Foundation

/// The cloud folder of the phone link, kept as a security-scoped bookmark: a sandboxed app can open a folder the user
/// picked once, but only through the bookmark of it, not its path. The folder is opened when the bookmark is resolved and
/// stays open while the app runs, or until another folder is opened. Modelled on the iPhone's `IOSBookmarkedFolder`.
final class MacSyncFolder: @unchecked Sendable {
    static let shared = MacSyncFolder()

    private let lock = NSLock()
    /// The folder whose security-scoped access was started.
    private var accessed: URL?

    /// The bookmark of `folder`, picked in an open panel; throws when none can be made of it.
    static func bookmark(of folder: URL) throws -> Data {
        try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder `bookmark` stands for, opened, and the bookmark to keep (made again when it is stale); nil when it does
    /// not resolve.
    func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)? {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                    bookmarkDataIsStale: &stale) else {
            close()
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if accessed != folder {
            accessed?.stopAccessingSecurityScopedResource()
            accessed = folder.startAccessingSecurityScopedResource() ? folder : nil
        }
        if stale, let fresh = try? MacSyncFolder.bookmark(of: folder) {
            return (folder: folder, bookmark: fresh)
        }
        return (folder: folder, bookmark: bookmark)
    }

    func close() {
        lock.lock()
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        lock.unlock()
    }
}
#endif
