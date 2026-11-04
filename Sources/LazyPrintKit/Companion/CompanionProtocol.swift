import Foundation

// Twin of windows/LazyPrint.Core/Companion/CompanionProtocol.cs: the same constants, the same
// JSON bytes for the same message and the same lenient reading, so the phone and the desktop speak
// exactly one protocol.

/// The companion link between a paired phone and the desktop app: HTTP/1.1 over TLS, the phone always
/// starting the connection. The desktop's certificate is pinned by its `SpkiFingerprint` from the
/// pairing code; every request after pairing carries the phone's device secret as a bearer token with
/// its id. Endpoints (all JSON unless noted):
/// - `GET /v1/health`: reachability, answered to anyone (`HealthResponse`; with credentials it also
///   says whether the phone is still paired, a wrong secret gets 401).
/// - `POST /v1/pair`: the one call an unpaired phone may make, with the pairing code's token
///   (`PairRequest` → `PairResponse`).
/// - `GET /v1/hello`: the desktop's name and its upload limit (`HelloResponse`).
/// - `PUT /v1/inbox/{packageId}`: a print package (`PrintPackage`), idempotent by package id
///   (`InboxResponse`).
/// - `DELETE /v1/devices/self`: the phone forgets this desktop.
/// Errors are `CompanionError` with a stable code (`CompanionErrorCode`).
public enum CompanionProtocol {
    /// The protocol version, in the pairing code and every response.
    public static let version = 1
    /// The DNS-SD service type the desktop advertises while it receives.
    public static let serviceType = "_lazyprint._tcp"
    /// The `service` value of `HealthResponse`.
    public static let serviceName = "lazyprint"
    /// The port the desktop tries first; another free one is used when it is taken.
    public static let defaultPort = 52732

    public static let healthPath = "/v1/health"
    public static let pairPath = "/v1/pair"
    public static let helloPath = "/v1/hello"
    /// Followed by the package id.
    public static let inboxPrefix = "/v1/inbox/"
    public static let deviceSelfPath = "/v1/devices/self"

    /// The phone's id, sent with its secret on every request after pairing.
    public static let deviceIdHeader = "X-Device-Id"
    public static let jsonContentType = "application/json; charset=utf-8"
    public static let packageContentType = "application/vnd.lazyprint.package"

    /// The largest JSON request body (a pairing request).
    public static let maxJsonBodyBytes = 8192
    /// The DNS-SD TXT keys: the protocol version and the desktop's id.
    public static let txtVersionKey = "v"
    public static let txtIdKey = "id"

    /// The largest upload: a print package at its largest.
    public static var maxUploadBytes: Int { PrintPackage.maxPackageBytes }

    /// Whether `id` can be a phone's, desktop's or package's id: 8 to 64 characters,
    /// letters, digits, '-' and '_' (safe as a file name everywhere).
    public static func isValidId(_ id: String?) -> Bool {
        guard let id = id, id.utf16.count >= 8, id.utf16.count <= 64 else { return false }
        for scalar in id.unicodeScalars {
            switch scalar.value {
            case 97...122, 65...90, 48...57, 45, 95: continue
            default: return false
            }
        }
        return true
    }

