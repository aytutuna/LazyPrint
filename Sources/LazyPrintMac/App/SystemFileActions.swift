#if os(macOS)
import AppKit
import Foundation
import LazyPrintKit

/// The macOS implementation of `FileActionService`: NSWorkspace and NSPasteboard. The Open With menu opens at the mouse
/// pointer in the key window.
@MainActor
public final class SystemFileActions: FileActionService {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw PrintError.unreadable("No app could open \(url.lastPathComponent).")
        }
    }

    public func reveal(_ url: URL) throws {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openWith(_ url: URL) throws {
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView, let window = view.window else {
            throw PrintError.unreadable("The app window is not open.")
        }
        let menu = NSMenu(title: "Open With")
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            menu.addItem(Self.appItem(defaultApp, file: url, isDefault: true))
            if !apps.isEmpty { menu.addItem(.separator()) }
        }
        let sorted = apps.sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        for app in sorted {
            menu.addItem(Self.appItem(app, file: url, isDefault: false))
        }
        let pointer = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: Self.anchorPoint(pointer: pointer, bounds: view.bounds), in: view)
    }

    public func copyText(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw PrintError.unreadable("The pasteboard did not take the text.")
        }
    }

    public func lazyScanInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: Self.lazyScanURL) != nil
    }

    public func openLazyScan() throws {
        guard lazyScanInstalled(), NSWorkspace.shared.open(Self.lazyScanURL) else {
            throw PrintError.unreadable("Lazy Scan is not installed.")
        }
    }

    public func lazyPDFInstalled() -> Bool {
        Self.lazyPDFLocation() != nil
    }

    // Like Lazy PDF's own hand-off to Lazy Print: the file goes through NSWorkspace, which passes the sandbox grant with it.
    public func openInLazyPDF(_ url: URL) throws {
        guard let app = Self.lazyPDFLocation() else { throw PrintError.unreadable("Lazy PDF is not installed.") }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    // MARK: Pure

    /// Where Lazy PDF is, by its bundle id; a copy left in the Trash is still known to LaunchServices.
    private static func lazyPDFLocation() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.lazypdf.lazypdf").flatMap {
            $0.path.contains("/.Trash/") ? nil : $0
        }
    }

    /// What Lazy Scan registers: the scheme alone, so opening it brings the app forward.
    nonisolated static var lazyScanURL: URL { URL(string: "lazyscan:")! }

    /// Where the Open With menu opens in a content view with `bounds`: at the pointer when it is inside, else the centre.
    nonisolated static func anchorPoint(pointer: NSPoint, bounds: NSRect) -> NSPoint {
        bounds.contains(pointer) ? pointer : NSPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The menu's title for an app: its name, with "(default)" for the one the system opens the file with.
    nonisolated static func appTitle(_ name: String, isDefault: Bool) -> String {
        isDefault ? "\(name) (default)" : name
    }

    // MARK: Helpers

    private static func appItem(_ app: URL, file: URL, isDefault: Bool) -> NSMenuItem {
        let name = FileManager.default.displayName(atPath: app.path)
        let target = MenuActionTarget {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        }
        let item = NSMenuItem(title: appTitle(name, isDefault: isDefault), action: #selector(MenuActionTarget.run), keyEquivalent: "")
        // Menu targets are weak: the item keeps its own alive.
        item.target = target
        item.representedObject = target
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }
}

/// Runs a closure when its menu item is chosen.
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}
#endif
