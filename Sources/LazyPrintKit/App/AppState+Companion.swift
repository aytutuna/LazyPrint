import Foundation

// The phone's side of the phone link: pairing with a computer from its code, checking the link and
// sending the job's files as print packages. The computer is the server (windows/LazyPrint.Core/Companion
// and, on the Mac, Companion/); this is the client, through `CompanionClient`. When the computer cannot
// be reached, files go through the cloud sync folder instead (`SyncPackage`).

/// The phone link's texts on the phone.
public enum CompanionText {
    public static let localNetworkOffReason = "Local Network access is off for Lazy Print. Turn it on in Settings."
    public static let refusedReason =
        "The computer is on this network but refused the connection. Check its firewall, or run the phone troubleshooter on the computer."
    public static let refusedSyncFolderReason =
        "The computer is on this network but refused the connection. Files go to the cloud folder instead."
    public static let notPairedMessage =
        "Pair this device with a computer first: choose Pair a phone in Lazy Print on the computer and scan its code."
    public static let outboxFullMessage =
        "\(PhoneOutbox.maxItems) files are waiting to be sent already. Send them, or remove some first."
    public static let unreachableMessage = "The computer cannot be reached."
    public static let wrongCertificateMessage =
        "The computer that answered is not the one this device was paired with. If pairing was reset there, pair again."
    public static let badResponseMessage = "The computer's answer could not be read."
    public static let notSavedMessage = "The pairing could not be saved on this device. Try again."
    public static let syncFolderHint = "Set a cloud folder in My computer to send when the computer cannot be reached."
    public static let syncFolderUnavailableMessage = "The cloud folder could not be opened. Choose it again in My computer."
    public static let syncFolderLine =
        "A folder in iCloud Drive or OneDrive that your computer also syncs. Files go here, encrypted, when the computer cannot be reached."
    public static let nothingToSendMessage = "Add a file to the job first."

    /// "Office PC is not on this network."
    public static func notOnNetworkReason(_ desktopName: String) -> String {
        "\(desktopName) is not on this network."
    }

    /// "Office PC cannot be reached on this network."
    public static func cannotReachMessage(_ desktopName: String) -> String {
        "\(desktopName) cannot be reached on this network."
    }

    /// "Paired with Office PC."
    public static func pairedMessage(_ desktopName: String) -> String {
        "Paired with \(desktopName)."
    }

    /// "This device is no longer paired with Office PC."
    public static func unpairedMessage(_ desktopName: String) -> String {
        "This device is no longer paired with \(desktopName)."
    }

    /// "3 files sent to Office PC."
    public static func sentMessage(_ fileCount: Int, desktopName: String) -> String {
        fileCount == 1 ? "1 file sent to \(desktopName)." : "\(fileCount) files sent to \(desktopName)."
    }

    /// "Report.pdf was not sent: This file is too large to send in one piece."
    public static func notSentMessage(_ fileName: String, reason: String) -> String {
        "\(fileName) was not sent: \(reason)"
    }

    /// "Put Report.pdf in the cloud folder for Office PC."
    public static func putInSyncFolderMessage(_ fileName: String, desktopName: String) -> String {
        "Put \(fileName) in the cloud folder for \(desktopName)."
    }

    /// "Put 3 files in the cloud folder for Office PC."
    public static func putInSyncFolderMessage(count: Int, desktopName: String) -> String {
        "Put \(count) files in the cloud folder for \(desktopName)."
    }

    /// "The computer refused the request (HTTP 501)."
    public static func refusedMessage(_ status: Int) -> String {
        "The computer refused the request (HTTP \(status))."
    }

    /// "Office PC cannot be reached on this network. The files wait here and go when it can."
    public static func waitingMessage(_ reason: String) -> String {
        "\(reason) The files wait here and go when it can."
    }

    /// "Scan.gif cannot be sent: only PDF, JPEG, PNG, HEIC and TIFF files can." Three names are listed, the rest counted.
    public static func notSendableMessage(_ fileNames: [String]) -> String {
        var list = fileNames.prefix(3).joined(separator: ", ")
        if fileNames.count > 3 { list += " and \(fileNames.count - 3) more" }
        return "\(list) cannot be sent: only PDF, JPEG, PNG, HEIC and TIFF files can."
    }
}

