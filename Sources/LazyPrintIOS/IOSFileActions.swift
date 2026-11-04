#if os(iOS)
import LazyPrintKit
import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

/// The share sheet a file action asks for: the files, and the title it shows.
public struct ShareRequest: Identifiable, Equatable {
    public let id: UUID
    public let urls: [URL]
    public let title: String

    public init(urls: [URL], title: String) {
        self.id = UUID()
        self.urls = urls
        self.title = title
    }
}

/// The iPhone's `FileActionService`. iOS has no Finder and no "Open With" menu, so: Open previews the file (Quick Look),
/// Open With and Show open the share sheet (`UIActivityViewController`, where the user picks Files or another app; a
/// folder, such as a job of the demo printer, is shared as the files in it), and Copy text puts the text on the
/// pasteboard, on this device only. The app's root view presents what `shareRequest` and `previewURL` ask for; nothing
/// leaves the device unless the user picks where it goes in the share sheet.
@MainActor
public final class IOSFileActions: ObservableObject, FileActionService {
    /// The share sheet to show; the root view sets it back to nil when the sheet closes.
    @Published public var shareRequest: ShareRequest?
    /// The file to preview with Quick Look; nil when none is shown.
    @Published public var previewURL: URL?

    private let pasteboard: UIPasteboard
    private let openSystemURL: @MainActor (URL) -> Void
    private let canOpenSystemURL: @MainActor (URL) -> Bool

    /// `pasteboard` nil: the general pasteboard. `openSystemURL` and `canOpenSystemURL` nil: `UIApplication`'s (tests
    /// pass their own, so no other app opens).
    public init(pasteboard: UIPasteboard? = nil, openSystemURL: (@MainActor (URL) -> Void)? = nil,
                canOpenSystemURL: (@MainActor (URL) -> Bool)? = nil) {
        self.pasteboard = pasteboard ?? UIPasteboard.general
        if let openSystemURL {
            self.openSystemURL = openSystemURL
        } else {
            self.openSystemURL = { (url: URL) -> Void in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        if let canOpenSystemURL {
            self.canOpenSystemURL = canOpenSystemURL
        } else {
            self.canOpenSystemURL = { (url: URL) -> Bool in
                UIApplication.shared.canOpenURL(url)
            }
        }
    }

    /// What Lazy Scan registers: the scheme alone, so opening it brings the app forward. `canOpenURL` needs the scheme in
    /// `LSApplicationQueriesSchemes`.
    nonisolated static var lazyScanURL: URL { URL(string: "lazyscan:")! }

    public func open(_ url: URL) throws {
        previewURL = url
    }

    public func openWith(_ url: URL) throws {
        try share([url], title: url.lastPathComponent)
    }

    public func reveal(_ url: URL) throws {
        try share(IOSFileActions.files(in: url), title: url.lastPathComponent)
    }

    /// Asks for the share sheet with `urls`.
    public func share(_ urls: [URL], title: String) throws {
        guard !urls.isEmpty else {
            throw PrintError.unreadable("There is nothing to share.")
        }
        shareRequest = ShareRequest(urls: urls, title: title)
    }

    public func copyText(_ text: String) throws {
        let item: [String: Any] = [UTType.utf8PlainText.identifier: text]
        pasteboard.setItems([item], options: [UIPasteboard.OptionsKey.localOnly: true])
    }

    public func lazyScanInstalled() -> Bool {
        canOpenSystemURL(IOSFileActions.lazyScanURL)
    }

    public func openLazyScan() throws {
        guard lazyScanInstalled() else {
            throw PrintError.unreadable("Lazy Scan is not installed.")
        }
        openSystemURL(IOSFileActions.lazyScanURL)
    }

    /// What is shared for `url`: the file itself, or for a folder the files in it, by name.
    nonisolated static func files(in url: URL) -> [URL] {
        let isFolder: Bool = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        guard isFolder else { return [url] }
        let listed: [URL] = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
        return listed.sorted { (a: URL, b: URL) -> Bool in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }
}
#endif
