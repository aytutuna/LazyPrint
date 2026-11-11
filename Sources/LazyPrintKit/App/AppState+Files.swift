import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Files.cs: the recent files, and handing a document to Lazy PDF.

extension AppState {
    private var recentStore: RecentFiles { RecentFiles(directory: files.settingsDirectory) }

    /// Puts the files the user picked in the recent list, those of them that opened as documents. The iPhone opens copies
    /// of what was picked, so a file counts as opened when a document has its name.
    public func remember(_ picked: [URL]) {
        let opened = Set(documents.map { $0.url.lastPathComponent })
        let store = recentStore
        for url in picked where opened.contains(url.lastPathComponent) { store.add(url) }
        for url in picked {
            if let locked = lockedFiles.first(where: { $0.lastPathComponent == url.lastPathComponent }) { lockedPicked[locked] = url }
        }
        refreshRecent()
    }

    /// A locked PDF that opened with its password joins the list.
    func rememberUnlocked(_ url: URL) {
        guard let picked = lockedPicked.removeValue(forKey: url) else { return }
        recentStore.add(picked)
        refreshRecent()
    }

    /// Reads the list again; a file that is gone is dropped from it.
    func refreshRecent() {
        let store = recentStore
        var found: [RecentFile] = []
        for file in store.load() {
            let url = store.locate(file)
            // Outside the container a file cannot be looked at without the scope its bookmark gives.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: url.path) {
                found.append(file)
            } else {
                store.remove(URL(fileURLWithPath: file.path))
            }
        }
        recentFiles = found
    }

    /// The file to open for a recent entry, with the access its bookmark gives.
    public func recentURL(_ file: RecentFile) -> URL {
        recentStore.locate(file)
    }

    public func clearRecent() {
        recentStore.clear()
        recentFiles = []
    }

    /// A PDF read from a file of its own can be edited in Lazy PDF, when that is installed.
    public func canEditInLazyPDF(_ document: OpenedDocument) -> Bool {
        guard lazyPDFInstalled, case .pdf = document.loaded.kind else { return false }
        return userFiles.contains(document.url)
    }

    public func editInLazyPDF(_ document: OpenedDocument) {
        guard userFiles.contains(document.url) else { return }
        do {
            try fileActions.openInLazyPDF(document.url)
        } catch {
            showFailure("Lazy PDF did not open", error.localizedDescription)
        }
    }
}
