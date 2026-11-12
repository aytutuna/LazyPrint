import CryptoKit
import Foundation

// Twin of windows/LazyPrint.Core/Companion/PairedDeviceStore.cs: the same rules for pairing,
// checking and removing phones; each platform keeps its own file in its own settings folder.

/// A phone paired with this desktop (an entry of companion-devices.json).
public struct PairedDevice: Codable, Equatable, Sendable {
    /// The phone's id (`CompanionProtocol.isValidId`), sent with every request.
    public var id = ""
    /// The phone's name as it gave it when pairing ("Aytu's iPhone").
    public var name = ""
    /// "ios", "ipados", "android"…, as the phone said.
    public var platform = ""
    public var appVersion = ""
    /// SHA-256 of the phone's secret, lowercase hex (`PairedDeviceStore.hashSecret`). The secret itself
    /// is never stored: a copy of this file does not let anyone pose as the phone.
    public var secretHash = ""
    public var paired: Date?
    /// When the phone last made a request, to the minute.
    public var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, platform, appVersion, secretHash, paired, lastSeen
    }

    public init() {}
}

extension PairedDevice {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        name = c.decodeLenient(forKey: .name, default: name)
        platform = c.decodeLenient(forKey: .platform, default: platform)
        appVersion = c.decodeLenient(forKey: .appVersion, default: appVersion)
        secretHash = c.decodeLenient(forKey: .secretHash, default: secretHash)
        paired = c.decodeLenient(forKey: .paired, default: paired)
        lastSeen = c.decodeLenient(forKey: .lastSeen, default: lastSeen)
    }
}

/// The contents of companion-devices.json.
public struct PairedDevicesFile: Codable, Equatable, Sendable {
    /// This desktop's id for phones (32 hex digits), made on first use.
    public var desktopId = ""
    public var devices: [PairedDevice] = []
    /// The cloud sync folder phones put files in when they cannot reach this computer, as a
    /// path; "" for none.
    public var syncFolder = ""
    /// A security-scoped bookmark of the sync folder, for an app that cannot reach a bare path (the sandboxed Mac
    /// app); nil when none was made. `syncFolder` stays beside it as the text to show.
    public var syncFolderBookmark: Data?

    enum CodingKeys: String, CodingKey {
        case desktopId, devices, syncFolder, syncFolderBookmark
    }

    public init() {}
}

extension PairedDevicesFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        devices = c.decodeLenient(forKey: .devices, default: devices)
        syncFolder = c.decodeLenient(forKey: .syncFolder, default: syncFolder)
        syncFolderBookmark = c.decodeLenient(forKey: .syncFolderBookmark, default: syncFolderBookmark)
    }
}

/// Why a phone could not be paired.
public enum PairedDeviceStoreError: Error, Equatable, Sendable {
    case invalidId
    case invalidSecret
    /// `PairedDeviceStore.maxDevices` other phones are paired.
    case tooManyDevices
    /// The pairing could not be saved (a phone must not believe it is paired when it is not).
    case notSaved
}

/// The phones paired with this desktop (companion-devices.json in the settings folder, Global rule 5 of
/// CONTRACTS.md). Pairing makes a random 256-bit secret, hands it to the phone once and keeps only its
/// SHA-256; a request is accepted when its device id and secret match an entry. It also makes the phone's
/// sync key for the cloud sync folder, kept in `syncKeyStore` (the Mac's Keychain), never in the file;
/// without a store no key is made, and the phone is not offered the folder. The file is re-read
/// for every check and before every change, so a phone removed elsewhere is refused at once; a phone
/// removed while the file could not be written stays removed for the rest of the session. Safe to use
/// from any thread.
public final class PairedDeviceStore: @unchecked Sendable {
    public static let fileName = "companion-devices.json"
    /// The secret's length in bytes.
    public static let secretByteCount = 32
    /// How many phones can be paired at once.
    public static let maxDevices = 16
    /// A phone's last-seen time is written at most this often.
    public static let lastSeenResolution: TimeInterval = 60
    /// How long an approved phone waits for its first request before it is dropped.
    public static let pendingLifetime: TimeInterval = 120

    private let url: URL
    private let syncKeyStore: (any CompanionSecretStore)?
    private let lock = NSLock()
    private var file: PairedDevicesFile
    /// Phones removed in this session: never accepted again, whatever the file says.
    private var removed: Set<String> = []
    /// Approved phones that have not made a request with their new secret yet; never written to the file.
    private var pending: [String: (device: PairedDevice, since: Date)] = [:]

