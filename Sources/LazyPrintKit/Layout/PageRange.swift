import Foundation

// Twin of windows/LazyPrint.Core/Layout/PageRange.cs: the pages a user types ("1-3, 5, 8-").

/// What is wrong with the typed pages, in words for the user.
public struct PageRangeError: Error, Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public enum PageRange {
    private static let usage = "Type pages like 1-3, 5"

    /// Parses "1-3, 5, 8-": single pages, ranges, an open range to the last page and a descending range ("5-2" is
    /// 5, 4, 3, 2), separated by commas, semicolons or spaces, with a hyphen, en dash or em dash in a range, counted
    /// from 1. Gives 0-based indices in the order typed, repeats kept. A page past `pageCount`
    /// is an error ("Page 9 is past the end (8 pages)").
    public static func parse(_ text: String, pageCount: Int) -> Result<[Int], PageRangeError> {
        var pages: [Int] = []
        let normal = text.replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        var parts: [String] = []
        for item in normal.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(contentsOf: trimmed.isEmpty ? [""] : trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        }
        for part in parts {
            let first: Int
            let last: Int
            if let dash = part.firstIndex(of: "-") {
                let end = String(part[part.index(after: dash)...])
                let start = String(part[..<dash])
                guard let startNumber = pageNumber(start) else { return fail(usage) }
                first = startNumber
                if end.isEmpty {
                    last = max(first, pageCount)
                } else {
                    guard let endNumber = pageNumber(end) else { return fail(usage) }
                    last = endNumber
                }
            } else {
                guard let single = pageNumber(part) else { return fail(usage) }
                first = single
                last = single
            }
            let low = min(first, last)
            let high = max(first, last)
            if high > pageCount {
                let past = low > pageCount ? low : high
                return fail("Page \(past) is past the end (\(pageCount) page\(pageCount == 1 ? "" : "s"))")
            }
            for page in stride(from: first, through: last, by: last >= first ? 1 : -1) { pages.append(page - 1) }
        }
        return .success(pages)
    }

    private static func fail(_ message: String) -> Result<[Int], PageRangeError> {
        .failure(PageRangeError(message: message))
    }

    /// A page number of digits only, 1 or more and within an Int32 (as the C# parse).
    private static func pageNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int32(text), value >= 1 else { return nil }
        return Int(value)
    }
}
