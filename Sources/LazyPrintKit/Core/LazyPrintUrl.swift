import Foundation

// Twin of windows/LazyPrint.Core/Core/LazyPrintUrl.cs: the same URL, the same files from it. They differ
// only in what a path may be: here any absolute path, there a local drive path.

/// The address Lazy Scan opens Lazy Print with: `lazyprint:open?file=%2Ftmp%2Fscan.pdf`, the `file` parameter
/// repeated for each file. It only ever adds files to the job.
public enum LazyPrintUrl {
    public static let scheme = "lazyprint"

    /// The files `url` asks to add, in order; none for any other address. A path that is not absolute is
    /// dropped. Unknown parameters are ignored.
    public static func parse(_ url: String?) -> [String] {
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
        var files: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "="), pair[..<equals] == "file" else { continue }
            let text = String(pair[pair.index(after: equals)...])
            let file = text.removingPercentEncoding ?? text
            if file.hasPrefix("/") && !file.contains("\0") { files.append(file) }
        }
        return files
    }
}
