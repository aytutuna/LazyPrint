import Foundation

// Twin of windows/LazyPrint.Core/Core/UserPresets.cs: presets.json, the presets the user saved.

/// A name and the option values it sets: everything in `PrintSettings` but the printer, the task, copies, the page selection and the order.
public struct UserPreset: Codable, Equatable, Sendable {
    public var name: String
    public var settings: PrintSettings

    public init(name: String = "", settings: PrintSettings = PrintSettings()) {
        self.name = name
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case name, settings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeLenient(forKey: .name, default: "")
        settings = c.decodeLenient(forKey: .settings, default: PrintSettings())
    }
}

public enum PresetNameCheck: Sendable {
    case ok
    case empty
    /// The name is a built-in preset's.
    case builtIn
    /// The name is another user preset's.
    case exists
}

public enum UserPresets {
    /// The names the built-in presets (the tasks) go by.
    private static var builtInNames: [String] { TaskCatalog.all.map(\.title) }

    /// Whether `name` can name a preset: not empty once trimmed, not a built-in preset's, and not another user preset's,
    /// ignoring case. `renaming` is the preset being renamed, which may keep its own name.
    public static func check(_ name: String, among presets: [UserPreset], renaming: String? = nil) -> PresetNameCheck {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return .empty }
        if builtInNames.contains(where: { same($0, clean) }) { return .builtIn }
        let taken = presets.contains { preset in
            same(preset.name, clean) && !(renaming.map { same(preset.name, $0) } ?? false)
        }
        return taken ? .exists : .ok
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    public static func find(_ name: String, in presets: [UserPreset]) -> UserPreset? {
        presets.first { same($0.name, name) }
    }

    /// The options of `settings` under `name` (trimmed).
    public static func make(_ name: String, from settings: PrintSettings) -> UserPreset {
        var options = settings
        options.printerId = nil
        options.printerName = nil
        options.taskId = nil
        options.copies = 1
        options.pageSelection = .all
        options.reverseOrder = false
        return UserPreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), settings: options)
    }

    /// The settings with the preset's options over them; the printer, copies, page selection and order stay, and no task is current.
    public static func apply(_ preset: UserPreset, to settings: PrintSettings) -> PrintSettings {
        var next = preset.settings
        next.printerId = settings.printerId
        next.printerName = settings.printerName
        next.taskId = nil
        next.copies = settings.copies
        next.pageSelection = settings.pageSelection
        next.reverseOrder = settings.reverseOrder
        return next
    }

    /// The settings still have every option the preset sets.
    public static func matches(_ preset: UserPreset, _ settings: PrintSettings) -> Bool {
        PrintSettings.sameInUse(apply(preset, to: settings), settings)
    }
}
