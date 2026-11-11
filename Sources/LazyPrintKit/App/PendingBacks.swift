import Foundation

/// A two-sided job whose fronts are printed, kept in the settings folder while it waits for its backs, so the card can
/// come back if iOS ends the app meanwhile. Swift only: the Windows app is not ended while it waits.
public struct PendingBacks: Codable, Equatable, Sendable {
    var printerId: String
    var settings: PrintSettings
    var taskId: String?
    var range: [Int]?
    /// The documents' files; the job is not restored once any of them is gone.
    public var paths: [String]

    private static func file(in directory: URL) -> URL {
        directory.appendingPathComponent("pending-backs.json")
    }

    public static func load(in directory: URL) -> PendingBacks? {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
        return try? JSONDecoder().decode(PendingBacks.self, from: data)
    }

    func save(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: PendingBacks.file(in: directory), options: .atomic)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: file(in: directory))
    }
}
