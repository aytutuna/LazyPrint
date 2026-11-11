import Foundation

// Twin of windows/LazyPrint.Core/Companion/CompanionInbox.cs: where uploads from paired phones
// land on the desktop, with the same checks, the same received.json per phone, the same idempotence
// by package id and the same batches.

/// A package a paired phone sent, checked and waiting in the inbox. `url` is the package file.
public struct ReceivedPackage: Equatable, Sendable {
    public var deviceId: String
    public var packageId: String
    public var url: URL
    public var info: PrintPackageInfo
    public var received: Date

    public init(deviceId: String, packageId: String, url: URL, info: PrintPackageInfo, received: Date) {
        self.deviceId = deviceId
        self.packageId = packageId
        self.url = url
        self.info = info
        self.received = received
    }
}

/// A package received before (an entry of received.json).
public struct ReceivedEntry: Codable, Equatable, Sendable {
    public var packageId = ""
    public var received: Date?

    enum CodingKeys: String, CodingKey {
        case packageId, received
    }

    public init() {}
}

extension ReceivedEntry {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        packageId = c.decodeLenient(forKey: .packageId, default: packageId)
        received = c.decodeLenient(forKey: .received, default: received)
    }
}

/// The contents of a phone's received.json.
public struct ReceivedLog: Codable, Equatable, Sendable {
    public var packages: [ReceivedEntry] = []

    enum CodingKeys: String, CodingKey {
        case packages
    }

    public init() {}
}

extension ReceivedLog {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        packages = c.decodeLenient(forKey: .packages, default: packages)
    }
}

/// The files sent together, as far as they have arrived. A batch is whole when all `count` files are
/// in, or `CompanionInbox.batchGrace` after the last one arrived, so a phone that lost the link does
/// not hold back what got through.
public struct PhoneBatch: Equatable, Sendable {
    public var id: String
    public var from: String
    /// How many files the phone said the batch has.
    public var count: Int
    /// How many are in the inbox.
    public var arrived: Int
    public var lastReceived: Date

    public init(id: String, from: String, count: Int, arrived: Int, lastReceived: Date) {
        self.id = id
        self.from = from
        self.count = count
        self.arrived = arrived
        self.lastReceived = lastReceived
    }

    public func isWhole(now: Date) -> Bool {
        arrived >= count || now.timeIntervalSince(lastReceived) >= CompanionInbox.batchGrace
    }
}

/// Why an upload was not received (besides a refused package, `PrintPackageError`, and the file
/// system's errors).
public enum CompanionInboxError: Error, Equatable, Sendable {
    /// The phone's or the package's id is not valid (`CompanionProtocol.isValidId`).
    case invalidId
    /// The upload ended before all of it arrived.
    case endedEarly
    /// The list of received files could not be saved.
    case notSaved
    /// The phone has as many files waiting as it may (`CompanionInbox.maxWaitingFiles`, `maxWaitingBytes`); its
    /// uploads are refused until some are dealt with.
    case full
}

/// Where uploads from paired phones land (one folder per phone under the inbox folder). A body is
/// streamed to "<id>.part", must be exactly as long as announced, is read as a `PrintPackage` (header
/// and first bytes checked) and only then renamed to "<id>.lppkg" and logged in received.json, so a
/// package is either received whole and valid or not at all. Uploads are idempotent by package id: one
/// received before is answered from the log (the last `maxLoggedPackages` per phone), and the same id
/// cannot be received twice at once. Ids are checked by `CompanionProtocol.isValidId`, so they are safe
/// file names. A phone may have `maxWaitingFiles` files and `maxWaitingBytes` bytes waiting at most. `take`
/// moves a batch to "<batch>/<name>" under the inbox folder with the files' names, made safe; `discard` deletes a
/// batch. Anything is deleted `keepDays` days after it arrived. Safe to use from any thread.
public final class CompanionInbox: @unchecked Sendable {
    public static let maxLoggedPackages = 1000
    public static let logFileName = "received.json"
    public static let keepDays = 7
    public static let maxWaitingFiles = 100
    public static let maxWaitingBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let minFreeBytes: Int64 = 1024 * 1024 * 1024
    public static let fullMessage = "This computer has too many files from your phone waiting. Add or dismiss them on the computer first."
    public static let batchGrace: TimeInterval = 30

