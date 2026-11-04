import Foundation

// Twin of windows/LazyPrint.Core/Companion/PrintPackage.cs: the same bytes for the same file, the
// same refusals. The golden file Tests/Fixtures/Companion/print-package.lppkg is written by the C# tests
// and checked here.

/// A print package that cannot be made or read; the message is for the phone.
public struct PrintPackageError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? { message }
}

/// What a package's header says about the file in it.
public struct PrintPackageInfo: Equatable, Sendable {
    /// The file's name, with no path.
    public var name: String
    /// One of `PrintPackage.contentTypes`.
    public var contentType: String
    /// The files sent together share it (`CompanionProtocol.isValidId`).
    public var batch: String
    /// From 0, the file's place in the batch.
    public var index: Int
    /// How many files the batch has.
    public var count: Int
    /// The phone's name, for the bar on the desktop.
    public var from: String
    /// Where the file's bytes start in the package.
    public var dataOffset = 0

    public init(name: String, contentType: String, batch: String, index: Int, count: Int, from: String, dataOffset: Int = 0) {
        self.name = name
        self.contentType = contentType
        self.batch = batch
        self.index = index
        self.count = count
        self.from = from
        self.dataOffset = dataOffset
    }
}

/// One file for the computer to print: eight bytes of magic, the header's length as four bytes little
/// endian, the header (UTF-8 JSON) and then the file's bytes to the end. The desktop opens what arrives,
/// so a package is accepted by what its first bytes are, not by what the sender says.
public enum PrintPackage {
    public static let fileExtension = "lppkg"

    /// The largest file in a package.
    public static let maxFileBytes = 512 * 1024 * 1024
    public static let maxHeaderBytes = 65536
    public static let maxNameBytes = 255

    private static let magic: [UInt8] = Array("LPPKG01".utf8) + [0]
    private static let prefixBytes = 12
    private static let sniffBytes = 12

    /// The largest package: the largest file, its header and the prefix.
    public static let maxPackageBytes = maxFileBytes + maxHeaderBytes + prefixBytes

    public static let contentTypes = ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/tiff"]

    public static let notPackageMessage = "This file is not a Lazy Print package."
    public static let damagedMessage = "This package is damaged."
    public static let tooLargeMessage = "This package is too large."
    public static let nameMessage = "The file's name in this package is not valid."
    public static let contentMessage = "The file in this package is not the kind it says it is."

    public static func make(name: String, contentType: String, batch: String, index: Int, count: Int, from: String,
                            bytes: Data) throws -> Data {
        let info = PrintPackageInfo(name: name, contentType: contentType, batch: batch, index: index, count: count, from: from)
        try check(info)
        guard bytes.count <= maxFileBytes else { throw PrintPackageError(message: tooLargeMessage) }
        guard matches(contentType, [UInt8](bytes.prefix(sniffBytes))) else { throw PrintPackageError(message: contentMessage) }
        let header = Data(headerJSON(info).utf8)
        guard header.count <= maxHeaderBytes else { throw PrintPackageError(message: damagedMessage) }
        var package = Data(magic)
        let length = UInt32(header.count)
        package.append(contentsOf: [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF),
                                    UInt8((length >> 24) & 0xFF)])
        package.append(header)
        package.append(bytes)
        return package
    }

    /// Checks the magic, the header and the first bytes of the file.
    public static func read(_ package: Data) throws -> PrintPackageInfo {
        let bytes = [UInt8](package)
        return try read(size: bytes.count) { offset, count in
            Array(bytes[min(offset, bytes.count)..<min(offset + count, bytes.count)])
        }
    }

    public static func read(contentsOf url: URL) throws -> PrintPackageInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        return try read(size: size) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }
    }

    private static func read(size: Int, chunk: (Int, Int) throws -> [UInt8]) throws -> PrintPackageInfo {
        guard size <= maxPackageBytes else { throw PrintPackageError(message: tooLargeMessage) }
        let prefix = try chunk(0, prefixBytes)
        guard prefix.count == prefixBytes, Array(prefix[0..<magic.count]) == magic else {
            throw PrintPackageError(message: notPackageMessage)
        }
        let length = Int(prefix[8]) | Int(prefix[9]) << 8 | Int(prefix[10]) << 16 | Int(prefix[11]) << 24
        guard length >= 1, length <= maxHeaderBytes else { throw PrintPackageError(message: damagedMessage) }
        let header = try chunk(prefixBytes, length)
        guard header.count == length, let dto = CompanionProtocol.decode(HeaderDTO.self, Data(header)) else {
            throw PrintPackageError(message: damagedMessage)
        }
        let info = PrintPackageInfo(name: dto.name, contentType: dto.contentType, batch: dto.batch, index: Int(dto.index),
                                    count: Int(dto.count), from: dto.from, dataOffset: prefixBytes + length)
        try check(info)
        let start = try chunk(info.dataOffset, sniffBytes)
        guard matches(info.contentType, start) else { throw PrintPackageError(message: contentMessage) }
        return info
    }

    /// The content type the first bytes of `url` say it is; nil for a file the desktop would not take. Swift
    /// only: the phone sends, Windows only receives.
    static func contentType(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let start = [UInt8]((try? handle.read(upToCount: sniffBytes)) ?? Data())
        return contentTypes.first { matches($0, start) }
    }

    /// The header's JSON, the keys in the order the golden file has them.
    static func headerJSON(_ info: PrintPackageInfo) -> String {
        "{\"name\":\(CompanionProtocol.quote(info.name)),\"contentType\":\(CompanionProtocol.quote(info.contentType))"
            + ",\"batch\":\(CompanionProtocol.quote(info.batch)),\"index\":\(CompanionProtocol.integer(info.index))"
            + ",\"count\":\(CompanionProtocol.integer(info.count)),\"from\":\(CompanionProtocol.quote(info.from))}"
    }

    private static func check(_ info: PrintPackageInfo) throws {
        guard contentTypes.contains(info.contentType), CompanionProtocol.isValidId(info.batch),
              info.count >= 1, info.index >= 0, info.index < info.count else {
            throw PrintPackageError(message: damagedMessage)
        }
        let name = info.name
        // By scalars: a slash followed by a combining mark is one Character, which is not "/".
        if name.isEmpty || name == "." || name == ".." || name.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" })
            || name.utf8.count > maxNameBytes {
            throw PrintPackageError(message: nameMessage)
        }
    }

    private static func matches(_ contentType: String, _ start: [UInt8]) -> Bool {
        switch contentType {
        case "application/pdf": return start.starts(with: Array("%PDF-".utf8))
        case "image/jpeg": return start.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png": return start.starts(with: [0x89, 0x50, 0x4E, 0x47])
        case "image/heic": return start.count >= 8 && Array(start[4..<8]) == Array("ftyp".utf8)
        case "image/tiff": return start.starts(with: [0x49, 0x49, 0x2A, 0x00]) || start.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        default: return false
        }
    }
}

private struct HeaderDTO: Decodable {
    var name = ""
    var contentType = ""
    var batch = ""
    var index: Int32 = 0
    var count: Int32 = 0
    var from = ""

    enum CodingKeys: String, CodingKey { case name, contentType, batch, index, count, from }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeLenient(forKey: .name, default: name)
        contentType = c.decodeLenient(forKey: .contentType, default: contentType)
        batch = c.decodeLenient(forKey: .batch, default: batch)
        index = c.decodeLenient(forKey: .index, default: index)
        count = c.decodeLenient(forKey: .count, default: count)
        from = c.decodeLenient(forKey: .from, default: from)
    }
}
