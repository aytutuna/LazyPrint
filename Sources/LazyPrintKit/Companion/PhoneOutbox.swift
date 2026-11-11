import Foundation

// What the phone has still to send to its desktop. Swift only: Windows has no phone side.

/// A file waiting to be sent, as a print package (an entry of outbox.json).
public struct PhoneOutboxItem: Codable, Equatable, Sendable {
    /// The package id the desktop receives it under (`PUT /v1/inbox/{id}`), so sending it again is
    /// harmless.
    public var id = ""
    /// The package's file in the outbox folder ("<id>.lppkg").
    public var fileName = ""
    /// The file's own name ("Report.pdf"), for what is said about it.
    public var name = ""
    /// The desktop it was sent to (`PairedDesktop.id`); no other desktop gets it.
    public var desktopId = ""
    public var created: Date?
    /// How often sending it failed.
    public var attempts = 0
    /// Why it failed last; "" when it has not.
    public var lastError = ""
    /// It goes through the cloud sync folder: putting it there failed once, so the next round tries
    /// the folder first, and the network only when no folder can be used.
    public var viaSyncFolder = false
    /// It is in the cloud sync folder: it stays until its file leaves the folder (the desktop took it) or
    /// it is sent over the network, so a desktop that can no longer open the file still gets it.
    public var inSyncFolder = false
    /// The desktop refused it (too large, not readable): it never goes into the cloud sync folder.
    public var refused = false

    enum CodingKeys: String, CodingKey {
        case id, fileName, name, desktopId, created, attempts, lastError, viaSyncFolder, inSyncFolder, refused
    }

    public init() {}
}

extension PhoneOutboxItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = c.decodeLenient(forKey: .id, default: id)
        fileName = c.decodeLenient(forKey: .fileName, default: fileName)
        name = c.decodeLenient(forKey: .name, default: name)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        created = c.decodeLenient(forKey: .created, default: created)
        attempts = c.decodeLenient(forKey: .attempts, default: attempts)
        lastError = c.decodeLenient(forKey: .lastError, default: lastError)
        viaSyncFolder = c.decodeLenient(forKey: .viaSyncFolder, default: viaSyncFolder)
        inSyncFolder = c.decodeLenient(forKey: .inSyncFolder, default: inSyncFolder)
        refused = c.decodeLenient(forKey: .refused, default: refused)
    }
}

/// The contents of outbox.json.
public struct PhoneOutboxFile: Codable, Equatable, Sendable {
    public var items: [PhoneOutboxItem] = []

    enum CodingKeys: String, CodingKey {
        case items
    }

    public init() {}
}

extension PhoneOutboxFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        items = c.decodeLenient(forKey: .items, default: items)
    }
}

/// Why a file could not be queued for sending.
public enum PhoneOutboxError: Error, Equatable, LocalizedError, Sendable {
    /// `PhoneOutbox.maxItems` files wait already.
    case full

    public var errorDescription: String? { CompanionText.outboxFullMessage }
}

/// The files waiting to be sent to the paired desktop, oldest first: a folder of `.lppkg` files
/// and outbox.json listing them (Global rule 5). A file stays until the desktop has it (201, or 200 for
/// one it had already) or the user removes it, across launches; entries whose file went are dropped
/// when the folder is opened. Safe to use from any thread.
public final class PhoneOutbox: @unchecked Sendable {
    public static let fileName = "outbox.json"
    public static let maxItems = 50

    public let directory: URL
    private let url: URL
    private let lock = NSLock()
    private var file: PhoneOutboxFile

    public init(directory: URL) {
        self.directory = directory
        url = directory.appendingPathComponent(PhoneOutbox.fileName)
        file = StoreFiles.load(PhoneOutboxFile.self, from: url) ?? PhoneOutboxFile()
        let before = file.items.count
        file.items.removeAll {
            !CompanionProtocol.isValidId($0.id) || $0.fileName.isEmpty
                || !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
        }
        if file.items.count != before { StoreFiles.write(file, to: url) }
    }

    public var items: [PhoneOutboxItem] {
        lock.lock()
        defer { lock.unlock() }
        return file.items
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return file.items.count
    }

    public func fileURL(of item: PhoneOutboxItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    /// Packs `file` as `name` (file number `index` of `count` in `batch`, from the phone called `from`) into
    /// the outbox folder, for the desktop `desktopId`, under a new package id. Throws `PhoneOutboxError.full`,
    /// `PrintPackageError` for a file that is not what its type says, or the file system's error.
    @discardableResult
    public func enqueue(file source: URL, name: String, contentType: String, batch: String, index: Int, count: Int,
                        from: String, desktopId: String, now: Date = Date()) throws -> PhoneOutboxItem {
        lock.lock()
        defer { lock.unlock() }
        guard file.items.count < PhoneOutbox.maxItems else { throw PhoneOutboxError.full }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var item = PhoneOutboxItem()
        item.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        item.fileName = item.id + "." + PrintPackage.fileExtension
        item.name = name
        item.desktopId = desktopId
        item.created = now
        let target = directory.appendingPathComponent(item.fileName)
        do {
            try PrintPackage.write(file: source, to: target, name: name, contentType: contentType, batch: batch, index: index,
                                   count: count, from: from)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        file.items.append(item)
        StoreFiles.write(file, to: url)
        return item
    }

    /// The oldest waiting file not in `excluding` (those tried already in this round).
    public func next(excluding: Set<String> = []) -> PhoneOutboxItem? {
        lock.lock()
        defer { lock.unlock() }
        return file.items.first { !excluding.contains($0.id) }
    }

    /// The desktop has it: its file and entry go.
    public func markSent(_ id: String) {
        remove(id)
    }

    /// Counts a failed attempt and keeps why.
    public func markFailed(_ id: String, error: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return }
        file.items[index].attempts += 1
        file.items[index].lastError = error
        StoreFiles.write(file, to: url)
    }

    /// Sends it through the cloud sync folder from now on (`PhoneOutboxItem.viaSyncFolder`).
    public func markViaSyncFolder(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }), !file.items[index].viaSyncFolder else { return }
        file.items[index].viaSyncFolder = true
        StoreFiles.write(file, to: url)
    }

    /// Notes whether it is in the cloud sync folder (`PhoneOutboxItem.inSyncFolder`).
    public func markInSyncFolder(_ id: String, _ inSyncFolder: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }), file.items[index].inSyncFolder != inSyncFolder
        else { return }
        file.items[index].inSyncFolder = inSyncFolder
        StoreFiles.write(file, to: url)
    }

    /// The desktop refused it (`PhoneOutboxItem.refused`).
    public func markRefused(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }), !file.items[index].refused else { return }
        file.items[index].refused = true
        StoreFiles.write(file, to: url)
    }

    /// Takes a file out unsent (the user removed it), with its file.
    public func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.items[index].fileName))
        file.items.remove(at: index)
        StoreFiles.write(file, to: url)
    }
}
