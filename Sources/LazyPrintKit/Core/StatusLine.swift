import Foundation

// Twin of windows/LazyPrint.Core/Core/StatusLine.cs (Lazy Scan's StatusLine): the status line's short text.
// Both apps show at most six words of their status sentence, facts only, and keep the whole sentence as
// the line's accessibility label.

/// The status line's visible text: at most `maxWords` words, facts only. The full sentence stays the
/// status line's accessibility label, so VoiceOver reads all of it. Twin of C# `StatusLine`.
public enum StatusLine {
    public static let maxWords = 6

    /// Words as the text spec counts them: whitespace-separated tokens with a letter or digit.
    public static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { isWord($0) }.count
    }

    /// `message`'s short form. `printerName`: the printer, for "Ready — HP LaserJet" after a task is
    /// picked. A change made to the job keeps a short warning on the line ("Sent 3 sheets · 2 blank
    /// added"); when the line can't hold both, the warnings win.
    public static func short(_ message: String, printerName: String? = nil) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        let found = findWarnings(text)
        var head = ""
        if found.notesAt > 0 {
            let before = (text as NSString).substring(to: found.notesAt)
            head = headOf(before.trimmingCharacters(in: .whitespacesAndNewlines), printerName: printerName)
        }
        return compose(head, found.shorts)
    }

    /// `head` with the short warnings found in `message`, the same way `short` adds them: "Printed ·
    /// shrunk to 82 %", or the warnings alone when the line can't hold both; just `head` when there
    /// are none.
    public static func withWarnings(_ head: String, message: String) -> String {
        compose(head, warnings(message))
    }

    /// The short warnings in `message`, in the order they come.
    public static func warnings(_ message: String) -> [String] {
        findWarnings(message.trimmingCharacters(in: .whitespacesAndNewlines)).shorts
    }

    // MARK: - Private

    /// A token with a letter or a digit.
    private static func isWord(_ token: Substring) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    /// The notes `PrintText` adds to a status sentence when a job was changed to fit, each with its
    /// short form (a template): a warning stays visible, not only in the label.
    private static let jobNotes = [
        (pattern: "(\\d+) blank pages? added", short: "$1 blank added"),
        (pattern: "Pages made smaller \\((\\d+) %\\)", short: "Shrunk to $1 %"),
    ]

    /// The warnings in `text`, and where the first note starts (UTF-16 offset; the text's length
    /// when none does).
    private static func findWarnings(_ text: String) -> (shorts: [String], notesAt: Int) {
        // The notes are appended after the message: the message is what comes before the first one.
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found = [(at: Int, short: String)]()
        var notesAt = ns.length
        for note in jobNotes {
            guard let regex = try? NSRegularExpression(pattern: note.pattern) else { continue }
            for match in regex.matches(in: text, options: [], range: whole) {
                let short = regex.replacementString(for: match, in: text, offset: 0, template: note.short)
                found.append((at: match.range.location, short: short))
                notesAt = min(notesAt, match.range.location)
            }
        }
        return (shorts: found.sorted { $0.at < $1.at }.map { $0.short }, notesAt: notesAt)
    }

    /// The head, then the warnings while they fit; when the line can't hold both, the warnings win.
    private static func compose(_ head: String, _ shorts: [String]) -> String {
        guard let firstShort = shorts.first else { return head }
        if !head.isEmpty {
            let all = ([head] + shorts.map { lowerFirst($0) }).joined(separator: " \u{00B7} ")
            if words(all) <= maxWords { return all }
        }
        // Not room for the message too: the warnings alone, as many as fit, then how many more.
        var shown = firstShort
        var i = 1
        while i < shorts.count {
            let next = shown + " \u{00B7} " + lowerFirst(shorts[i])
            // While more would follow, keep a word free for "+N".
            if words(next) > maxWords - (i < shorts.count - 1 ? 1 : 0) { break }
            shown = next
            i += 1
        }
        return i < shorts.count ? "\(shown) +\(shorts.count - i)" : shown
    }

    /// "Shrunk to 82 %" after a message reads "… · shrunk to 82 %"; "2 blank added" stays as it is.
    private static func lowerFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    /// The groups of `pattern`'s first match in `text` (group 0 is the whole match); nil when it does
    /// not match.
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
    }

    /// The short form of the message itself (without the notes after it).
    private static func headOf(_ text: String, printerName: String?) -> String {
        if text.isEmpty { return "" }
        if text.hasPrefix("Ready for \u{201C}") {
            if let name = printerName, !name.isEmpty { return "Ready \u{2014} \(name)" }
            return "Ready"
        }
        if let sent = groups("^Sent (\\d+) (sheets?)\\b", in: text) {
            return "Sent \(sent[1]) \(sent[2])"
        }

        // Anything else: its first sentence, then what comes before a dash or a colon, then its whole facts.
        let first = firstSentence(text)
        if words(first) <= maxWords { return first }
        for mark in [" \u{2014} ", ": ", ", "] {
            if let range = first.range(of: mark), range.lowerBound > first.startIndex {
                let before = String(first[first.startIndex..<range.lowerBound])
                if words(before) <= maxWords { return before }
            }
        }
        // Facts joined by " · " ("9 pages · 3 sheets · 2 blank added"): the whole facts that fit.
        let facts = first.components(separatedBy: " \u{00B7} ")
        if facts.count > 1, words(facts[0]) <= maxWords {
            var shown = facts[0]
            for fact in facts.dropFirst() {
                let next = shown + " \u{00B7} " + fact
                if words(next) > maxWords { break }
                shown = next
            }
            return shown
        }
        var kept = [Substring]()
        var count = 0
        for token in first.split(separator: " ", omittingEmptySubsequences: true) {
            if isWord(token) {
                count += 1
                if count > maxWords { break }
            }
            kept.append(token)
        }
        var joined = kept.joined(separator: " ")
        while let last = joined.last, ",:;. ".contains(last) {
            joined.removeLast()
        }
        return joined + "\u{2026}"
    }

    /// The first sentence without its full stop ("…" is kept: it says work is under way).
    private static func firstSentence(_ text: String) -> String {
        let chars = Array(text)
        var i = 0
        while i + 2 < chars.count {
            let next = chars[i + 2]
            if ".!?".contains(chars[i]) && chars[i + 1] == " " && (next.isUppercase || next.isNumber) {
                return String(chars[0..<i])
            }
            i += 1
        }
        if text.hasSuffix(".") && !text.hasSuffix("\u{2026}") { return String(text.dropLast()) }
        return text
    }
}
