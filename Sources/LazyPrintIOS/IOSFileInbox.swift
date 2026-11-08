#if os(iOS)
import Foundation

/// Where the files the pickers and Open In hand over wait to be printed. What those give is security-scoped or may go
/// away when the picker closes, so each file is copied to `lp-files/<uuid>/<name>` in the temporary folder, under its
/// own name (two files of one name stay apart in folders of their own), and those copies go to `AppState.addFiles`.
/// The folder is emptied at launch.
public struct IOSFileInbox: Sendable {
    public let folder: URL

    /// `folder` nil: `lp-files` in the temporary folder (tests pass their own).
    public init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("lp-files", isDirectory: true)
    }

    /// Removes everything in the inbox.
    public func empty() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A copy of each file, in the order given, and the names of those that could not be copied. The copying is off the
    /// main actor: a file that is still in iCloud comes down first, and a big one takes a while.
    public func receive(_ urls: [URL]) async -> (copies: [URL], failed: [String]) {
        await Task.detached { () -> (copies: [URL], failed: [String]) in
            var copies: [URL] = []
            var failed: [String] = []
            for url in urls {
                if let copy = self.copied(url) {
                    copies.append(copy)
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            return (copies: copies, failed: failed)
        }.value
    }

    /// The copy of one file, read through a file coordinator; nil when it could not be made.
    private func copied(_ url: URL) -> URL? {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        var result: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { (readable: URL) -> Void in
            do {
                let target: URL = try place(url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: readable, to: target)
                    result = target
                } catch {
                    try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
                }
            } catch {}
        }
        return result
    }

    /// Removes a file Open In delivered, once its copy is made: with `LSSupportsOpeningDocumentsInPlace` off, iOS puts it
    /// in the app's own `Inbox` folder and never takes it away. A file from anywhere else is not the app's to delete.
    public func discardDelivered(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A file made of `data` (a photo from the library), named `name`.
    public func receive(_ data: Data, named name: String) throws -> URL {
        let target: URL = try place(name)
        do {
            try data.write(to: target)
        } catch {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            throw error
        }
        return target
    }

    /// The path of a new file called `name` in a folder of its own.
    private func place(_ name: String) throws -> URL {
        let slot: URL = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let leaf: String = URL(fileURLWithPath: name).lastPathComponent
        return slot.appendingPathComponent(leaf.isEmpty ? "file" : leaf)
    }
}
#endif
