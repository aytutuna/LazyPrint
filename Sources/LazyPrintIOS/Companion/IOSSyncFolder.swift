#if os(iOS)
import LazyPrintKit
import Foundation

/// The cloud folder of My computer: a folder in iCloud Drive or OneDrive that the computer also syncs, where files go,
/// sealed, when the computer cannot be reached. Picked in Files and kept as a bookmark (`PairedDesktop.syncFolderBookmark`),
/// opened and kept open while the app runs (`AppState.resolveSyncFolderBookmark`, set by `makeForIOS`).
@MainActor
public enum IOSSyncFolder {
    private static let kept: IOSBookmarkedFolder = IOSBookmarkedFolder()

    /// The bookmark of `folder`, picked in Files; throws when none can be made of it.
    public static func bookmark(of folder: URL) throws -> Data {
        try IOSBookmarkedFolder.bookmark(of: folder)
    }

    /// The folder `bookmark` stands for, opened, and the bookmark to keep (made again when iOS says it is stale); nil when it
    /// does not resolve.
    public static func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)? {
        kept.resolve(bookmark)
    }

    /// The folder is no longer used.
    public static func close() {
        kept.close()
    }

    /// The sealed files in `folder` the computer has not taken yet (it deletes each once it has it). Those of another phone
    /// syncing the same folder count too. Listed in a coordinated read, as the provider sees the folder.
    public static func waitingCount(in folder: URL) -> Int {
        var files: [URL] = []
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly,
                                                         error: &coordinationError) { (listed: URL) -> Void in
            files = (try? FileManager.default.contentsOfDirectory(
                at: listed, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        }
        return files.filter { $0.pathExtension.lowercased() == SyncPackage.fileExtension }.count
    }
}

/// A folder outside the app opened through its bookmark and kept open while the app runs.
@MainActor
final class IOSBookmarkedFolder {
    /// The folder open now and the bookmark it was opened with.
    private var opened: (folder: URL, bookmark: Data)?
    /// The folder whose security-scoped access was started, stopped when another is opened.
    private var accessed: URL?

    nonisolated init() {}

    /// The bookmark of `folder`, picked in Files; throws when none can be made of it.
    static func bookmark(of folder: URL) throws -> Data {
        let started: Bool = folder.startAccessingSecurityScopedResource()
        defer {
            if started { folder.stopAccessingSecurityScopedResource() }
        }
        return try folder.bookmarkData()
    }

    func resolve(_ bookmark: Data) -> (folder: URL, bookmark: Data)? {
        if let current = opened, current.bookmark == bookmark,
           (try? current.folder.checkResourceIsReachable()) == true {
            return current
        }
        var stale: Bool = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                    bookmarkDataIsStale: &stale) else {
            close()
            return nil
        }
        if opened?.folder != folder {
            close()
            if folder.startAccessingSecurityScopedResource() {
                accessed = folder
            }
        }
        var kept: Data = bookmark
        if stale, let fresh = try? folder.bookmarkData() {
            kept = fresh
        }
        opened = (folder: folder, bookmark: kept)
        return (folder: folder, bookmark: kept)
    }

    func close() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        opened = nil
    }
}
#endif
