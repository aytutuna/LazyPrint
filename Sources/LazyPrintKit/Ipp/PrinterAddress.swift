import Foundation

// Twin of windows/LazyPrint.Core/Ipp/PrinterAddress.cs: the same accepted forms, messages and
// canonical text (the text kept in ipp-hosts.json). The C# code leans on System.Uri and IPAddress;
// here the address text is read by hand (IppUrlText) and IPv6 addresses by inet_pton/inet_ntop, to
// the same results for every form a user types or discovery reports.

/// What is wrong with a typed printer address, in words for the user.
public struct PrinterAddressError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Where an IPP printer answers: scheme, host, port and resource path. Parsed from what a user types
/// ("192.168.1.50", "printer.local:8631", "ipps://10.0.0.7", "[fe80::1%12]:631",
/// "http://host:8080/ipp/print") and written back in one canonical form, `description`, the text kept
/// in ipp-hosts.json. Secure means ipps (and https); http and https are read as ipp and ipps on the
/// port they name, so a printer-uri is always ipp or ipps. Two addresses are equal when their canonical
/// texts are, ignoring case.
public struct PrinterAddress: Hashable, CustomStringConvertible, Sendable {
    /// The port IPP uses, for ipp and ipps alike.
    public static let defaultPort = 631
    /// The resource path IPP Everywhere printers answer at.
    public static let defaultPath = "ipp/print"

    /// ipps (IPP over TLS) instead of plain ipp.
    public let secure: Bool
    /// Host name (lowercase) or IP address; IPv6 without brackets, with its zone (%12) when it has one.
    public let host: String
    public let port: Int
    /// The IPP resource path below the host, without slashes ("ipp/print" unless given).
    public let resourcePath: String

    private init(secure: Bool, host: String, port: Int, resourcePath: String) {
        self.secure = secure
        self.host = host
        self.port = port
        self.resourcePath = resourcePath
    }

    private var isIPv6: Bool { host.contains(":") }

    private var bracketedHost: String { isIPv6 ? "[" + host + "]" : host }

    /// "host:port" (IPv6 in brackets, with its zone), lowercase: identifies the endpoint, e.g. for
    /// certificate trust.
    public var authority: String { bracketedHost + ":" + String(port) }

    private var pathText: String { "/" + IppUrlText.escapePath(resourcePath) }

    /// The printer-uri an IPP request carries: ipp or ipps, always with the port. An IPv6 zone is
    /// left out, since only this machine knows what it means.
    public var printerUri: String {
        let name = isIPv6 ? "[" + String(host.prefix { $0 != "%" }) + "]" : host
        return (secure ? "ipps://" : "ipp://") + name + ":" + String(port) + pathText
    }

    /// Where requests are posted: the printer-uri over http or https, with the scheme's default port
    /// left out. An IPv6 zone is written "%25" + zone as RFC 6874 asks. The same text as C#'s
    /// `RequestUri.AbsoluteUri`, except that System.Uri drops the zone from it.
    public var requestURLText: String {
        let name = isIPv6 ? "[" + host.replacingOccurrences(of: "%", with: "%25") + "]" : host
        var text = (secure ? "https://" : "http://") + name
        if port != (secure ? 443 : 80) {
            text += ":" + String(port)
        }
        return text + pathText
    }

    /// `requestURLText` as a URL; nil only when Foundation does not take the text.
    public var requestURL: URL? { URL(string: requestURLText) }

    /// The canonical text: the bare host for the plain default ("192.168.1.50"), "host:port" for plain
    /// ipp on another port, otherwise a URL ("ipps://10.0.0.7", "ipp://host:8080/printers/office").
    /// Parsing it gives an equal address, except for a resource at the root of the host, which only a
    /// discovered service can name (it reads back as /ipp/print).
    public var description: String {
        if !secure && resourcePath == Self.defaultPath {
            return port == Self.defaultPort ? bracketedHost : bracketedHost + ":" + String(port)
        }
        var text = (secure ? "ipps://" : "ipp://") + bracketedHost
        if port != Self.defaultPort {
            text += ":" + String(port)
        }
        if resourcePath != Self.defaultPath {
            text += "/" + IppUrlText.escapePath(resourcePath)
        }
        return text
    }

