import Foundation

// Twin of windows/LazyPrint.Core/Core/PrintTask.cs (Lazy Scan's ScanTask, with print tasks).

/// What the user is printing, as picked from the Task menu. Settings files store it as its raw
/// value (`PrintSettings.taskId`), never as this enum, so a task added by a newer version
/// survives a round trip through an older one. Add new tasks after the existing ones.
/// Twin of C# `PrintTask` (`PrintTasks.All`, `RawValue`, `TryParse`).
public enum PrintTask: String, CaseIterable, Identifiable, Sendable {
    case document
    case twoSided
    case booklet
    case handouts
    case photos
    case photoSheet
    case testPage
    case scanAndPrint
    case fromPhone

    public var id: String { rawValue }

    /// The task stored as `rawValue`; nil for nil and for any other text (compared exactly),
    /// such as a task of a newer version.
    public static func tryParse(_ rawValue: String?) -> PrintTask? {
        guard let rawValue else { return nil }
        return PrintTask(rawValue: rawValue)
    }
}
