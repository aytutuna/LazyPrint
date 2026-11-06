#if os(macOS)
import Darwin
import Foundation
import LazyPrintKit
import SystemConfiguration

// Twin of the phone link half of windows/LazyPrint.App/AppViewModel.Companion.cs: the server the Mac runs, started when a
// phone is paired or the phone sheet opens, with the pieces only the Mac has. `AppState` sees it as `CompanionHosting`.

/// The phone link of the Mac app: the `CompanionService` built from the keychain identity, the interfaces, DNS-SD and the
/// phones' sync keys. Nothing listens, and no certificate is made, until a phone is paired or the phone sheet opens.
@MainActor
final class MacCompanionHosting: ObservableObject, CompanionHosting {
    var onChange: (@MainActor () -> Void)?

    /// The phone link; nil until it is started, and when another copy of the app has it.
    @Published private(set) var service: CompanionService?
    /// Set every time the service says something changed, so a view showing the phones or the pairing follows.
    @Published private(set) var status = CompanionHostStatus.initial
    /// Why the link could not start; nil when it started or was not tried.
    @Published private(set) var error: String?
    /// The last file in the cloud folder that could not be read; nil since the folder was chosen.
    @Published private(set) var syncFolderProblem: String?
    /// Asks the user whether a phone that presented the pairing code may pair (the phone sheet answers). Without
    /// anyone to ask, the pairing is declined: a code is only shown where someone can answer.
    var confirmPairing: ((PairRequest) async -> Bool)?

    private let options: CompanionServiceOptions
    private var lockDescriptor: Int32 = -1

    init(options: CompanionServiceOptions) {
        self.options = options
    }

    /// The options the app runs with.
    static func standardOptions() -> CompanionServiceOptions {
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        let hostName = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "Mac"
        var options = CompanionServiceOptions(settingsDirectory: CompanionService.settingsFolder,
                                              dataDirectory: CompanionService.dataFolder(),
                                              identity: CompanionCertificateStore(hostName: hostName),
                                              networks: MacNetworkSource(), desktopName: computerName)
        options.advertiser = MacDnsSdAdvertiser()
        options.syncKeyStore = MacCompanionSyncKeys()
        options.resolveSyncFolder = { MacSyncFolder.shared.resolve($0) }
        return options
    }

    /// Starts the link at launch when a phone is paired.
    func startIfPaired() {
        if PairedDeviceStore(directory: options.settingsDirectory).count > 0 { ensure() }
    }

    /// The phone link, started now if it was not; nil when another copy of the app has it (`status.state` is
    /// `.elsewhere`) or it could not start (`error`).
    @discardableResult
    func ensure() -> CompanionService? {
        if let service { return service }
        guard status.state != .elsewhere else { return nil }
        // One copy of the app receives: the one holding the lock, which the system releases when it quits.
        let folder = options.dataDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor: Int32 = Darwin.open(folder.appendingPathComponent("companion.lock").path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            error = String(cString: strerror(errno))
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            status = CompanionHostStatus(state: .elsewhere, networks: [], endpoints: [])
            return nil
        }
        lockDescriptor = descriptor
        let service = CompanionService(options)
        service.router.approvePairing = { [weak self] request in
            await self?.askToPair(request) ?? false
        }
        service.onPackageReceived = { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
        service.onSyncFolderProblem = { [weak self] message in
            Task { @MainActor in self?.syncFolderProblem = message }
        }
        service.onChange = { [weak self] in
            Task { @MainActor in self?.serviceChanged() }
        }
        self.service = service
        error = nil
        Task { await service.start() }
        // Files that came before the app last closed and were not taken.
        onChange?()
        return service
    }

    /// Chooses the cloud folder phones put files in (nil: none); false when that could not be saved.
    @discardableResult
    func setSyncFolder(_ folder: URL?) -> Bool {
        var bookmark: Data?
        if let folder {
            guard let made = try? MacSyncFolder.bookmark(of: folder) else { return false }
            bookmark = made
        }
        guard let service, service.setSyncFolder(folder, bookmark: bookmark) else { return false }
        if folder == nil { MacSyncFolder.shared.close() }
        syncFolderProblem = nil
        return true
    }

    func batches(now: Date) -> [PhoneBatch] {
        service?.inbox.batches(now: now) ?? []
    }

    func take(batch: String) async -> [URL] {
        guard let inbox = service?.inbox else { return [] }
        let now = Date()
        return await Task.detached { inbox.take(batch: batch, now: now) }.value
    }

    func discard(batch: String) {
        service?.inbox.discard(batch: batch)
    }

    private func askToPair(_ request: PairRequest) async -> Bool {
        guard let ask = confirmPairing else { return false }
        return await ask(request)
    }

    private func serviceChanged() {
        guard let service else { return }
        status = service.status
        // Forgetting a phone deletes its waiting files.
        onChange?()
    }
}
#endif