    public static func == (lhs: PrinterAddress, rhs: PrinterAddress) -> Bool {
        lhs.description.lowercased() == rhs.description.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description.lowercased())
    }

    /// The ipps address to try when a host typed bare (no scheme, no path) got no answer over plain
    /// ipp on port 631; nil for any other address.
    public func httpsFallback(typed text: String) -> PrinterAddress? {
        guard !secure, port == Self.defaultPort, resourcePath == Self.defaultPath, !text.contains("/") else { return nil }
        return PrinterAddress(secure: true, host: host, port: port, resourcePath: resourcePath)
    }

    /// The same host, port and path over TLS or not: where the client goes on HTTP 426 or a failed handshake.
    func withSecure(_ secure: Bool) -> PrinterAddress {
        PrinterAddress(secure: secure, host: host, port: port, resourcePath: resourcePath)
    }

    /// An address from its parts (a discovered service); nil when the host or the port is not usable.
    public static func create(secure: Bool, host: String, port: Int, resourcePath: String) -> PrinterAddress? {
        guard port >= 1 && port <= 65535 else { return nil }
        var bare = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while bare.hasPrefix("[") {
            bare.removeFirst()
        }
        while bare.hasSuffix("]") {
            bare.removeLast()
        }
        guard let normalized = IppHostText.normalizeHost(bare) else { return nil }
        let path = resourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return PrinterAddress(secure: secure, host: normalized, port: port, resourcePath: path)
    }

    /// Parses an address; throws `PrinterAddressError` with a user-facing message.
    public static func parse(_ text: String) throws -> PrinterAddress {
        var error = ""
        guard let address = tryParse(text, error: &error) else { throw PrinterAddressError(error) }
        return address
    }

    /// Parses what a user typed. Accepted: an IPv4 or IPv6 address or host name, optionally with a
    /// port ("host:8631", "[2001:db8::1]:8631"), or an ipp, ipps, http or https URL with an optional
    /// port and resource path. Plain addresses mean ipp on port 631 at /ipp/print; an ipp or ipps URL
    /// without a port means 631, an http or https one the web's 80 or 443. nil when it is none of
    /// these, with what is wrong, for the user, in `error`.
    public static func tryParse(_ text: String?, error: inout String) -> PrinterAddress? {
        error = ""
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            error = "Enter the printer's IP address or host name."
            return nil
        }
        if value.contains(where: { $0.isWhitespace }) {
            error = "An address cannot contain spaces."
            return nil
        }

        let hasScheme = value.contains("://")
        // "192.168.1.5/ipp/print": a path without a scheme means plain ipp.
        if !hasScheme && value.contains("/") {
            return tryParse("ipp://" + value, error: &error)
        }
        if hasScheme {
            return tryParseUrl(value, error: &error)
        }

        let host: String
        var port: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else {
                error = "An IPv6 address in brackets needs its closing \"]\"."
                return nil
            }
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else {
                    error = "That is not a valid address."
                    return nil
                }
                port = String(rest.dropFirst())
            }
        } else if value.filter({ $0 == ":" }).count >= 2 {
            host = value   // a bare IPv6 address: no port
        } else if let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            port = String(value[value.index(after: colon)...])
        } else {
            host = value
        }

        var portNumber = defaultPort
        if let portText = port {
            guard let number = IppHostText.port(portText), number >= 1 else {
                error = "The port must be a number from 1 to 65535."
                return nil
            }
            portNumber = number
        }
        guard let normalized = IppHostText.normalizeHost(host) else {
            error = "\"\(host)\" is not a valid IP address or host name."
            return nil
        }
        if lacksZone(normalized) {
            error = "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12."
            return nil
        }
        return PrinterAddress(secure: false, host: normalized, port: portNumber, resourcePath: defaultPath)
    }

    /// A link-local IPv6 address with no zone: it cannot be reached, as discovery also finds.
    private static func lacksZone(_ host: String) -> Bool {
        guard host.contains(":"), let ip = IppHostText.ipv6(host) else { return false }
        return ip.isLinkLocal && ip.zone == 0
    }

    private static func tryParseUrl(_ value: String, error: inout String) -> PrinterAddress? {
        guard let parts = IppUrlText.split(value), !parts.host.isEmpty,
              parts.bracketed || IppHostText.isPlausibleHost(parts.host) else {
            error = "That is not a valid address."
            return nil
        }
        let secure = parts.scheme == "ipps" || parts.scheme == "https"
        switch parts.scheme {
        case "ipp", "ipps", "http", "https":
            break
        default:
            error = "Use an address that starts with ipp://, ipps://, http:// or https://, or just the IP address or host name."
            return nil
        }
        if let userInfo = parts.userInfo, !userInfo.isEmpty {
            error = "Leave out the user name and password; printers do not need them."
            return nil
        }
        guard let host = IppHostText.normalizeHost(parts.host) else {
            if parts.bracketed {
                error = "That is not a valid address."
            } else {
                error = "\"\(parts.host.lowercased())\" is not a valid IP address or host name."
            }
            return nil
        }
        if lacksZone(host) {
            error = "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12."
            return nil
        }
        let flat = IppUrlText.removeDotSegments(parts.path)
        let path = (flat.removingPercentEncoding ?? flat).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // ipp and ipps without a port mean 631; http and https the web's 80 and 443.
        let webPort = parts.scheme == "http" ? 80 : parts.scheme == "https" ? 443 : defaultPort
        let port = parts.port ?? webPort
        return PrinterAddress(secure: secure, host: host, port: port, resourcePath: path.isEmpty ? defaultPath : path)
    }
}

