import Foundation

// Twin of windows/LazyPrint.Core/Layout/TextPages.cs: plain text set in lines and pages.

public enum TextPages {
    public static let fontSize: Double = 10.5
    public static let lineHeight: Double = 12.6
    public static let margin: Double = 54
    /// The advance of one character of the monospaced font (0.6 em); every line breaks by a count of them.
    public static let cellWidth: Double = 6.3

    private static let tabWidth = 4

    /// The lines of each page of a sheet of `page` size. Lines break at the last space that fits, or at the margin in a
    /// word that is longer; a form feed starts a page; tabs are stops of four; other control characters are dropped.
    /// Text with nothing but white space has no pages.
    public static func paginate(_ text: String, page: LayoutSize) -> [[String]] {
        if text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) { return [] }
        let columns = max(1, Int(((page.width - 2 * margin) / cellWidth).rounded(.down)))
        let rows = max(1, Int(((page.height - 2 * margin) / lineHeight).rounded(.down)))

        var parts = text.split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts[parts.count - 1].isEmpty { parts.removeLast() }
        var pages: [[String]] = []
        for part in parts {
            var source = lines(of: part)
            if source.count > 1, source[source.count - 1].isEmpty { source.removeLast() }
            var wrapped: [String] = []
            for line in source { wrap(line, columns: columns, into: &wrapped) }
            var at = 0
            while at < wrapped.count {
                pages.append(Array(wrapped[at..<min(wrapped.count, at + rows)]))
                at += rows
            }
        }
        return pages
    }

    /// The text of a file: UTF-8 (with or without a byte order mark) or UTF-16 with one, else Windows-1252.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: Data(bytes.dropFirst(3)), encoding: .utf8) { return text }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) { return text }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) { return text }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// The lines of a part, each ended by CR LF, CR, LF, NEL, LS or PS (the characters `ReplaceLineEndings` treats so).
    private static func lines(of part: String) -> [String] {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var previousWasReturn = false
        for scalar in part.unicodeScalars {
            switch scalar.value {
            case 0x0A where previousWasReturn:
                previousWasReturn = false
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                lines.append(String(line))
                line = String.UnicodeScalarView()
                previousWasReturn = scalar.value == 0x0D
            default:
                line.append(scalar)
                previousWasReturn = false
            }
        }
        lines.append(String(line))
        return lines
    }

    private static func wrap(_ line: String, columns: Int, into result: inout [String]) {
        var cells: [Unicode.Scalar] = []
        for scalar in line.unicodeScalars {
            if scalar == "\t" {
                repeat { cells.append(" ") } while cells.count % tabWidth != 0
            } else if scalar.properties.generalCategory != .control {
                cells.append(scalar)
            }
        }

        var start = 0
        var wrapped = false
        while cells.count - start > columns {
            var cut = start + columns
            if cells[cut] != " " {
                if let space = cells[start..<cut].lastIndex(of: " "), space > start { cut = space }
            }
            result.append(join(cells, start, cut))
            wrapped = true
            start = cut
            while start < cells.count && cells[start] == " " { start += 1 }
        }
        if start < cells.count || !wrapped { result.append(join(cells, start, cells.count)) }
    }

    private static func join(_ cells: [Unicode.Scalar], _ start: Int, _ end: Int) -> String {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: cells[start..<end])
        var line = String(text)
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }
}