    private static let base64UrlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Base64url without padding (RFC 4648 section 5).
    public static func encodeBase64Url(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var text: [UInt8] = []
        text.reserveCapacity((bytes.count * 4 + 2) / 3)
        var i = 0
        while i + 3 <= bytes.count {
            let block = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
            text.append(base64UrlAlphabet[(block >> 6) & 63])
            text.append(base64UrlAlphabet[block & 63])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let block = Int(bytes[i]) << 16
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
        } else if rest == 2 {
            let block = Int(bytes[i]) << 16 | Int(bytes[i + 1]) << 8
            text.append(base64UrlAlphabet[(block >> 18) & 63])
            text.append(base64UrlAlphabet[(block >> 12) & 63])
            text.append(base64UrlAlphabet[(block >> 6) & 63])
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The bytes of base64url text without padding; nil for anything else: padding, other characters,
    /// a length no encoding has, or unused bits that are not zero (so every value has exactly one text).
    public static func decodeBase64Url(_ text: String?) -> Data? {
        guard let text = text else { return nil }
        let characters = Array(text.utf16)
        guard characters.count % 4 != 1 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count * 3 / 4)
        var bits = 0
        var bitCount = 0
        for character in characters {
            let value: Int
            switch character {
            case 65...90: value = Int(character) - 65
            case 97...122: value = Int(character) - 97 + 26
            case 48...57: value = Int(character) - 48 + 52
            case 45: value = 62
            case 95: value = 63
            default: return nil
            }
            bits = (bits << 6) | value
            bitCount += 6
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8(truncatingIfNeeded: bits >> bitCount))
                bits &= (1 << bitCount) - 1
            }
        }
        guard bits == 0 else { return nil }
        return Data(bytes)
    }

    /// `text` as a JSON string literal: quote, backslash and control characters escaped, the rest as is.
    static func quote(_ text: String) -> String {
        var json = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: json += "\\\""
            case 0x5C: json += "\\\\"
            case 0x0A: json += "\\n"
            case 0x0D: json += "\\r"
            case 0x09: json += "\\t"
            case 0x08: json += "\\b"
            case 0x0C: json += "\\f"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                json += "\\u00" + (hex.count < 2 ? "0" : "") + hex
            default:
                json.unicodeScalars.append(scalar)
            }
        }
        return json + "\""
    }

    static func integer(_ value: Int) -> String { String(value) }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    /// `json` read as `T` the way settings files are read (every property on its own, defaults for
    /// anything missing or wrong-typed); nil when it is not a JSON object.
    static func decode<T: Decodable>(_ type: T.Type, _ json: Data) -> T? {
        try? JSONDecoder().decode(type, from: json)
    }
}

/// The stable error codes of `CompanionError`.
public enum CompanionErrorCode {
    public static let unauthorized = "unauthorized"
    public static let pairingClosed = "pairingClosed"
    public static let tokenInvalid = "tokenInvalid"
    public static let tokenExpired = "tokenExpired"
    public static let tokenUsed = "tokenUsed"
    public static let declined = "declined"
    public static let tooManyDevices = "tooManyDevices"
    public static let tooLarge = "tooLarge"
    public static let invalidPackage = "invalidPackage"
    public static let rateLimited = "rateLimited"
    public static let notFound = "notFound"
    public static let methodNotAllowed = "methodNotAllowed"
    public static let badRequest = "badRequest"
    public static let lengthRequired = "lengthRequired"
    public static let busy = "busy"
    public static let inboxFull = "inboxFull"
    public static let serverError = "serverError"
}