/// An IPv6 address as `IppHostText.ipv6` reads it.
struct IppIPv6Address: Equatable {
    /// Its standard text: lowercase, the longest run of zero groups as "::", with "%zone" when it has a
    /// zone other than 0 (the same text as .NET's `IPAddress.ToString`).
    let text: String
    /// fe80::/10.
    let isLinkLocal: Bool
    /// The zone (interface index; a name is read as its index); 0 when none was given.
    let zone: UInt32
}

/// The host rules of the printer addresses, the C# code's `NormalizeHost`, `IPAddress.TryParse` and
/// `Uri.CheckHostName` as far as addresses use them.
enum IppHostText {
    /// A host name in lowercase (without a trailing dot) or an IP address in its standard form (IPv6
    /// keeps its zone); nil when it is neither.
    static func normalizeHost(_ host: String) -> String? {
        if host.isEmpty {
            return nil
        }
        if host.contains(":") {
            return ipv6(host)?.text
        }
        if isDigitsAndDots(host) {
            // Digits and dots only: it has to be a complete dotted IPv4 address ("192.168.1" would
            // otherwise pass as a host name).
            return ipv4(host)
        }
        guard isDnsName(host) else { return nil }
        var name = host
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name.lowercased()
    }

    /// Four decimal numbers of up to three digits, each at most 255, written without leading zeros.
    static func ipv4(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var numbers: [String] = []
        for part in parts {
            guard part.count >= 1, part.count <= 3, isDigits(part), let number = Int(part), number <= 255 else {
                return nil
            }
            numbers.append(String(number))
        }
        return numbers.joined(separator: ".")
    }

    /// An IPv6 address with an optional zone, an interface number ("fe80::1%12") or the name of an
    /// interface on this device ("fe80::1%en0"), read as its number as .NET does; nil when it is not
    /// one, or when its zone is neither (a link-local address without its interface cannot be reached).
    static func ipv6(_ text: String) -> IppIPv6Address? {
        var addressText = text
        var zone: UInt32 = 0
        if let percent = text.firstIndex(of: "%") {
            addressText = String(text[..<percent])
            let zoneText = String(text[text.index(after: percent)...])
            if !zoneText.isEmpty {
                if isDigits(zoneText) {
                    guard let number = UInt32(zoneText) else { return nil }
                    zone = number
                } else {
                    let index = if_nametoindex(zoneText)
                    guard index > 0 else { return nil }
                    zone = index
                }
            }
        }
        if addressText.isEmpty {
            return nil
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, addressText, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let formatted = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.lowercased()
        if formatted.isEmpty {
            return nil
        }
        let bytes = withUnsafeBytes(of: &address) { [UInt8]($0) }
        let linkLocal = bytes.count == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        return IppIPv6Address(text: zone == 0 ? formatted : formatted + "%" + String(zone), isLinkLocal: linkLocal, zone: zone)
    }

    /// A DNS host name as .NET's `Uri.CheckHostName` accepts one: labels of 1 to 63 characters
    /// separated by dots (one trailing dot allowed), each starting with a letter or digit and made of
    /// letters, digits, '-' and '_'; letters beyond ASCII are taken as an internationalized name.
    static func isDnsName(_ host: String) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, let last = labels.last, last.isEmpty {
            labels.removeLast()
        }
        for label in labels {
            guard label.count >= 1, label.count <= 63 else { return false }
            var first = true
            for scalar in label.unicodeScalars {
                let value = scalar.value
                let isAlphanumeric = (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A)
                    || (value >= 0x61 && value <= 0x7A)
                let isOther = value > 0x7F && !scalar.properties.isWhitespace
                    && scalar.properties.generalCategory != .control
                if first {
                    if !isAlphanumeric && !isOther { return false }
                    first = false
                } else if !isAlphanumeric && !isOther && value != 0x2D && value != 0x5F {
                    return false
                }
            }
        }
        return true
    }

    /// What a URL's host may be before `normalizeHost` reads it: digits and dots, or a DNS name.
    static func isPlausibleHost(_ host: String) -> Bool {
        isDigitsAndDots(host) || isDnsName(host)
    }