/// Where the link to the paired desktop stands.
public enum CompanionStatus: Equatable, Sendable {
    case notPaired
    /// A check or a pairing is under way, or the paired desktop has not been checked yet.
    case checking
    /// The desktop answered: its name.
    case reachable(desktopName: String)
    /// The desktop did not answer, or refused: why, as a sentence.
    case unreachable(reason: String)
    /// The desktop named no longer knows this phone (it was removed there): pair again.
    case unpaired(byDesktop: String)
}

extension AppState {
    /// Keeps the phone link's files in `folder` (companion-desktop.json and the "Outbox" folder; the iPhone's
    /// network folder, out of backups) and the device secret in `secrets` (the Keychain), and loads the paired
    /// desktop, `.checking` until `checkDesktop` runs. Set by the shell; without it the phone cannot pair.
    public func setUpCompanion(in folder: URL, secrets: any CompanionSecretStore) {
        let store = PairedDesktopStore(directory: folder, secrets: secrets)
        companionStore = store
        companionOutbox = PhoneOutbox(directory: folder.appendingPathComponent("Outbox", isDirectory: true))
        companionClient = nil
        companionDesktop = store.load()
        countOutbox()
        if let desktop = companionDesktop {
            companionStatus = store.secret(for: desktop) == nil ? .unpaired(byDesktop: desktop.name) : .checking
        } else {
            companionStatus = .notPaired
        }
    }

    /// Pairs with the desktop whose code is `uri` (scanned, or its text pasted), as `phoneName`. The
    /// desktop asks its user first, so this can take two minutes. The certificate that answers must be
    /// the one the code names. On success the desktop, its secret and its sync key are kept, replacing a
    /// desktop paired before; pairing the same desktop again keeps its sync folder. A refusal is said in
    /// the error bar with the desktop's own message, and the pairing kept before stays.
    public func pairDesktop(uri: String, phoneName: String) async {
        guard let store = companionStore else { return }
        let code: PairingUri
        do {
            code = try PairingUri.parse(uri)
        } catch {
            showFailure("Not paired", error.localizedDescription)
            return
        }
        var phoneId = companionDesktop?.phoneId ?? ""
        if !CompanionProtocol.isValidId(phoneId) { phoneId = PairedDesktop.makePhoneId() }
        var desktop = PairedDesktop(id: code.desktopId, name: code.name, fingerprint: code.fingerprint,
                                    addresses: code.addresses, port: code.port, phoneId: phoneId)
        guard !desktop.addresses.isEmpty else {
            showFailure("Not paired", CompanionText.notOnNetworkReason(code.name))
            return
        }
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let before = companionStatus
        companionStatus = .checking
        let client = CompanionClient(desktop: desktop, secret: nil, protocolClasses: companionProtocolClasses)
        do {
            let response = try await client.pair(token: code.token, phoneId: phoneId, phoneName: phoneName,
                                                 platform: platform, appVersion: version)
            guard let secret = CompanionProtocol.decodeBase64Url(response.deviceSecret) else {
                throw CompanionClientError.badResponse
            }
            desktop.id = response.desktopId
            if !response.desktopName.isEmpty { desktop.name = response.desktopName }
            desktop.pairedAt = Date()
            desktop.lastSeen = desktop.pairedAt
            if let before = companionDesktop, before.id == desktop.id {
                desktop.syncFolderBookmark = before.syncFolderBookmark
            }
            let syncKey = CompanionProtocol.decodeBase64Url(response.syncKey)
            try store.save(desktop, secret: secret, syncKey: syncKey?.count == SyncPackage.keyByteCount ? syncKey : nil)
        } catch {
            companionStatus = before
            if case .unreachable? = error as? CompanionClientError {
                showFailure("Not paired", companionUnreachableReason(desktop))
            } else {
                showFailure("Not paired", error.localizedDescription)
            }
            return
        }
        companionDesktop = desktop
        countOutbox()
        companionClient = client
        companionStatus = .reachable(desktopName: desktop.name)
        statusOverride = CompanionText.pairedMessage(desktop.name)
    }

    /// Tells the desktop to forget this phone (best effort: it may be off), then forgets the desktop
    /// and its secret. Files waiting to be sent stay, for that desktop only.
    public func unpairDesktop() async {
        guard let desktop = companionDesktop else { return }
        if let client = desktopClient() {
            try? await client.unpair()
        }
        companionStore?.remove()
        companionClient = nil
        companionDesktop = nil
        countOutbox()
        companionStatus = .notPaired
        statusOverride = CompanionText.unpairedMessage(desktop.name)
    }

