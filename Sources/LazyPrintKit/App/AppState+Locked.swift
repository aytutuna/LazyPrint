import Foundation

// Locked PDFs: the password is asked for in an alert, and typed once the file opens. It goes to the loader and is not kept:
// the unlocked document is what stays, for preview and printing.

extension AppState {
    /// Asks about the first locked PDF waiting, unless an alert is up already.
    func askNextPassword() {
        guard passwordRequest == nil, let url = lockedFiles.first else { return }
        passwordRequest = PasswordRequest(name: url.lastPathComponent, wrong: false)
    }

    /// The password typed in the alert. The file opens in the background; a wrong one asks again.
    public func submitPassword(_ password: String) {
        guard let url = lockedFiles.first else { return }
        passwordRequest = nil
        Task { await unlock(url, with: password) }
    }

    func unlock(_ url: URL, with password: String) async {
        passwordRequest = nil
        let opener = loader
        do {
            var document = try await Task.detached { try opener.load(url, password: password) }.value
            document.access = lockedAccess.removeValue(forKey: url)
            lockedFiles.removeAll { $0 == url }
            documents.append(document)
            rememberUnlocked(url)
            replan()
        } catch {
            if error as? PrintError == PrintError.unreadable(DocumentText.lockedPdf) {
                await alertDismissed()
                passwordRequest = PasswordRequest(name: url.lastPathComponent, wrong: true)
                return
            }
            lockedFiles.removeAll { $0 == url }
            lockedAccess[url] = nil
            lockedPicked[url] = nil
            reportNotAdded([(name: url.lastPathComponent, reason: error.localizedDescription)])
        }
        askNextPassword()
    }

    /// Cancel in the alert: the file stays out, with a short note.
    public func skipPassword() {
        guard let url = lockedFiles.first else { return }
        passwordRequest = nil
        lockedFiles.removeFirst()
        lockedAccess[url] = nil
        lockedPicked[url] = nil
        showNotice("Left out", DocumentText.lockedLeftOut(url.lastPathComponent))
        Task {
            await alertDismissed()
            askNextPassword()
        }
    }

    /// A presentation made while the last alert is still going away is dropped, so the next one waits.
    private func alertDismissed() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}