    /// A port as typed: digits only (no sign or spaces) and at most 65535; nil otherwise.
    static func port<S: StringProtocol>(_ text: S) -> Int? {
        guard !text.isEmpty, isDigits(text) else { return nil }
        var value = 0
        for scalar in text.unicodeScalars {
            value = value * 10 + Int(scalar.value - 0x30)
            if value > 65535 {
                return nil
            }
        }
        return value
    }

    static func isDigits<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    private static func isDigitsAndDots(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "." || ($0.value >= 0x30 && $0.value <= 0x39) }
    }
}

/// The parts of a URL's text, as `IppUrlText.split` reads them.
struct IppUrlParts: Equatable {
    /// Lowercase.
    var scheme: String
    /// What came before an "@"; nil when there was none.
    var userInfo: String?
    /// As written, without brackets; "" when there is none.
    var host: String
    /// The host was in brackets (an IPv6 address).
    var bracketed: Bool
    /// nil when the URL names none (or only a ":").
    var port: Int?
    /// The path as written (still percent-encoded), "" when there is none.
    var path: String
}

/// URL text read by hand, so the address rules do not depend on how a Foundation version reads URLs.
enum IppUrlText {
    /// "scheme://userinfo@host:port/path?query#fragment" in its parts; nil when the text is not of that
    /// shape, its port is not a number up to 65535, or a bracketed host does not close.
    static func split(_ text: String) -> IppUrlParts? {
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = String(text[..<separator.lowerBound])
        guard isScheme(scheme) else { return nil }
        let rest = text[separator.upperBound...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        let afterAuthority = rest[authorityEnd...]
        let pathEnd = afterAuthority.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? afterAuthority.endIndex
        let path = String(afterAuthority[..<pathEnd])

        var userInfo: String?
        if let at = authority.lastIndex(of: "@") {
            userInfo = String(authority[..<at])
            authority = authority[authority.index(after: at)...]
        }

        let host: String
        var bracketed = false
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            bracketed = true
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else if let colon = authority.firstIndex(of: ":") {
            host = String(authority[..<colon])
            portText = authority[authority.index(after: colon)...]
        } else {
            host = String(authority)
        }

        var port: Int?
        if let given = portText, !given.isEmpty {
            guard let number = IppHostText.port(given) else { return nil }
            port = number
        }
        return IppUrlParts(scheme: scheme.lowercased(), userInfo: userInfo, host: host, bracketed: bracketed,
                           port: port, path: path)
    }

    /// "a/./b/../c" becomes "a/c": the path's "." and ".." segments resolved, as System.Uri does before
    /// the path is read; the leading slash is dropped.
    static func removeDotSegments(_ path: String) -> String {
        var output: [Substring] = []
        var segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if let first = segments.first, first.isEmpty {
            segments.removeFirst()
        }
        for segment in segments {
            if segment == "." {
                continue
            }
            if segment == ".." {
                if !output.isEmpty {
                    output.removeLast()
                }
                continue
            }
            output.append(segment)
        }
        return output.joined(separator: "/")
    }

    /// A resource path for a URL: every byte percent-encoded (uppercase hex) except the unreserved
    /// characters and '/', as C#'s `Uri.EscapeDataString` with "%2F" put back.
    static func escapePath(_ path: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var text = ""
        for byte in path.utf8 {
            let isAlphanumeric = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
            if isAlphanumeric || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E || byte == 0x2F {
                text.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                text.append("%")
                text.append(hex[Int(byte >> 4)])
                text.append(hex[Int(byte & 0x0F)])
            }
        }
        return text
    }

    /// "host:port" of a URL's text in the form `PrinterAddress.authority` uses: the host lowercase, an
    /// IPv6 address in brackets with its zone ("%25" read as "%", RFC 6874), the port the URL names or
    /// its scheme's default; "" when the text is not a URL.
    static func authority(_ text: String) -> String {
        guard let parts = split(text) else { return "" }
        var host = parts.host.lowercased()
        if parts.bracketed {
            if let range = host.range(of: "%25") {
                host.replaceSubrange(range, with: "%")
            }
            host = "[" + host + "]"
        }
        var port = -1
        if let given = parts.port {
            port = given
        } else {
            switch parts.scheme {
            case "http": port = 80
            case "https": port = 443
            case "ipp", "ipps": port = PrinterAddress.defaultPort
            default: break
            }
        }
        return host + ":" + String(port)
    }

    private static func isScheme(_ text: String) -> Bool {
        var first = true
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isLetter = (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
            let isDigit = value >= 0x30 && value <= 0x39
            let isMark = value == 0x2B || value == 0x2D || value == 0x2E   // + - .
            if first {
                if !isLetter { return false }
                first = false
            } else if !isLetter && !isDigit && !isMark {
                return false
            }
        }
        return !first
    }
}
