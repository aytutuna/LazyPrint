import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppCodec.cs: IPP messages as bytes (RFC 8010).

/// An IPP version. 2.0 is sent; 1.x and 2.x are read.
public struct IppVersion: Equatable, Sendable, CustomStringConvertible {
    public var major: UInt8
    public var minor: UInt8

    public static let v20 = IppVersion(major: 2, minor: 0)
    public static let v11 = IppVersion(major: 1, minor: 1)

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public var description: String { "\(major).\(minor)" }
}

/// Group delimiter and value tags (RFC 8010 §3.5.1, §3.5.2).
public enum IppTag {
    public static let operationAttributes: UInt8 = 0x01
    public static let jobAttributes: UInt8 = 0x02
    public static let endOfAttributes: UInt8 = 0x03
    public static let printerAttributes: UInt8 = 0x04
    public static let unsupportedAttributes: UInt8 = 0x05

    public static let unsupported: UInt8 = 0x10
    public static let unknown: UInt8 = 0x12
    public static let noValue: UInt8 = 0x13
    public static let integer: UInt8 = 0x21
    public static let boolean: UInt8 = 0x22
    public static let enumeration: UInt8 = 0x23
    public static let octetString: UInt8 = 0x30
    public static let dateTime: UInt8 = 0x31
    public static let resolution: UInt8 = 0x32
    public static let rangeOfInteger: UInt8 = 0x33
    public static let begCollection: UInt8 = 0x34
    public static let textWithLanguage: UInt8 = 0x35
    public static let nameWithLanguage: UInt8 = 0x36
    public static let endCollection: UInt8 = 0x37
    public static let text: UInt8 = 0x41
    public static let name: UInt8 = 0x42
    public static let keyword: UInt8 = 0x44
    public static let uri: UInt8 = 0x45
    public static let uriScheme: UInt8 = 0x46
    public static let charset: UInt8 = 0x47
    public static let naturalLanguage: UInt8 = 0x48
    public static let mimeMediaType: UInt8 = 0x49
    public static let memberAttrName: UInt8 = 0x4A
}

/// One value of an attribute. `dateTime` holds the 11 bytes of RFC 2579 DateAndTime as they came; `resolution`
/// units 3 are dots per inch, 4 dots per centimetre; `outOfBand` is 0x10 unsupported, 0x12 unknown or 0x13
/// no-value; `unknown` is a value tag this codec does not know, or a known one with a length it should not have.
public enum IppValue: Equatable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumValue(Int32)
    case octets(Data)
    case dateTime(Data)
    case resolution(x: Int32, y: Int32, units: UInt8)
    case range(Int32, Int32)
    case text(String)
    case name(String)
    case keyword(String)
    case uri(String)
    case uriScheme(String)
    case charset(String)
    case language(String)
    case mimeType(String)
    case collection([IppAttribute])
    case outOfBand(UInt8)
    case unknown(tag: UInt8, Data)
}

/// A named attribute with one or more values.
public struct IppAttribute: Equatable, Sendable {
    public var name: String
    public var values: [IppValue]

    public init(name: String, values: [IppValue]) {
        self.name = name
        self.values = values
    }

    public init(_ name: String, _ values: IppValue...) {
        self.name = name
        self.values = values
    }
}

/// The attributes after one delimiter tag: 0x01 operation, 0x02 job, 0x04 printer, 0x05 unsupported, any 0x00-0x0F kept.
public struct IppGroup: Equatable, Sendable {
    public var tag: UInt8
    public var attributes: [IppAttribute]

    public init(tag: UInt8, attributes: [IppAttribute]) {
        self.tag = tag
        self.attributes = attributes
    }
}

public enum IppOperation: UInt16, Sendable {
    case printJob = 0x0002
    case validateJob = 0x0004
    case cancelJob = 0x0008
    case getJobAttributes = 0x0009
    case getJobs = 0x000A
    case getPrinterAttributes = 0x000B
}

/// A request or a response; `code` is the operation id in a request, the status code in a response.
public struct IppMessage: Equatable, Sendable {
    public var version: IppVersion
    public var code: UInt16
    public var requestId: Int32
    public var groups: [IppGroup]

    public init(version: IppVersion, code: UInt16, requestId: Int32, groups: [IppGroup]) {
        self.version = version
        self.code = code
        self.requestId = requestId
        self.groups = groups
    }

    /// Successful-ok and the two other successes (codes below 0x0100).
    public var isSuccess: Bool { code < 0x0100 }

    /// The first attribute of that name outside the unsupported-attributes group.
    public subscript(_ name: String) -> IppAttribute? {
        for group in groups where group.tag != IppTag.unsupportedAttributes {
            if let attribute = group.attributes.first(where: { $0.name == name }) { return attribute }
        }
        return nil
    }