    /// Asks the desktop how it is (`hello`) at its addresses: `.reachable`, keeping the name it gives now; a
    /// desktop that no longer knows this phone (401) loses its secret here and is `.unpaired`; one that does
    /// not answer is `.unreachable` with the reason (`companionUnreachableReason`), everything kept.
    public func checkDesktop() async {
        guard let desktop = companionDesktop else {
            companionStatus = .notPaired
            return
        }
        guard let client = desktopClient() else {
            companionStatus = .unpaired(byDesktop: desktop.name)
            return
        }
        companionStatus = .checking
        do {
            let hello = try await client.hello()
            // Unpaired or found at new addresses meanwhile: only what the answer says is kept.
            guard var current = companionDesktop, current.id == desktop.id else { return }
            if !hello.desktopName.isEmpty { current.name = hello.desktopName }
            current.lastSeen = Date()
            companionStore?.update(current)
            companionDesktop = current
            companionStatus = .reachable(desktopName: current.name)
        } catch {
            companionFailed(error, desktop)
        }
    }

    /// Packs the files of the job's documents as one batch into the outbox for the paired desktop and sends
    /// what waits there (`drainOutbox`); the job is not touched. Every document is a file the user gave, so
    /// each is sent as it is. A file that cannot be sent now waits in the outbox for the next time, said in
    /// a notice. `phoneName` is what the desktop shows for the sender. A file the link does not carry (a GIF or a BMP)
    /// is left out and named in the error bar; the others are sent, and the left-out file stays in the job.
    public func sendJobToDesktop(from phoneName: String) async {
        guard let outbox = companionOutbox, let desktop = companionDesktop, desktopClient() != nil else {
            showNotice("Not paired", CompanionText.notPairedMessage)
            return
        }
        var files: [(url: URL, type: String)] = []
        var leftOut: [String] = []
        for document in documents {
            let url = document.url
            guard let type = PrintPackage.contentType(ofFile: url) else {
                leftOut.append(url.lastPathComponent)
                continue
            }
            files.append((url, type))
        }
        guard !files.isEmpty else {
            if leftOut.isEmpty {
                showNotice("Nothing to send", CompanionText.nothingToSendMessage)
            } else {
                showFailure("Not sent", CompanionText.notSendableMessage(leftOut))
            }
            return
        }
        guard outbox.count + files.count <= PhoneOutbox.maxItems else {
            showFailure("Not sent", CompanionText.outboxFullMessage)
            return
        }
        let batch = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var queued: [String] = []
        do {
            for (index, file) in files.enumerated() {
                let item = try outbox.enqueue(file: file.url, name: file.url.lastPathComponent, contentType: file.type,
                                              batch: batch, index: index, count: files.count, from: phoneName,
                                              desktopId: desktop.id)
                queued.append(item.id)
            }
        } catch {
            for id in queued { outbox.remove(id) }
            showFailure("Not sent", error.localizedDescription)
            return
        }
        countOutbox()
        clearMessages()
        statusOverride = nil
        await drainOutbox()
        // The status line is not on every screen of the phone: say where the files are when they did not go.
        var waiting: String?
        if companionOutboxCount > 0, error == nil, sentMessage == nil, let reason = statusOverride {
            waiting = CompanionText.waitingMessage(reason)
        }
        guard !leftOut.isEmpty else {
            if let waiting { showNotice("Not sent yet", waiting) }
            return
        }
        // Said after the drain, which replaces what is in the bar; what it said is kept above the left-out files.
        let sent = sentMessage
        let leftOutMessage = CompanionText.notSendableMessage(leftOut)
        if let said = error?.detail ?? waiting {
            showFailure("Not sent", "\(said)\n\(leftOutMessage)")
        } else {
            showFailure("Not sent", leftOutMessage)
        }
        sentMessage = sent
    }