/// What went wrong, for the phone: a stable `code` and a sentence to show.
public struct CompanionError: Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public func toJSON() -> String {
        "{\"error\":\(CompanionProtocol.quote(code)),\"message\":\(CompanionProtocol.quote(message))}"
    }

    public static func fromJSON(_ json: Data) -> CompanionError? {
        guard let dto = CompanionProtocol.decode(ErrorDTO.self, json), !dto.error.isEmpty else { return nil }
        return CompanionError(code: dto.error, message: dto.message)
    }

    public static var unauthorized: CompanionError {
        CompanionError(code: CompanionErrorCode.unauthorized, message: "This computer no longer recognizes this phone. Pair it again.")
    }
    public static var pairingClosed: CompanionError {
        CompanionError(code: CompanionErrorCode.pairingClosed, message: "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.")
    }
    public static var tokenInvalid: CompanionError {
        CompanionError(code: CompanionErrorCode.tokenInvalid, message: "This pairing code is not valid. Scan the code shown on the computer again.")
    }
    public static var tokenExpired: CompanionError {
        CompanionError(code: CompanionErrorCode.tokenExpired, message: "This pairing code has expired. Show a new code on the computer.")
    }
    public static var tokenUsed: CompanionError {
        CompanionError(code: CompanionErrorCode.tokenUsed, message: "This pairing code was already used. Show a new code on the computer.")
    }
    public static var declined: CompanionError {
        CompanionError(code: CompanionErrorCode.declined, message: "Pairing was declined on the computer.")
    }
    public static var tooManyDevices: CompanionError {
        CompanionError(code: CompanionErrorCode.tooManyDevices, message: "This computer is paired with \(PairedDeviceStore.maxDevices) phones already. Remove one there first.")
    }
    public static var tooLarge: CompanionError {
        CompanionError(code: CompanionErrorCode.tooLarge, message: "This file is too large to send in one piece.")
    }
    public static var rateLimited: CompanionError {
        CompanionError(code: CompanionErrorCode.rateLimited, message: "Too many attempts. Wait a minute, then try again.")
    }
    public static var notFound: CompanionError {
        CompanionError(code: CompanionErrorCode.notFound, message: "Not found.")
    }
    public static var methodNotAllowed: CompanionError {
        CompanionError(code: CompanionErrorCode.methodNotAllowed, message: "This address does not take that request.")
    }
    public static var badRequest: CompanionError {
        CompanionError(code: CompanionErrorCode.badRequest, message: "The request was not understood.")
    }
    public static var lengthRequired: CompanionError {
        CompanionError(code: CompanionErrorCode.lengthRequired, message: "The request must say how long it is (Content-Length).")
    }
    public static var busy: CompanionError {
        CompanionError(code: CompanionErrorCode.busy, message: "This file is still being received. Try again in a moment.")
    }
    public static var inboxFull: CompanionError {
        CompanionError(code: CompanionErrorCode.inboxFull, message: CompanionInbox.fullMessage)
    }
    public static var serverError: CompanionError {
        CompanionError(code: CompanionErrorCode.serverError, message: "The computer could not store this file.")
    }

    /// The error for a code the computer sent, nil for a code with no fixed wording.
    public static func local(code: String) -> CompanionError? {
        switch code {
        case CompanionErrorCode.unauthorized: return unauthorized
        case CompanionErrorCode.pairingClosed: return pairingClosed
        case CompanionErrorCode.tokenInvalid: return tokenInvalid
        case CompanionErrorCode.tokenExpired: return tokenExpired
        case CompanionErrorCode.tokenUsed: return tokenUsed
        case CompanionErrorCode.declined: return declined
        case CompanionErrorCode.tooManyDevices: return tooManyDevices
        case CompanionErrorCode.tooLarge: return tooLarge
        case CompanionErrorCode.rateLimited: return rateLimited
        case CompanionErrorCode.notFound: return notFound
        case CompanionErrorCode.methodNotAllowed: return methodNotAllowed
        case CompanionErrorCode.badRequest: return badRequest
        case CompanionErrorCode.lengthRequired: return lengthRequired
        case CompanionErrorCode.busy: return busy
        case CompanionErrorCode.inboxFull: return inboxFull
        case CompanionErrorCode.serverError: return serverError
        default: return nil
        }
    }
}

/// The body of `POST /v1/pair`: the pairing code's token and who the phone is.
public struct PairRequest: Equatable, Sendable {
    public var token: String
    public var phoneId: String
    public var phoneName: String
    public var platform: String
    public var appVersion: String

    /// The longest phone name kept, in UTF-8 bytes (longer names are cut).
    public static let maxNameBytes = 128

    public init(token: String, phoneId: String, phoneName: String, platform: String, appVersion: String) {
        self.token = token
        self.phoneId = phoneId
        self.phoneName = phoneName
        self.platform = platform
        self.appVersion = appVersion
    }

    public func toJSON() -> String {
        "{\"token\":\(CompanionProtocol.quote(token)),\"phoneId\":\(CompanionProtocol.quote(phoneId))"
            + ",\"phoneName\":\(CompanionProtocol.quote(phoneName)),\"platform\":\(CompanionProtocol.quote(platform))"
            + ",\"appVersion\":\(CompanionProtocol.quote(appVersion))}"
    }