    public func encoded() -> Data {
        var out = [UInt8]()
        out.append(version.major)
        out.append(version.minor)
        Self.putUInt16(&out, Int(code))
        Self.putInt32(&out, requestId)
        for group in groups {
            out.append(group.tag)
            for attribute in group.attributes {
                for (i, value) in attribute.values.enumerated() {
                    Self.putValue(&out, value, i == 0 ? attribute.name : "")
                }
            }
        }
        out.append(IppTag.endOfAttributes)
        return Data(out)
    }

    /// Reads a message from the start of `data`. A document, if there is one, starts at `documentOffset`.
    /// Throws `PrintError.badResponse` for data that is cut short or not IPP.
    public static func decode(_ data: Data) throws -> (message: IppMessage, documentOffset: Int) {
        var reader = IppReader(bytes: [UInt8](data))
        let major = try reader.byte()
        let minor = try reader.byte()
        guard major == 1 || major == 2 else { throw PrintError.badResponse }
        let code = try reader.uint16()
        let requestId = try reader.int32()
        var groups = [IppGroup]()
        var tag = try reader.byte()
        while tag != IppTag.endOfAttributes {
            guard tag <= 0x0F else { throw PrintError.badResponse }
            let groupTag = tag
            var attributes = [IppAttribute]()
            tag = try reader.byte()
            while tag > 0x0F {
                let nameLength = try reader.uint16()
                let name = try reader.text(nameLength)
                let value = try readValue(&reader, tag, depth: 0)
                if !name.isEmpty {
                    attributes.append(IppAttribute(name: name, values: [value]))
                } else if !attributes.isEmpty {
                    attributes[attributes.count - 1].values.append(value)
                } else {
                    throw PrintError.badResponse
                }
                tag = try reader.byte()
            }
            groups.append(IppGroup(tag: groupTag, attributes: attributes))
        }
        let message = IppMessage(version: IppVersion(major: major, minor: minor), code: UInt16(code),
                                 requestId: requestId, groups: groups)
        return (message, reader.position)
    }

    // Real printers nest two or three deep; a reply deeper than this is hostile and would overflow the stack.
    private static let maxDepth = 16

    private static func readValue(_ reader: inout IppReader, _ tag: UInt8, depth: Int) throws -> IppValue {
        let length = try reader.uint16()
        if tag == IppTag.begCollection {
            guard depth < maxDepth else { throw PrintError.badResponse }
            try reader.skip(length)
            return try readCollection(&reader, depth: depth + 1)
        }
        let bytes = try reader.take(length)
        return value(tag, bytes)
    }

    // Members come as a memberAttrName whose value is the name, then that member's values with empty names.
    private static func readCollection(_ reader: inout IppReader, depth: Int) throws -> IppValue {
        var members = [IppAttribute]()
        while true {
            let tag = try reader.byte()
            let nameLength = try reader.uint16()
            try reader.skip(nameLength)
            if tag == IppTag.endCollection {
                let valueLength = try reader.uint16()
                try reader.skip(valueLength)
                break
            }
            if tag == IppTag.memberAttrName {
                let length = try reader.uint16()
                let name = try reader.text(length)
                members.append(IppAttribute(name: name, values: []))
                continue
            }
            guard !members.isEmpty else { throw PrintError.badResponse }
            let value = try readValue(&reader, tag, depth: depth)
            members[members.count - 1].values.append(value)
        }
        return .collection(members)
    }

    private static func value(_ tag: UInt8, _ bytes: [UInt8]) -> IppValue {
        switch tag {
        case IppTag.integer where bytes.count == 4: return .integer(int32(bytes, 0))
        case IppTag.enumeration where bytes.count == 4: return .enumValue(int32(bytes, 0))
        case IppTag.boolean where bytes.count == 1: return .boolean(bytes[0] != 0)
        case IppTag.octetString: return .octets(Data(bytes))
        case IppTag.dateTime where bytes.count == 11: return .dateTime(Data(bytes))
        case IppTag.resolution where bytes.count == 9:
            return .resolution(x: int32(bytes, 0), y: int32(bytes, 4), units: bytes[8])
        case IppTag.rangeOfInteger where bytes.count == 8: return .range(int32(bytes, 0), int32(bytes, 4))
        case IppTag.unsupported, IppTag.unknown, IppTag.noValue:
            return bytes.isEmpty ? .outOfBand(tag) : .unknown(tag: tag, Data(bytes))
        case IppTag.text: return .text(utf8(bytes))
        case IppTag.name: return .name(utf8(bytes))
        case IppTag.keyword: return .keyword(utf8(bytes))
        case IppTag.uri: return .uri(utf8(bytes))
        case IppTag.uriScheme: return .uriScheme(utf8(bytes))
        case IppTag.charset: return .charset(utf8(bytes))
        case IppTag.naturalLanguage: return .language(utf8(bytes))
        case IppTag.mimeMediaType: return .mimeType(utf8(bytes))
        case IppTag.textWithLanguage, IppTag.nameWithLanguage:
            guard let text = withLanguage(bytes) else { return .unknown(tag: tag, Data(bytes)) }
            return tag == IppTag.textWithLanguage ? .text(text) : .name(text)
        default: return .unknown(tag: tag, Data(bytes))
        }
    }

