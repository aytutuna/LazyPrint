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

    /// Parses "1-3, 5, 8-": single pages, ranges and an open range to the last page, separated by commas,
    /// counted from 1. Gives 0-based indices in the order typed, repeats kept. A page past `pageCount`
    /// is an error ("Page 9 is past the end (8 pages)").
    public static func parse(_ text: String, pageCount: Int) -> Result<[Int], PageRangeError> {
        var pages: [Int] = []
        for item in text.components(separatedBy: ",") {
            let part = item.trimmingCharacters(in: .whitespacesAndNewlines)
            let first: Int
            let last: Int
            if let dash = part.firstIndex(of: "-") {
                let end = String(part[part.index(after: dash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = String(part[..<dash]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let startNumber = pageNumber(start) else { return fail(usage) }
                first = startNumber
                if end.isEmpty {
                    last = max(first, pageCount)
                } else {
                    guard let endNumber = pageNumber(end), endNumber >= first else { return fail(usage) }
                    last = endNumber
                }
            } else {
                guard let single = pageNumber(part) else { return fail(usage) }
                first = single
                last = single
            }
            if last > pageCount {
                let past = first > pageCount ? first : last
                return fail("Page \(past) is past the end (\(pageCount) page\(pageCount == 1 ? "" : "s"))")
            }
            for page in first...last { pages.append(page - 1) }
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
