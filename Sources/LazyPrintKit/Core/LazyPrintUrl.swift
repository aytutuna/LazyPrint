import Foundation

// Twin of windows/LazyPrint.Core/Core/LazyPrintUrl.cs: the same URL, the same files from it. They differ
// only in what a path may be: here any absolute path, there a local drive path. `handoff` is Swift only.

/// The address Lazy Scan opens Lazy Print with: `lazyprint:open?file=%2Ftmp%2Fscan.pdf`, the `file` parameter
/// repeated for each file. It only ever adds files to the job. The iPhone cannot read another app's paths, so Lazy Scan
/// there names a folder of the shared app group instead: `lazyprint:open?handoff=<uuid>`.
public enum LazyPrintUrl {
    public static let scheme = "lazyprint"
    public static let handoffGroup = "group.com.alazy.handoff"
    public static let handoffFolder = "Handoff"

    /// The files `url` asks to add, in order; none for any other address. A path that is not absolute is
    /// dropped. Unknown parameters are ignored.
    public static func parse(_ url: String?) -> [String] {
        var files: [String] = []
        for (name, text) in parameters(of: url) where name == "file" {
            let file = text.removingPercentEncoding ?? text
            if file.hasPrefix("/") && !file.contains("\0") { files.append(file) }
        }
        return files
    }

    /// The hand-off folder `url` names; nil for any other address or a `handoff` that is not a plain UUID (a path, or a
    /// name with a slash or dots in it), so the name can never lead out of the hand-off folder. The first one counts.
    public static func handoff(_ url: String?) -> UUID? {
        guard let text = parameters(of: url).first(where: { $0.name == "handoff" })?.value else { return nil }
        return UUID(uuidString: text.removingPercentEncoding ?? text)
    }

    /// The query's parameters of an address of ours (`lazyprint:open?...`, with `open` or no path), in order, the value
    /// not yet decoded; none for any other address.
    private static func parameters(of url: String?) -> [(name: String, value: String)] {
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
        var found: [(name: String, value: String)] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            found.append((name: String(pair[..<equals]), value: String(pair[pair.index(after: equals)...])))
        }
        return found
    }
}