    /// Sends the files waiting in the outbox for the paired desktop one by one, oldest first (those queued
    /// for a desktop paired before wait for it), each removed once the desktop has it (a duplicate counts: it
    /// had it already). One the desktop refuses (too large, not readable) stays, said in the error bar, and
    /// the next is sent; when the desktop is busy or no longer knows this phone, the rest wait. When it does
    /// not answer, the rest go through the sync folder if the desktop handed out a sync key and a folder is
    /// set (`sendThroughSyncFolder`), except those it refused as too large or not readable (another error
    /// status sends the next too, but keeps the folder open); with a key but no folder, the status says once
    /// this session where to set one. One that failed to go into the folder before tries the folder first.
    /// One in the folder leaves once its file has left it (the desktop took it), or once it is sent over the
    /// network, its file then taken out of the folder. "3 files sent to Office PC."
    public func drainOutbox() async {
        guard !companionDraining, let outbox = companionOutbox, let desktop = companionDesktop,
              let client = desktopClient() else { return }
        companionDraining = true
        defer {
            companionDraining = false
            countOutbox()
        }
        var tried: Set<String> = []
        var sent = 0
        while let item = outbox.next(excluding: tried) {
            tried.insert(item.id)
            guard item.desktopId == desktop.id else { continue }
            if item.inSyncFolder, let folder = openSyncFolder(), !syncFolder(folder, holds: item.id) {
                outbox.markSent(item.id)
                countOutbox()
                continue
            }
            if item.viaSyncFolder, sendThroughSyncFolder(itemId: item.id) { continue }
            let data: Data
            do {
                data = try Data(contentsOf: outbox.fileURL(of: item), options: .mappedIfSafe)
            } catch {
                if FileManager.default.fileExists(atPath: outbox.fileURL(of: item).path) {
                    outbox.markFailed(item.id, error: error.localizedDescription)
                } else {
                    outbox.remove(item.id)
                }
                continue
            }
            do {
                _ = try await client.send(packageId: item.id, data: data)
                if item.inSyncFolder, let folder = openSyncFolder() {
                    try? AppState.coordinateWriting(folder.appendingPathComponent(SyncPackage.fileName(item.id)),
                                                    options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
                }
                outbox.markSent(item.id)
                sent += 1
                countOutbox()
            } catch {
                outbox.markFailed(item.id, error: error.localizedDescription)
                switch error as? CompanionClientError {
                case .tooLarge?, .invalidPackage?:
                    outbox.markRefused(item.id)
                    showFailure("Not sent", CompanionText.notSentMessage(item.name, reason: error.localizedDescription))
                    continue
                case .refused?:
                    // Not about the file itself (a 500, say): it may still go through the folder.
                    showFailure("Not sent", CompanionText.notSentMessage(item.name, reason: error.localizedDescription))
                    continue
                case .unreachable?:
                    companionFailed(error, desktop)
                    statusOverride = CompanionText.cannotReachMessage(desktop.name)
                    putInSyncFolder(for: desktop)
                default:
                    companionFailed(error, desktop)
                    statusOverride = error.localizedDescription
                }
                return
            }
        }
        if sent > 0 {
            let message = CompanionText.sentMessage(sent, desktopName: desktop.name)
            statusOverride = message
            sentMessage = message
            await checkDesktop()
        }
    }

    /// The paired desktop handed out a sync key, so files can go through a cloud sync folder.
    public var canUseSyncFolder: Bool {
        guard let desktop = companionDesktop else { return false }
        return companionStore?.syncKey(for: desktop) != nil
    }

    /// The files waiting in the outbox for the paired desktop that are in the sync folder, for the desktop
    /// to take from there.
    public var companionInSyncFolderCount: Int {
        companionOutbox?.items.filter { $0.inSyncFolder && isForPairedDesktop($0) }.count ?? 0
    }

    /// Keeps `bookmark` (made by the shell of the folder picked in My computer, in iCloud Drive or
    /// OneDrive) as the paired desktop's sync folder; nil forgets it. The desktop watches the same folder.
    /// Files put in the folder set before go again, into this one or over the network.
    public func setSyncFolder(bookmark: Data?) {
        guard var desktop = companionDesktop else { return }
        if bookmark != desktop.syncFolderBookmark, let outbox = companionOutbox {
            for item in outbox.items where item.desktopId == desktop.id && item.inSyncFolder {
                outbox.markInSyncFolder(item.id, false)
            }
        }
        desktop.syncFolderBookmark = bookmark
        companionStore?.update(desktop)
        companionDesktop = desktop
    }

    /// The sync folder of the paired desktop, opened through `resolveSyncFolderBookmark`, its bookmark
    /// brought up to date; nil without a folder or a resolver, or when it does not resolve now (the
    /// bookmark is kept).
    public func openSyncFolder() -> URL? {
        guard var desktop = companionDesktop, let bookmark = desktop.syncFolderBookmark,
              let resolve = resolveSyncFolderBookmark, let resolved = resolve(bookmark) else { return nil }
        if resolved.bookmark != bookmark {
            desktop.syncFolderBookmark = resolved.bookmark
            companionStore?.update(desktop)
            companionDesktop = desktop
        }
        return resolved.folder
    }

    /// Seals the waiting file `itemId` with the paired desktop's sync key (`SyncPackage`) and puts it in the
    /// sync folder as "<id>.lpsync", written whole in a coordinated write, so the provider (iCloud Drive,
    /// OneDrive) takes it as a new file and the desktop never takes half of it; it stays in the outbox,
    /// marked in the folder, until the desktop has it (`drainOutbox`). False when it is not for the paired
    /// desktop, the desktop refused it, it is in the folder already, or there is no key or folder; a folder
    /// that does not open or a write that fails is said in the error bar, and the file waits, to try the
    /// folder first the next time (one too large to seal counts as refused). "Put Report.pdf in the cloud
    /// folder for Office PC."
    @discardableResult
    public func sendThroughSyncFolder(itemId: String) -> Bool {
        guard let outbox = companionOutbox, let desktop = companionDesktop,
              let item = outbox.items.first(where: { $0.id == itemId }), item.desktopId == desktop.id,
              !item.refused, !item.inSyncFolder,
              let key = companionStore?.syncKey(for: desktop), desktop.syncFolderBookmark != nil else { return false }
        guard let folder = openSyncFolder() else {
            outbox.markViaSyncFolder(item.id)
            showFailure("Not sent", CompanionText.syncFolderUnavailableMessage)
            return false
        }
        do {
            let data = try Data(contentsOf: outbox.fileURL(of: item), options: .mappedIfSafe)
            let sealed = try SyncPackage.seal(packageId: item.id, phoneId: desktop.phoneId, plaintext: data, key: key)
            try AppState.coordinateWriting(folder.appendingPathComponent(SyncPackage.fileName(item.id)),
                                           options: .forReplacing) { try sealed.write(to: $0, options: .atomic) }
        } catch {
            outbox.markFailed(item.id, error: error.localizedDescription)
            // The desktop refuses it over the network too: the same limit.
            if (error as? SyncPackageError) == .tooLarge {
                outbox.markRefused(item.id)
            } else {
                outbox.markViaSyncFolder(item.id)
            }
            showFailure("Not sent", CompanionText.notSentMessage(item.name, reason: error.localizedDescription))
            return false
        }
        outbox.markInSyncFolder(item.id)
        let message = CompanionText.putInSyncFolderMessage(item.name, desktopName: desktop.name)
        statusOverride = message
        sentMessage = message
        return true
    }

    /// Removes the files waiting to be sent to the paired desktop (all of them while none is paired),
    /// unsent.
    public func clearOutbox() {
        guard let outbox = companionOutbox else { return }
        for item in outbox.items where isForPairedDesktop(item) {
            outbox.remove(item.id)
        }
        countOutbox()
    }

    /// Removes the files waiting for a desktop no longer paired while another is, unsent.
    public func clearOtherOutbox() {
        guard let outbox = companionOutbox else { return }
        for item in outbox.items where !isForPairedDesktop(item) {
            outbox.remove(item.id)
        }
        countOutbox()
    }

    /// The desktop with this id was found on the network (its DNS-SD service, TXT `id`) at `addresses`
    /// and `port`. When that is the paired desktop and they differ from the ones kept (a new DHCP
    /// lease), they replace them, IPv4 first, once the pinned certificate answers there, since anyone
    /// can advertise that id; the next request looks for its address anew. Returns whether they did.
    @discardableResult
    public func desktopFound(id: String, addresses: [String], port: Int) async -> Bool {
        guard let desktop = companionDesktop, desktop.id == id, (1...65535).contains(port) else { return false }
        var ipv4: [String] = []
        var ipv6: [String] = []
        for address in addresses where PairingUri.isValidAddress(address) && !ipv4.contains(address)
            && !ipv6.contains(address) {
            if address.contains(":") {
                ipv6.append(address)
            } else {
                ipv4.append(address)
            }
        }
        let found = Array((ipv4 + ipv6).prefix(PairingUri.maxAddresses))
        guard !found.isEmpty, Set(found) != Set(desktop.addresses) || port != desktop.port else { return false }
        var moved = desktop
        moved.addresses = found
        moved.port = port
        let probe = CompanionClient(desktop: moved, secret: nil, protocolClasses: companionProtocolClasses)
        guard (try? await probe.health()) != nil, var current = companionDesktop, current.id == id else { return false }
        current.addresses = found
        current.port = port
        companionStore?.update(current)
        companionDesktop = current
        companionClient = nil
        return true
    }

    /// Why the paired desktop does not answer: Local Network access is off (`companionAccessDenied`); else
    /// the desktop is seen on the network (`companionDesktopSeenOnNetwork`) and refuses the connection,
    /// and then the cloud folder is used when one is set for a desktop that handed out a sync key; else
    /// it is not on this network.
    func companionUnreachableReason(_ desktop: PairedDesktop) -> String {
        if companionAccessDenied?() == true {
            return CompanionText.localNetworkOffReason
        }
        guard companionDesktopSeenOnNetwork?(desktop.id) == true else {
            return CompanionText.notOnNetworkReason(desktop.name)
        }
        if desktop.syncFolderBookmark != nil, companionStore?.syncKey(for: desktop) != nil {
            return CompanionText.refusedSyncFolderReason
        }
        return CompanionText.refusedReason
    }

    // MARK: - Private

    /// The client of the paired desktop, made with its secret the first time; nil without either.
    private func desktopClient() -> CompanionClient? {
        if let client = companionClient { return client }
        guard let desktop = companionDesktop, let secret = companionStore?.secret(for: desktop) else { return nil }
        let client = CompanionClient(desktop: desktop, secret: secret, protocolClasses: companionProtocolClasses)
        companionClient = client
        return client
    }

    /// Whether `item` waits for the paired desktop; while none is paired, every one does.
    private func isForPairedDesktop(_ item: PhoneOutboxItem) -> Bool {
        guard let desktop = companionDesktop else { return true }
        return item.desktopId == desktop.id
    }

    /// Counts what waits in the outbox for the paired desktop, and apart what waits for another.
    private func countOutbox() {
        let items = companionOutbox?.items ?? []
        let waiting = items.filter { isForPairedDesktop($0) }.count
        companionOutboxCount = waiting
        companionOtherOutboxCount = items.count - waiting
    }

    /// `desktop` did not answer: what waits for it goes through the sync folder when it handed out a sync
    /// key and a folder is set; with a key but no folder, the status says where to set one, once.
    private func putInSyncFolder(for desktop: PairedDesktop) {
        guard let outbox = companionOutbox, companionStore?.syncKey(for: desktop) != nil else { return }
        guard companionDesktop?.syncFolderBookmark != nil else {
            if !companionSyncFolderHinted {
                companionSyncFolderHinted = true
                statusOverride = CompanionText.cannotReachMessage(desktop.name) + " " + CompanionText.syncFolderHint
            }
            return
        }
        var put = 0
        for item in outbox.items where item.desktopId == desktop.id && !item.inSyncFolder && !item.refused {
            if sendThroughSyncFolder(itemId: item.id) {
                put += 1
            } else if openSyncFolder() == nil {
                break
            }
        }
        if put > 1 {
            let message = CompanionText.putInSyncFolderMessage(count: put, desktopName: desktop.name)
            statusOverride = message
            sentMessage = message
        }
    }

    /// Whether `id`'s file is still in the sync folder `folder` (an iCloud file moved off the phone shows
    /// as ".<name>.icloud"); a folder that cannot be listed holds it.
    private func syncFolder(_ folder: URL, holds id: String) -> Bool {
        let name = SyncPackage.fileName(id)
        var holds = true
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: .immediatelyAvailableMetadataOnly,
                                                         error: &coordinationError) { listed in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: listed.path) else { return }
            holds = names.contains(name) || names.contains("." + name + ".icloud")
        }
        return holds
    }

    /// Runs `body` on `url` in a coordinated write, so the provider of a folder picked in Files learns of
    /// the change (an uncoordinated one may never be uploaded).
    private static func coordinateWriting(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                          _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options,
                                                         error: &coordinationError) { file in
            do {
                try body(file)
            } catch {
                failure = error
            }
        }
        if let failure = failure { throw failure }
        if let coordinationError = coordinationError { throw coordinationError }
    }

    /// What a failed request means for the link.
    private func companionFailed(_ error: Error, _ desktop: PairedDesktop) {
        // Unpaired, or another desktop paired, while the request ran.
        guard companionDesktop?.id == desktop.id else { return }
        switch error as? CompanionClientError {
        case .unauthorized?:
            companionStore?.forgetSecret(of: desktop)
            companionClient = nil
            companionStatus = .unpaired(byDesktop: desktop.name)
        case .unreachable?:
            companionStatus = .unreachable(reason: companionUnreachableReason(desktop))
        default:
            companionStatus = .unreachable(reason: error.localizedDescription)
        }
    }
}
