import Foundation

/// Opens the files a job starts with. `DocumentLoader` is the one implementation; tests pass stand-ins.
public protocol DocumentLoading: Sendable {
    /// Throws `PrintError.unreadable(sentence)` for a file that can't be printed.
    func load(_ url: URL) throws -> OpenedDocument
    /// The file as it is, for a PDF or an upright JPEG that can be sent unchanged; nil for the rest.
    func originalFile(_ document: OpenedDocument) -> URL?
}
