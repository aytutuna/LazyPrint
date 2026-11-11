import UIKit
import UniformTypeIdentifiers

/// The share sheet's Lazy Print: copies what was shared into `Shared/<uuid>` of the App Group, where the app picks it up
/// the next time it is in front, and says to open the app. An extension cannot open its app, so this only leaves the files.
final class ShareViewController: UIViewController {
    private let types: [UTType] = [.pdf, .image, .plainText]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Adding to Lazy Print"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        Task {
            let added: Int = await copyItems()
            label.text = added > 0 ? "Open Lazy Print to print" : "Lazy Print could not add this"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The number of shared items copied.
    private func copyItems() async -> Int {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.alazy.handoff") else {
            return 0
        }
        let folder: URL = group.appendingPathComponent("Shared", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return 0 }
        let providers: [NSItemProvider] = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var added: Int = 0
        for provider in providers {
            guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            if await copy(provider, type, into: folder) { added += 1 }
        }
        if added == 0 { try? FileManager.default.removeItem(at: folder) }
        return added
    }

    private func copy(_ provider: NSItemProvider, _ type: UTType, into folder: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { (url: URL?, _: Error?) in
                // The file is gone when this returns, so it is copied here.
                guard let url else {
                    continuation.resume(returning: false)
                    return
                }
                var target: URL = folder.appendingPathComponent(url.lastPathComponent)
                var n: Int = 1
                while FileManager.default.fileExists(atPath: target.path) {
                    n += 1
                    target = folder.appendingPathComponent("\(n)-\(url.lastPathComponent)")
                }
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: target)) != nil)
            }
        }
    }
}