    /// Called (on the thread that changed it) after a phone was paired or removed.
    public var onChange: (() -> Void)?

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps companion-devices.json in `directory`, and the phones' sync keys in `syncKeyStore` under
    /// their ids.
    public init(directory: URL, syncKeyStore: (any CompanionSecretStore)? = nil) {
        url = directory.appendingPathComponent(PairedDeviceStore.fileName)
        self.syncKeyStore = syncKeyStore
        file = PairedDeviceStore.load(url) ?? PairedDevicesFile()
    }

    /// This desktop's id; made and saved the first time it is asked for.
    public var desktopId: String {
        lock.lock()
        defer { lock.unlock() }
        reload()
        if !CompanionProtocol.isValidId(file.desktopId) {
            file.desktopId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            StoreFiles.write(file, to: url)
        }
        return file.desktopId
    }

    /// The paired phones, in the order they were paired.
    public var devices: [PairedDevice] {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.devices
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.devices.count
    }

    /// The cloud sync folder phones put files in; nil when none is chosen.
    public var syncFolder: URL? {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.syncFolder.isEmpty ? nil : URL(fileURLWithPath: file.syncFolder, isDirectory: true)
    }

    /// The bookmark of the sync folder; nil when none was kept.
    public var syncFolderBookmark: Data? {
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.syncFolderBookmark
    }

    /// Chooses the cloud sync folder (nil: none), with the bookmark that opens it where a path alone does not; false
    /// when that could not be saved.
    @discardableResult
    public func setSyncFolder(_ folder: URL?, bookmark: Data? = nil) -> Bool {
        lock.lock()
        reload()
        let previous = (path: file.syncFolder, bookmark: file.syncFolderBookmark)
        file.syncFolder = folder?.path ?? ""
        file.syncFolderBookmark = folder == nil ? nil : bookmark
        let saved = StoreFiles.write(file, to: url)
        if !saved {
            file.syncFolder = previous.path
            file.syncFolderBookmark = previous.bookmark
        }
        lock.unlock()
        if saved { onChange?() }
        return saved
    }