    // Two length-prefixed strings, the language and the text; only the text is kept.
    private static func withLanguage(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let language = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + language + 2 else { return nil }
        let offset = 2 + language
        let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        guard bytes.count >= offset + 2 + length else { return nil }
        return utf8(Array(bytes[(offset + 2)..<(offset + 2 + length)]))
    }

    private static func utf8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static func int32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        let value = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        return Int32(bitPattern: value)
    }

    private static func putUInt16(_ out: inout [UInt8], _ value: Int) {
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    private static func putInt32(_ out: inout [UInt8], _ value: Int32) {
        putUInt16(&out, Int(value >> 16))
        putUInt16(&out, Int(value))
    }

    private static func putEntry(_ out: inout [UInt8], _ tag: UInt8, _ name: String, _ value: [UInt8]) {
        out.append(tag)
        let nameBytes = Array(name.utf8)
        putUInt16(&out, nameBytes.count)
        out.append(contentsOf: nameBytes)
        putUInt16(&out, value.count)
        out.append(contentsOf: value)
    }

    private static func putText(_ out: inout [UInt8], _ tag: UInt8, _ name: String, _ text: String) {
        putEntry(&out, tag, name, Array(text.utf8))
    }

    private static func int32Bytes(_ values: Int32...) -> [UInt8] {
        var bytes = [UInt8]()
        for value in values { putInt32(&bytes, value) }
        return bytes
    }

    private static func putValue(_ out: inout [UInt8], _ value: IppValue, _ name: String) {
        switch value {
        case .integer(let v): putEntry(&out, IppTag.integer, name, int32Bytes(v))
        case .boolean(let v): putEntry(&out, IppTag.boolean, name, [v ? 1 : 0])
        case .enumValue(let v): putEntry(&out, IppTag.enumeration, name, int32Bytes(v))
        case .octets(let v): putEntry(&out, IppTag.octetString, name, [UInt8](v))
        case .dateTime(let v): putEntry(&out, IppTag.dateTime, name, [UInt8](v))
        case .resolution(let x, let y, let units): putEntry(&out, IppTag.resolution, name, int32Bytes(x, y) + [units])
        case .range(let lower, let upper): putEntry(&out, IppTag.rangeOfInteger, name, int32Bytes(lower, upper))
        case .text(let v): putText(&out, IppTag.text, name, v)
        case .name(let v): putText(&out, IppTag.name, name, v)
        case .keyword(let v): putText(&out, IppTag.keyword, name, v)
        case .uri(let v): putText(&out, IppTag.uri, name, v)
        case .uriScheme(let v): putText(&out, IppTag.uriScheme, name, v)
        case .charset(let v): putText(&out, IppTag.charset, name, v)
        case .language(let v): putText(&out, IppTag.naturalLanguage, name, v)
        case .mimeType(let v): putText(&out, IppTag.mimeMediaType, name, v)
        case .outOfBand(let tag): putEntry(&out, tag, name, [])
        case .unknown(let tag, let bytes): putEntry(&out, tag, name, [UInt8](bytes))
        case .collection(let members):
            putEntry(&out, IppTag.begCollection, name, [])
            for member in members {
                putText(&out, IppTag.memberAttrName, "", member.name)
                for memberValue in member.values { putValue(&out, memberValue, "") }
            }
            putEntry(&out, IppTag.endCollection, "", [])
        }
    }
}

// A read past the end throws a bad response.
private struct IppReader {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw PrintError.badResponse }
        position += 1
        return bytes[position - 1]
    }

    mutating func uint16() throws -> Int {
        let high = try byte()
        let low = try byte()
        return Int(high) << 8 | Int(low)
    }

    mutating func int32() throws -> Int32 {
        let high = try uint16()
        let low = try uint16()
        return Int32(bitPattern: UInt32(high) << 16 | UInt32(low))
    }

    mutating func skip(_ count: Int) throws {
        guard count <= bytes.count - position else { throw PrintError.badResponse }
        position += count
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count <= bytes.count - position else { throw PrintError.badResponse }
        position += count
        return Array(bytes[(position - count)..<position])
    }

    mutating func text(_ count: Int) throws -> String {
        let taken = try take(count)
        return String(decoding: taken, as: UTF8.self)
    }
}