    public static func fromJSON(_ json: Data) -> PairRequest? {
        guard let dto = CompanionProtocol.decode(PairRequestDTO.self, json) else { return nil }
        return PairRequest(token: dto.token, phoneId: dto.phoneId, phoneName: dto.phoneName, platform: dto.platform,
                           appVersion: dto.appVersion)
    }
}

/// The answer to a pairing the user allowed: who the desktop is, the phone's secret and the key
/// packages put in the cloud sync folder are sealed with (`SyncPackage`).
public struct PairResponse: Equatable, Sendable {
    public var desktopId: String
    public var desktopName: String
    public var deviceSecret: String
    public var protocolVersion: Int
    /// Base64url of the 32-byte sync key; nil from a desktop without the sync folder (left out of the JSON).
    public var syncKey: String?

    public init(desktopId: String, desktopName: String, deviceSecret: String, protocolVersion: Int, syncKey: String? = nil) {
        self.desktopId = desktopId
        self.desktopName = desktopName
        self.deviceSecret = deviceSecret
        self.protocolVersion = protocolVersion
        self.syncKey = syncKey
    }

    public func toJSON() -> String {
        "{\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"desktopId\":\(CompanionProtocol.quote(desktopId))"
            + ",\"desktopName\":\(CompanionProtocol.quote(desktopName)),\"deviceSecret\":\(CompanionProtocol.quote(deviceSecret))"
            + (syncKey.map { ",\"syncKey\":\(CompanionProtocol.quote($0))" } ?? "") + "}"
    }

    public static func fromJSON(_ json: Data) -> PairResponse? {
        guard let dto = CompanionProtocol.decode(PairResponseDTO.self, json) else { return nil }
        return PairResponse(desktopId: dto.desktopId, desktopName: dto.desktopName, deviceSecret: dto.deviceSecret,
                            protocolVersion: Int(dto.protocolVersion), syncKey: dto.syncKey)
    }
}

/// The answer to `GET /v1/health`; `paired` only when the phone sent valid credentials.
public struct HealthResponse: Equatable, Sendable {
    public var protocolVersion: Int
    public var paired: Bool

    public init(protocolVersion: Int, paired: Bool) {
        self.protocolVersion = protocolVersion
        self.paired = paired
    }

    public func toJSON() -> String {
        "{\"service\":\(CompanionProtocol.quote(CompanionProtocol.serviceName))"
            + ",\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"paired\":\(CompanionProtocol.bool(paired))}"
    }

    /// nil unless the body says it is Lazy Print's.
    public static func fromJSON(_ json: Data) -> HealthResponse? {
        guard let dto = CompanionProtocol.decode(HealthDTO.self, json), dto.service == CompanionProtocol.serviceName else {
            return nil
        }
        return HealthResponse(protocolVersion: Int(dto.protocolVersion), paired: dto.paired)
    }
}

/// The answer to `GET /v1/hello`: the desktop and the largest upload it takes.
public struct HelloResponse: Equatable, Sendable {
    public var desktopId: String
    public var desktopName: String
    public var protocolVersion: Int
    public var maxUploadBytes: Int

    public init(desktopId: String, desktopName: String, protocolVersion: Int, maxUploadBytes: Int) {
        self.desktopId = desktopId
        self.desktopName = desktopName
        self.protocolVersion = protocolVersion
        self.maxUploadBytes = maxUploadBytes
    }

    public func toJSON() -> String {
        "{\"protocolVersion\":\(CompanionProtocol.integer(protocolVersion)),\"desktopId\":\(CompanionProtocol.quote(desktopId))"
            + ",\"desktopName\":\(CompanionProtocol.quote(desktopName))"
            + ",\"maxUploadBytes\":\(CompanionProtocol.integer(maxUploadBytes))}"
    }