    /// Pairs the phone `id` (pairing again replaces its entry and secret, and keeps its sync key, so what
    /// it put in the sync folder before still opens) and returns its new secret (base64url of 32 bytes),
    /// to be sent to the phone once.
    public func pair(id: String, name: String, platform: String, appVersion: String, now: Date) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<PairedDeviceStore.secretByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        return try pair(id: id, name: name, platform: platform, appVersion: appVersion, now: now, secret: secret)
    }

    /// Same as `pair(id:name:platform:appVersion:now:)` with a given secret (tests).
    func pair(id: String, name: String, platform: String, appVersion: String, now: Date, secret: Data) throws -> String {
        guard CompanionProtocol.isValidId(id) else { throw PairedDeviceStoreError.invalidId }
        guard secret.count == PairedDeviceStore.secretByteCount else { throw PairedDeviceStoreError.invalidSecret }
        lock.lock()
        do {
            defer { lock.unlock() }
            reload()
            let others = file.devices.filter { $0.id != id }
            guard others.count < PairedDeviceStore.maxDevices else { throw PairedDeviceStoreError.tooManyDevices }
            var device = PairedDevice()
            device.id = id
            device.name = PairedDeviceStore.cleanName(name)
            device.platform = PairedDeviceStore.cleanName(platform)
            device.appVersion = PairedDeviceStore.cleanName(appVersion)
            device.secretHash = PairedDeviceStore.hashSecret(secret)
            device.paired = now
            device.lastSeen = now
            let previous = file.devices
            file.devices = others + [device]
            guard StoreFiles.write(file, to: url) else {
                file.devices = previous
                throw PairedDeviceStoreError.notSaved
            }
            removed.remove(id)
            pending[id] = nil
        }
        ensureSyncKey(for: id)
        onChange?()
        return CompanionProtocol.encodeBase64Url(secret)
    }

    /// Approves the phone `id` and returns its new secret like `pair`, but keeps the phone in memory only:
    /// it is not paired, listed or written until its first request with that secret (`authenticateFirstUse`),
    /// so a phone that never got the secret is never stored. Throws as `pair` does, except `notSaved`.
    public func prepare(id: String, name: String, platform: String, appVersion: String, now: Date) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<PairedDeviceStore.secretByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        return try prepare(id: id, name: name, platform: platform, appVersion: appVersion, now: now, secret: secret)
    }

    /// Same as `prepare(id:name:platform:appVersion:now:)` with a given secret (tests).
    func prepare(id: String, name: String, platform: String, appVersion: String, now: Date, secret: Data) throws -> String {
        guard CompanionProtocol.isValidId(id) else { throw PairedDeviceStoreError.invalidId }
        guard secret.count == PairedDeviceStore.secretByteCount else { throw PairedDeviceStoreError.invalidSecret }
        lock.lock()
        reload()
        guard file.devices.filter({ $0.id != id }).count < PairedDeviceStore.maxDevices else {
            lock.unlock()
            throw PairedDeviceStoreError.tooManyDevices
        }
        var device = PairedDevice()
        device.id = id
        device.name = PairedDeviceStore.cleanName(name)
        device.platform = PairedDeviceStore.cleanName(platform)
        device.appVersion = PairedDeviceStore.cleanName(appVersion)
        device.secretHash = PairedDeviceStore.hashSecret(secret)
        device.paired = now
        device.lastSeen = now
        pending[id] = (device, now)
        lock.unlock()
        ensureSyncKey(for: id)
        return CompanionProtocol.encodeBase64Url(secret)
    }

    /// Drops the approved phone `id` that never came back (its reply was not delivered).
    public func discard(_ id: String) {
        lock.lock()
        let dropped = pending.removeValue(forKey: id) != nil
        lock.unlock()
        if dropped { releaseSyncKeys([id]) }
    }

    /// Drops every approved phone that has not come back (pairing ended).
    public func clearPending() {
        lock.lock()
        let ids = Array(pending.keys)
        pending = [:]
        lock.unlock()
        releaseSyncKeys(ids)
    }

    /// Whether an approved phone still waits for its first request (the desktop keeps listening for it).
    public func hasPending(now: Date) -> Bool {
        lock.lock()
        let expired = dropExpired(now: now)
        let any = !pending.isEmpty
        lock.unlock()
        releaseSyncKeys(expired)
        return any
    }

    /// Makes the phone's sync key when it has none. A key that cannot be kept is not handed out: the phone
    /// pairs without the sync folder.
    private func ensureSyncKey(for id: String) {
        guard let store = syncKeyStore, (try? store.load(for: id))?.count != SyncPackage.keyByteCount else { return }
        var generator = SystemRandomNumberGenerator()
        let key = Data((0..<SyncPackage.keyByteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
        if (try? store.save(key, for: id)) == nil { try? store.delete(for: id) }
    }

    /// Deletes the sync keys of dropped approvals, unless the phone is paired from before.
    private func releaseSyncKeys(_ ids: [String]) {
        guard let store = syncKeyStore, !ids.isEmpty else { return }
        lock.lock()
        reload()
        let stale = ids.filter { id in pending[id] == nil && !file.devices.contains { $0.id == id } }
        lock.unlock()
        for id in stale { try? store.delete(for: id) }
    }

    /// Drops the approvals whose time is up (with the lock held); returns their ids.
    private func dropExpired(now: Date) -> [String] {
        let ids = pending.filter { now.timeIntervalSince($0.value.since) >= PairedDeviceStore.pendingLifetime || now < $0.value.since }.map { $0.key }
        for id in ids { pending[id] = nil }
        return ids
    }

    /// The sync key of the paired phone `id` (32 bytes, sent to it at pairing and opening what it puts in
    /// the sync folder); nil when it has none. Throws the store's error when it cannot be read now (a
    /// locked keychain).
    public func syncKey(for id: String) throws -> Data? {
        guard let store = syncKeyStore, CompanionProtocol.isValidId(id) else { return nil }
        lock.lock()
        reload()
        let paired = pending[id] != nil || (!removed.contains(id) && file.devices.contains { $0.id == id })
        lock.unlock()
        guard paired, let key = try store.load(for: id), key.count == SyncPackage.keyByteCount else { return nil }
        return key
    }

    /// Whether the paired phone `id` has a sync key that can be read now (one paired before the sync
    /// folder has none).
    public func hasSyncKey(_ id: String) -> Bool {
        (try? syncKey(for: id)) != nil
    }

    /// The paired phone `id` when `secret` is its secret (compared in constant time); nil otherwise.
    /// Records when it was last seen.
    public func authenticate(id: String?, secret: String?, now: Date) -> PairedDevice? {
        authenticateFirstUse(id: id, secret: secret, now: now)?.device
    }

    /// Same, and says whether this was the first request of a phone approved with `prepare`, which pairs
    /// it for good; nil when that cannot be saved.
    public func authenticateFirstUse(id: String?, secret: String?, now: Date) -> (device: PairedDevice, firstUse: Bool)? {
        guard let id = id, CompanionProtocol.isValidId(id),
              let bytes = CompanionProtocol.decodeBase64Url(secret), bytes.count == PairedDeviceStore.secretByteCount
        else { return nil }
        let presented = PairedDeviceStore.hashSecret(bytes)
        lock.lock()
        reload()
        if !removed.contains(id), let index = file.devices.firstIndex(where: { $0.id == id }),
           PairedDeviceStore.matches(file.devices[index].secretHash, presented) {
            defer { lock.unlock() }
            if let seen = file.devices[index].lastSeen, now.timeIntervalSince(seen) < PairedDeviceStore.lastSeenResolution, now >= seen {
                return (file.devices[index], false)
            }
            file.devices[index].lastSeen = now
            StoreFiles.write(file, to: url)
            return (file.devices[index], false)
        }
        var expired = dropExpired(now: now)
        let committed = commitPending(id: id, presented: presented, now: now, dropped: &expired)
        lock.unlock()
        releaseSyncKeys(expired)
        guard let device = committed else { return nil }
        onChange?()
        return (device, true)
    }

    /// Stores the approved phone `id` when `presented` is its secret's hash (with the lock held).
    private func commitPending(id: String, presented: String, now: Date, dropped: inout [String]) -> PairedDevice? {
        guard var device = pending[id]?.device, PairedDeviceStore.matches(device.secretHash, presented) else { return nil }
        let others = file.devices.filter { $0.id != id }
        guard others.count < PairedDeviceStore.maxDevices else {
            pending[id] = nil
            dropped.append(id)
            return nil
        }
        device.paired = now
        device.lastSeen = now
        let previous = file.devices
        file.devices = others + [device]
        guard StoreFiles.write(file, to: url) else {
            file.devices = previous
            return nil
        }
        pending[id] = nil
        removed.remove(id)
        return device
    }

    private static func matches(_ stored: String, _ presented: String) -> Bool {
        guard stored.utf8.count == 64, stored.utf8.count == presented.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(stored.utf8, presented.utf8) {
            difference |= a ^ b
        }
        return difference == 0
    }

    /// Unpairs the phone `id`; it is refused from now on. False when it was not paired.
    @discardableResult
    public func remove(_ id: String) -> Bool {
        lock.lock()
        reload()
        removed.insert(id)
        pending[id] = nil
        let before = file.devices.count
        file.devices.removeAll { $0.id == id }
        let wasPaired = file.devices.count != before
        if wasPaired { StoreFiles.write(file, to: url) }
        lock.unlock()
        try? syncKeyStore?.delete(for: id)
        if wasPaired { onChange?() }
        return wasPaired
    }

    /// Unpairs every phone; returns how many were paired.
    @discardableResult
    public func removeAll() -> Int {
        lock.lock()
        reload()
        let count = file.devices.count
        let ids = file.devices.map(\.id)
        for id in ids { removed.insert(id) }
        let waiting = Array(pending.keys)
        pending = [:]
        file.devices = []
        StoreFiles.write(file, to: url)
        lock.unlock()
        for id in ids + waiting { try? syncKeyStore?.delete(for: id) }
        if count > 0 { onChange?() }
        return count
    }

    /// SHA-256 of a device secret's bytes, lowercase hex.
    public static func hashSecret(_ secret: Data) -> String {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// A name as kept: control characters removed, trimmed, cut to `PairRequest.maxNameBytes` UTF-8 bytes.
    public static func cleanName(_ name: String?) -> String {
        var text = String.UnicodeScalarView()
        var bytes = 0
        for scalar in (name ?? "").unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { continue }
            let length = scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
            if bytes + length > PairRequest.maxNameBytes { break }
            bytes += length
            text.append(scalar)
        }
        return String(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-reads the file (with the lock held); an unreadable one keeps what was loaded.
    private func reload() {
        guard var loaded = PairedDeviceStore.load(url) else { return }
        if !CompanionProtocol.isValidId(loaded.desktopId) && CompanionProtocol.isValidId(file.desktopId) {
            loaded.desktopId = file.desktopId
        }
        file = loaded
    }

    /// The file as read under the settings-file rules; nil when there is none or it could not be read.
    private static func load(_ url: URL) -> PairedDevicesFile? {
        switch StoreFiles.read(PairedDevicesFile.self, from: url) {
        case .loaded(let loaded):
            return loaded
        case .missing:
            return nil
        case .corrupt(let error):
            StoreFiles.keepUnreadable(url, error: error)
            return nil
        case .inaccessible(let error):
            StoreFiles.leaveInaccessible(url, error: error)
            return nil
        }
    }
}
