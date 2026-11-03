import Foundation

/// Where an `AppState` keeps its files: the settings it reads when it is made and writes, the printer log, and the
/// folder the demo printer prints into. The app's own places (`standard`) in the app; a folder of their own in tests
/// (`all(in:)`), so a test never reads the user's settings or fills their Documents.
public struct AppStateFiles {
    /// Where settings.json, printers.json, ipp-hosts.json and ipp-trust.json are.
    public var settingsDirectory: URL
    /// Where printers.txt is written; nil: not written.
    public var logsDirectory: URL?
    /// The demo printer's folders of pictures, one per job.
    public var demoPrints: URL

    public init(settingsDirectory: URL, logsDirectory: URL?, demoPrints: URL) {
        self.settingsDirectory = settingsDirectory
        self.logsDirectory = logsDirectory
        self.demoPrints = demoPrints
    }

    /// Application Support/Lazy Print, ~/Library/Logs/Lazy Print and Documents/Lazy Print/Demo prints.
    public static var standard: AppStateFiles {
        let manager = FileManager.default
        let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        return AppStateFiles(
            settingsDirectory: StoreFiles.defaultDirectory,
            logsDirectory: library?.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Lazy Print", isDirectory: true),
            demoPrints: documents.appendingPathComponent("Lazy Print", isDirectory: true)
                .appendingPathComponent("Demo prints", isDirectory: true))
    }

    /// Everything in `folder`: its settings, a "logs" folder and a "Demo prints" folder.
    public static func all(in folder: URL) -> AppStateFiles {
        AppStateFiles(settingsDirectory: folder,
                      logsDirectory: folder.appendingPathComponent("logs", isDirectory: true),
                      demoPrints: folder.appendingPathComponent("Demo prints", isDirectory: true))
    }
}