    public static func fromJSON(_ json: Data) -> HelloResponse? {
        guard let dto = CompanionProtocol.decode(HelloDTO.self, json) else { return nil }
        return HelloResponse(desktopId: dto.desktopId, desktopName: dto.desktopName, protocolVersion: Int(dto.protocolVersion),
                             maxUploadBytes: Int(dto.maxUploadBytes))
    }
}

/// The answer to an upload: the package and whether it had arrived before.
public struct InboxResponse: Equatable, Sendable {
    public var packageId: String
    public var duplicate: Bool

    public init(packageId: String, duplicate: Bool) {
        self.packageId = packageId
        self.duplicate = duplicate
    }

    public func toJSON() -> String {
        "{\"packageId\":\(CompanionProtocol.quote(packageId))"
            + ",\"duplicate\":\(CompanionProtocol.bool(duplicate))}"
    }

    public static func fromJSON(_ json: Data) -> InboxResponse? {
        guard let dto = CompanionProtocol.decode(InboxDTO.self, json) else { return nil }
        return InboxResponse(packageId: dto.packageId, duplicate: dto.duplicate)
    }
}

// MARK: - The messages as read: every property on its own and leniently (Global rule 5), the defaults below
// for anything missing, null, wrong-typed or unknown. Whole numbers decode as the C# twin's int and
// long, so both read the same values.

private struct ErrorDTO: Decodable {
    var error = ""
    var message = ""

    enum CodingKeys: String, CodingKey { case error, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = c.decodeLenient(forKey: .error, default: error)
        message = c.decodeLenient(forKey: .message, default: message)
    }
}

private struct PairRequestDTO: Decodable {
    var token = ""
    var phoneId = ""
    var phoneName = ""
    var platform = ""
    var appVersion = ""

    enum CodingKeys: String, CodingKey { case token, phoneId, phoneName, platform, appVersion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = c.decodeLenient(forKey: .token, default: token)
        phoneId = c.decodeLenient(forKey: .phoneId, default: phoneId)
        phoneName = c.decodeLenient(forKey: .phoneName, default: phoneName)
        platform = c.decodeLenient(forKey: .platform, default: platform)
        appVersion = c.decodeLenient(forKey: .appVersion, default: appVersion)
    }
}

private struct PairResponseDTO: Decodable {
    var protocolVersion: Int32 = 0
    var desktopId = ""
    var desktopName = ""
    var deviceSecret = ""
    var syncKey: String?

    enum CodingKeys: String, CodingKey { case protocolVersion, desktopId, desktopName, deviceSecret, syncKey }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        desktopName = c.decodeLenient(forKey: .desktopName, default: desktopName)
        deviceSecret = c.decodeLenient(forKey: .deviceSecret, default: deviceSecret)
        syncKey = c.decodeLenient(forKey: .syncKey, default: syncKey)
    }
}

private struct HealthDTO: Decodable {
    var service = ""
    var protocolVersion: Int32 = 0
    var paired = false

    enum CodingKeys: String, CodingKey { case service, protocolVersion, paired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        service = c.decodeLenient(forKey: .service, default: service)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        paired = c.decodeLenient(forKey: .paired, default: paired)
    }
}

private struct HelloDTO: Decodable {
    var protocolVersion: Int32 = 0
    var desktopId = ""
    var desktopName = ""
    var maxUploadBytes: Int64 = 0

    enum CodingKeys: String, CodingKey { case protocolVersion, desktopId, desktopName, maxUploadBytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = c.decodeLenient(forKey: .protocolVersion, default: protocolVersion)
        desktopId = c.decodeLenient(forKey: .desktopId, default: desktopId)
        desktopName = c.decodeLenient(forKey: .desktopName, default: desktopName)
        maxUploadBytes = c.decodeLenient(forKey: .maxUploadBytes, default: maxUploadBytes)
    }
}

private struct InboxDTO: Decodable {
    var packageId = ""
    var duplicate = false

    enum CodingKeys: String, CodingKey { case packageId, duplicate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packageId = c.decodeLenient(forKey: .packageId, default: packageId)
        duplicate = c.decodeLenient(forKey: .duplicate, default: duplicate)
    }
}
