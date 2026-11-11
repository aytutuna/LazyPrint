import Foundation

// Twin of windows/LazyPrint.App/Services/RecentFiles.cs. A sandboxed app can open a file again only through the bookmark
// it made when the file was chosen, so each entry keeps one beside the path that is shown and compared.

/// A file in the recent list: where it was, how to get back to it, and when it was last opened.
public struct RecentFile: Codable, Equatable {
    public var path = ""
    public var bookmark = Data()
    public var opened = Date(timeIntervalSince1970: 0)

    public init(path: String, bookmark: Data, opened: Date) {
        self.path = path
        self.bookmark = bookmark
        self.opened = opened
    }

    private enum CodingKeys: String, CodingKey {
        case path, bookmark, opened
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.decodeLenient(forKey: .path, default: path)
        bookmark = c.decodeLenient(forKey: .bookmark, default: bookmark)
        opened = c.decodeLenient(forKey: .opened, default: opened)
    }
}

struct RecentList: Codable {
    var files: [RecentFile] = []

    init(files: [RecentFile] = []) {
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = c.decodeLenient(forKey: .files, default: files)
    }

    private enum CodingKeys: String, CodingKey {
        case files
    }
}

/// The files opened last, newest first, in recent.json beside the settings.
public final class RecentFiles {
    public static let limit = 10

    private let file: URL

    public init(directory: URL) {
        file = directory.appendingPathComponent("recent.json")
    }

    public func load() -> [RecentFile] {
        let files = StoreFiles.load(RecentList.self, from: file)?.files ?? []
        return Array(files.filter { !$0.path.isEmpty }.prefix(Self.limit))
    }

    public func add(_ url: URL, now: Date = Date()) {
        let files = load().filter { !Self.same($0.path, url.path) }
        write([RecentFile(path: url.path, bookmark: Self.bookmark(of: url) ?? Data(), opened: now)] + files)
    }

    public func remove(_ url: URL) {
        write(load().filter { !Self.same($0.path, url.path) })
    }

    public func clear() {
        write([])
    }

    /// Where the file is now: through its bookmark, else by the path it had. A stale bookmark is made again.
    public func locate(_ recent: RecentFile) -> URL {
        if !recent.bookmark.isEmpty, let found = Self.resolve(recent.bookmark) {
            if found.stale, let fresh = Self.bookmark(of: found.url) { refresh(recent, fresh) }
            return found.url
        }
        return URL(fileURLWithPath: recent.path)
    }

    private func refresh(_ recent: RecentFile, _ bookmark: Data) {
        var files = load()
        guard let at = files.firstIndex(where: { $0.path == recent.path }) else { return }
        files[at].bookmark = bookmark
        write(files)
    }

    private func write(_ files: [RecentFile]) {
        StoreFiles.write(RecentList(files: Array(files.prefix(Self.limit))), to: file)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(b.precomposedStringWithCanonicalMapping) == .orderedSame
    }

    // The Mac needs the app-scoped kind; on iOS a url from the importer carries its scope, and the bookmark made from it
    // keeps the grant. Resolving takes no UI and mounts nothing, so an unplugged volume cannot stall the window.
    private static func bookmark(of url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
#if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
#else
        return try? url.bookmarkData()
#endif
    }

    private static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
#if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
#else
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
#endif
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (url, stale)
    }
}