    // The longest name a taken file gets, so that " (2)" and so on still fit in 255 bytes.
    private static let maxTakenNameBytes = 240

    private static let extensions: [String: [String]] = [
        "application/pdf": ["pdf"],
        "image/jpeg": ["jpg", "jpeg"],
        "image/png": ["png"],
        "image/heic": ["heic", "heif"],
        "image/tiff": ["tif", "tiff"],
    ]

    // Windows opens these names as devices, with an extension or without.
    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        for suffix in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{B9}", "\u{B2}", "\u{B3}"] {
            names.insert("COM" + suffix)
            names.insert("LPT" + suffix)
        }
        return names
    }()

    public let directory: URL
    private let lock = NSLock()
    private var inProgress: Set<String> = []
    // What uploads under way have been promised, per phone, so parallel ones count against the quota together.
    private var reserved: [String: (files: Int, bytes: Int64)] = [:]

    /// The name a paired phone goes by on this computer, nil when unknown. A batch shows it instead of the phone's own
    /// word. Set once, before the inbox is used.
    public var nameOf: @Sendable (String) -> String? = { _ in nil }

    /// The free bytes on the volume that holds the given folder; nil when unknown. Set once, before the inbox is used.
    public var freeSpace: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default inbox: Application Support/Lazy Print/Companion/Inbox.
    public static var defaultDirectory: URL {
        StoreFiles.defaultDirectory.appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// The package `packageId` received from `deviceId` before; nil when it was not (or an id is not valid).
    public func find(deviceId: String, packageId: String) -> ReceivedEntry? {
        guard CompanionInbox.valid(deviceId, packageId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return log(deviceId).packages.first { $0.packageId == packageId }
    }

    /// Claims the package id for one upload; false while another upload of it runs (or an id is not valid).
    public func tryBegin(deviceId: String, packageId: String) -> Bool {
        guard CompanionInbox.valid(deviceId, packageId) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return inProgress.insert(deviceId + "/" + packageId).inserted
    }

    /// Ends the claim of `tryBegin`.
    public func end(deviceId: String, packageId: String) {
        lock.lock()
        inProgress.remove(deviceId + "/" + packageId)
        lock.unlock()
    }

    /// Receives the package: copies exactly `length` bytes of `body`, checks it and logs it. Throws
    /// `PrintPackageError` for a package that is refused, `CompanionInboxError.endedEarly` when the
    /// body ends early, `.full` (before any of the body is read) when the phone has too much waiting,
    /// `.notSaved` or the file system's error when it cannot be stored, and the body's own error when
    /// the connection breaks; nothing is kept then.
    public func receive(deviceId: String, packageId: String, body: CompanionRequestBody, length: Int64,
                        now: Date) async throws -> ReceivedPackage {
        guard CompanionInbox.valid(deviceId, packageId) else { throw CompanionInboxError.invalidId }
        let folder = deviceFolder(deviceId)
        try reserve(deviceId, folder: folder, length: length)
        defer { release(deviceId, length: length) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(packageId + ".part")
        let final = folder.appendingPathComponent(packageId + "." + PrintPackage.fileExtension)
        defer { CompanionInbox.tryDelete(part) }
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: part.path])
        }
        let file = try FileHandle(forWritingTo: part)
        do {
            defer { try? file.close() }
            var remaining = length
            while remaining > 0 {
                let chunk = try await body.read(maxLength: Int(min(81920, remaining)))
                if chunk.isEmpty { throw CompanionInboxError.endedEarly }
                try file.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        let info = try PrintPackage.read(contentsOf: part)
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: part, to: final)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: final.path)
        guard record(deviceId: deviceId, packageId: packageId, now: now) else {
            try? FileManager.default.removeItem(at: final)
            throw CompanionInboxError.notSaved
        }
        return ReceivedPackage(deviceId: deviceId, packageId: packageId, url: final, info: info, received: now)
    }

    /// The batches in the inbox, oldest first, whole or not (`PhoneBatch.isWhole`). Files older than
    /// `keepDays` days are deleted first.
    public func batches(now: Date) -> [PhoneBatch] {
        lock.lock()
        defer { lock.unlock() }
        purge(now: now)
        let stored = self.stored()
        var batches: [PhoneBatch] = []
        for id in Set(stored.map { $0.info.batch }) {
            let group = stored.filter { $0.info.batch == id }
            let paired = nameOf(group[0].deviceId) ?? ""
            let from = paired.isEmpty ? PairedDeviceStore.cleanName(group[0].info.from) : paired
            batches.append(PhoneBatch(id: id, from: from, count: group.map { $0.info.count }.max() ?? 0,
                                      arrived: group.count, lastReceived: group.map { $0.received }.max() ?? Date.distantPast))
        }
        return batches.sorted { $0.lastReceived < $1.lastReceived }
    }

    /// Moves the files of `batch` to "<batch>/<name>" under the inbox folder and returns their paths in the order the
    /// phone sent them, stamped `now` so they are kept `keepDays` days from now on. The name is the sender's word, so it
    /// is made safe: characters Windows does not allow become "_", trailing dots and spaces go, a device name like NUL
    /// gets "_" in front, the extension is the one the content type says (appended when the name has another) and the
    /// stem is cut to fit. A name already taken in the folder gets " (2)" and so on. A file that cannot be moved stays
    /// in the inbox; the others are still taken.
    public func take(batch: String, now: Date) -> [URL] {
        guard CompanionProtocol.isValidId(batch) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(batch, isDirectory: true)
        let packages = stored().filter { $0.info.batch == batch }
            .sorted { ($0.info.index, $0.received) < ($1.info.index, $1.received) }
        var taken: [URL] = []
        for package in packages {
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  let target = copy(package, to: folder, now: now) else { continue }
            taken.append(target)
        }
        return taken
    }

    /// Deletes the files of `batch` that wait in the inbox, without copying them.
    public func discard(batch: String) {
        guard CompanionProtocol.isValidId(batch) else { return }
        lock.lock()
        defer { lock.unlock() }
        for package in stored() where package.info.batch == batch { CompanionInbox.tryDelete(package.url) }
    }

    /// Deletes everything received from `deviceId` (the phone was removed).
    public func removeDevice(_ deviceId: String) {
        guard CompanionProtocol.isValidId(deviceId) else { return }
        try? FileManager.default.removeItem(at: deviceFolder(deviceId))
    }

    /// The file of `package` (without the header) in `folder` under its own name; the package file is deleted.
    private func copy(_ package: ReceivedPackage, to folder: URL, now: Date) -> URL? {
        let target = CompanionInbox.uniqueName(in: folder, package.info)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { return nil }
        guard let source = try? FileHandle(forReadingFrom: package.url),
              let destination = try? FileHandle(forWritingTo: target) else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        defer {
            try? source.close()
            try? destination.close()
        }
        do {
            try source.seek(toOffset: UInt64(package.info.dataOffset))
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try destination.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        CompanionInbox.tryDelete(package.url)
        return target
    }

    /// The packages waiting in the phones' folders, each header read again; a file that no longer reads is deleted.
    private func stored() -> [ReceivedPackage] {
        var stored: [ReceivedPackage] = []
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        for folder in folders {
            let deviceId = folder.lastPathComponent
            guard CompanionProtocol.isValidId(deviceId),
                  let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.pathExtension == PrintPackage.fileExtension {
                let packageId = file.deletingPathExtension().lastPathComponent
                guard CompanionProtocol.isValidId(packageId) else { continue }
                guard let info = try? PrintPackage.read(contentsOf: file) else {
                    CompanionInbox.tryDelete(file)
                    continue
                }
                stored.append(ReceivedPackage(deviceId: deviceId, packageId: packageId, url: file, info: info,
                                              received: CompanionInbox.modified(file)))
            }
        }
        return stored
    }

    private func purge(now: Date) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let oldest = now.addingTimeInterval(-Double(CompanionInbox.keepDays) * 86400)
        for folder in folders {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent != CompanionInbox.logFileName && CompanionInbox.modified(file) <= oldest {
                CompanionInbox.tryDelete(file)
            }
            if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? manager.removeItem(at: folder)
            }
        }
    }

    /// Logs the package in the phone's received.json; false when that could not be saved.
    private func record(deviceId: String, packageId: String, now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var log = self.log(deviceId)
        log.packages.removeAll { $0.packageId == packageId }
        var entry = ReceivedEntry()
        entry.packageId = packageId
        entry.received = now
        log.packages.append(entry)
        if log.packages.count > CompanionInbox.maxLoggedPackages {
            log.packages.removeFirst(log.packages.count - CompanionInbox.maxLoggedPackages)
        }
        return StoreFiles.write(log, to: logURL(deviceId))
    }

    private func deviceFolder(_ deviceId: String) -> URL {
        directory.appendingPathComponent(deviceId, isDirectory: true)
    }

    private func logURL(_ deviceId: String) -> URL {
        deviceFolder(deviceId).appendingPathComponent(CompanionInbox.logFileName)
    }

    /// The phone's received.json (with the lock held).
    private func log(_ deviceId: String) -> ReceivedLog {
        StoreFiles.load(ReceivedLog.self, from: logURL(deviceId)) ?? ReceivedLog()
    }

    private static func modified(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? Date.distantPast
    }

    private static func fileName(_ info: PrintPackageInfo) -> (stem: String, ext: String) {
        let invalid: Set<Unicode.Scalar> = ["\"", "<", ">", "|", ":", "*", "?", "\\", "/"]
        var name = String.UnicodeScalarView()
        for scalar in info.name.unicodeScalars { name.append(invalid.contains(scalar) || scalar.value < 0x20 ? "_" : scalar) }
        let allowed = extensions[info.contentType] ?? ["pdf"]
        var stem = String(name)
        var ext = allowed[0]
        if let dot = name.lastIndex(of: "."), allowed.contains(String(name[name.index(after: dot)...]).lowercased()) {
            ext = String(name[name.index(after: dot)...])
            stem = String(name[..<dot])
        }
        stem = trimEnd(cutToBytes(trimEnd(stem), maxTakenNameBytes - ext.utf8.count - 1))
        if stem.isEmpty { stem = "file" }
        let first = stem.unicodeScalars.firstIndex(of: ".").map { String(stem.unicodeScalars[..<$0]) } ?? stem
        if reservedNames.contains(trimSpaces(first).uppercased()) { stem = "_" + stem }
        return (stem, ext)
    }

    private static func trimEnd(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last == "." || last == " " { scalars.removeLast() }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    private static func trimSpaces(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last == " " { scalars.removeLast() }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars)
        return String(result)
    }

    private static func cutToBytes(_ text: String, _ limit: Int) -> String {
        var cut = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            let length = String(scalar).utf8.count
            if bytes + length > limit { break }
            bytes += length
            cut.append(scalar)
        }
        return String(cut)
    }

    private static func uniqueName(in folder: URL, _ info: PrintPackageInfo) -> URL {
        let (stem, ext) = fileName(info)
        var candidate = folder.appendingPathComponent(stem + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Counts an upload of `length` bytes against the phone's quota until `release`. Throws `CompanionInboxError.full`
    /// when it would pass what the phone may have waiting, or leave less than `minFreeBytes` on the disk.
    private func reserve(_ deviceId: String, folder: URL, length: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        let held = reserved[deviceId] ?? (files: 0, bytes: 0)
        var count = held.files
        var bytes = held.bytes + length
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files where file.pathExtension == PrintPackage.fileExtension {
                count += 1
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        if count >= CompanionInbox.maxWaitingFiles || bytes > CompanionInbox.maxWaitingBytes { throw CompanionInboxError.full }
        if let free = freeSpace(directory), free - length < CompanionInbox.minFreeBytes { throw CompanionInboxError.full }
        reserved[deviceId] = (files: held.files + 1, bytes: held.bytes + length)
    }

    private func release(_ deviceId: String, length: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let held = reserved[deviceId] else { return }
        reserved[deviceId] = held.files <= 1 ? nil : (files: held.files - 1, bytes: held.bytes - length)
    }

    private static func valid(_ deviceId: String, _ packageId: String) -> Bool {
        CompanionProtocol.isValidId(deviceId) && CompanionProtocol.isValidId(packageId)
    }

    private static func tryDelete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
