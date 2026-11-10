import Foundation

// Twin of windows/LazyPrint.Core/Core/LazyPrintUrl.cs: the same URL, the same files from it. They differ
// only in what a path may be: here any absolute path, there a local drive path.

/// The address Lazy Scan opens Lazy Print with: `lazyprint:open?file=%2Ftmp%2Fscan.pdf`, the `file` parameter
/// repeated for each file. It only ever adds files to the job. The iPhone cannot read another app's paths, so there Lazy
/// Scan names a folder both apps share instead: `lazyprint:open?handoff=<uuid>`, the folder `Handoff/<uuid>` of the
/// `handoffGroup` container (the address has one `handoff` and no `file`).
public enum LazyPrintUrl {
    public static let scheme = "lazyprint"
    public static let handoffGroup = "group.com.alazy.handoff"
    public static let handoffFolder = "Handoff"

    /// The files `url` asks to add, in order; none for any other address. A path that is not absolute is
    /// dropped. Unknown parameters are ignored.
    public static func parse(_ url: String?) -> [String] {
        var files: [String] = []
        for pair in pairs(of: url) {
            guard let equals = pair.firstIndex(of: "="), pair[..<equals] == "file" else { continue }
            let text = String(pair[pair.index(after: equals)...])
            let file = text.removingPercentEncoding ?? text
            if file.hasPrefix("/") && !file.contains("\0") { files.append(file) }
        }
        return files
    }

    /// The hand-off `url` names, `lazyprint:open?handoff=<uuid>`; nil for any other address, or when the value is
    /// not a UUID (it becomes a folder name, so nothing else gets through). Swift only.
    public static func parseHandoff(_ url: String?) -> UUID? {
        for pair in pairs(of: url) {
            guard let equals = pair.firstIndex(of: "="), pair[..<equals] == "handoff" else { continue }
            let text = String(pair[pair.index(after: equals)...])
            return UUID(uuidString: text.removingPercentEncoding ?? text)
        }
        return nil
    }

    /// The `name=value` pairs of a `lazyprint:open` address; none for any other address.
    private static func pairs(of url: String?) -> [Substring] {
        guard let url, url.range(of: scheme + ":", options: [.anchored, .caseInsensitive]) != nil else { return [] }
        var rest = String(url.dropFirst(scheme.count + 1))
        if let fragment = rest.firstIndex(of: "#") { rest = String(rest[..<fragment]) }
        var path = rest
        var query = ""
        if let mark = rest.firstIndex(of: "?") {
            path = String(rest[..<mark])
            query = String(rest[rest.index(after: mark)...])
        }
        if path.hasPrefix("//") { path = String(path.dropFirst(2)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty && path.lowercased() != "open" { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false)
    }
}
