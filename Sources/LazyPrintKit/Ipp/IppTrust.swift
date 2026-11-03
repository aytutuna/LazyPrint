import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppTrust.cs (the TLS hook and the certificate type differ).
//
// Printers make their own certificates, so one is trusted the first time the app connects (trust on first use) and
// pinned by the SHA-256 of its public key (cut out by `SpkiFingerprint`) in ipp-trust.json; a different key for a
// known printer is refused until the user trusts it. The URLSession delegate that feeds the validator is the client's.

/// What the trust store says about a certificate a printer presented.
public enum IppTrustVerdict: String, Sendable {
    /// Neither this certificate nor the printer has been trusted before.
    case unknown
    /// The certificate is trusted (pinned, or valid for the system).
    case trusted
    /// The printer was trusted with a different certificate.
    case changed
    /// The printer presented no certificate that could be pinned.
    case invalid
}

/// One trusted printer certificate (an entry of ipp-trust.json).
public struct IppTrustedCertificate: Codable, Equatable, Sendable {
    /// SHA-256 of the certificate's public key (SubjectPublicKeyInfo), lowercase hex.
    public var fingerprint = ""
    /// The printer's UUID (`IppTxtRecord.uuidKey`); "" when it was not known.
    public var deviceUuid = ""
    /// Where the certificate was seen ("host:port", see `PrinterAddress.authority`).
    public var addresses: [String] = []
    /// The printer's name when it was trusted (for people reading the file).
    public var name = ""
    /// When the user trusted it. Each platform writes the date its own way (JSONEncoder's number here,
    /// ISO 8601 text in C#); the other platform's form reads as nil.
    public var trusted: Date?

    enum CodingKeys: String, CodingKey {
        case fingerprint, deviceUuid, addresses, name, trusted
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fingerprint = c.decodeLenient(forKey: .fingerprint, default: fingerprint)
        deviceUuid = c.decodeLenient(forKey: .deviceUuid, default: deviceUuid)
        addresses = c.decodeLenient(forKey: .addresses, default: addresses)
        name = c.decodeLenient(forKey: .name, default: name)
        trusted = c.decodeLenient(forKey: .trusted, default: trusted)
    }
}

/// The contents of ipp-trust.json.
public struct IppTrustFile: Codable, Equatable, Sendable {
    public var certificates: [IppTrustedCertificate] = []

    enum CodingKeys: String, CodingKey {
        case certificates
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        certificates = c.decodeLenient(forKey: .certificates, default: certificates)
    }
}

/// What `IppTrustStore.check` found: the verdict, and for `changed` the certificate trusted before
/// for that printer (the C# method's `previous` out parameter).
public struct IppTrustCheck: Equatable, Sendable {
    public let verdict: IppTrustVerdict
    public let previous: IppTrustedCertificate?

    public init(verdict: IppTrustVerdict, previous: IppTrustedCertificate? = nil) {
        self.verdict = verdict
        self.previous = previous
    }
}

/// Why a certificate could not be trusted.
public enum IppTrustStoreError: Error, Equatable, Sendable {
    /// There was no certificate (an empty fingerprint).
    case noCertificate
}

/// The trusted printer certificates (ipp-trust.json), safe to use from any thread. The file is
/// re-read for every check and before every write, since several windows of the app may share it;
/// certificates trusted while the file could not be written stay trusted for the rest of the session.
/// It follows the settings-file rules (CONTRACTS.md, Global rule 5).
public final class IppTrustStore: @unchecked Sendable {
    public static let fileName = "ipp-trust.json"
    /// Addresses remembered per certificate; the oldest are dropped beyond this.
    static let maxAddresses = 8

    /// A certificate trusted (and the address it was trusted at) that is not in the file yet: its last
    /// write failed.
    private struct UnsavedPin {
        var pin: IppTrustedCertificate
        let address: String
    }

    private let url: URL
    private let lock = NSLock()
    private var file: IppTrustFile
    private var unsaved: [UnsavedPin] = []

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps ipp-trust.json in `directory` (tests).
    public init(directory: URL) {
        url = directory.appendingPathComponent(IppTrustStore.fileName)
        file = StoreFiles.load(IppTrustFile.self, from: url) ?? IppTrustFile()
    }

    /// Whether `fingerprint` may be trusted for the printer with `deviceUuid` (nil when unknown) at
    /// `authority`. A pinned public key is trusted wherever it shows up (only the printer holds its
    /// private key); the address it was reached at, and the printer's UUID when the pin did not have
    /// one, are remembered. Otherwise, a printer trusted before with another key (the same UUID, or,
    /// when either UUID is unknown, the same address) is `changed`, with that entry as `previous`. A
    /// pinned key that claims the UUID of a printer trusted with another key is `changed` too: a key
    /// vouches only for the printer it was trusted for.
    public func check(_ fingerprint: String, deviceUuid: String?, authority: String) -> IppTrustCheck {
        if fingerprint.isEmpty {
            return IppTrustCheck(verdict: .invalid)
        }
        let uuid = IppTxtRecord.uuidKey(deviceUuid) ?? ""
        let address = authority.lowercased()
        lock.lock()
        defer { lock.unlock() }
        reload()
        if let index = file.certificates.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var pinned = file.certificates[index]
            if !uuid.isEmpty && pinned.deviceUuid != uuid,
               let other = file.certificates.first(where: { $0.deviceUuid == uuid }) {
                return IppTrustCheck(verdict: .changed, previous: other)
            }
            var learned = false
            if pinned.deviceUuid.isEmpty && !uuid.isEmpty {
                pinned.deviceUuid = uuid
                learned = true
            }
            if !pinned.addresses.contains(address) {
                pinned.addresses.append(address)
                if pinned.addresses.count > IppTrustStore.maxAddresses {
                    pinned.addresses.removeFirst()
                }
                learned = true
            }
            if learned {
                file.certificates[index] = pinned
                // An unsaved pin is the same entry: it learns too.
                for k in unsaved.indices where unsaved[k].pin.fingerprint == fingerprint {
                    unsaved[k].pin = pinned
                }
                save()
            }
            return IppTrustCheck(verdict: .trusted)
        }
        let previous = file.certificates.first(where: { IppTrustStore.samePrinter($0, uuid: uuid, address: address) })
        return IppTrustCheck(verdict: previous == nil ? .unknown : .changed, previous: previous)
    }

    /// Trusts `fingerprint` for a printer, replacing whatever was trusted for that printer before (see
    /// `check`), and saves the file. Throws `IppTrustStoreError.noCertificate` for an empty one.
    public func trust(_ fingerprint: String, deviceUuid: String?, authority: String, name: String) throws {
        if fingerprint.isEmpty {
            throw IppTrustStoreError.noCertificate
        }
        let uuid = IppTxtRecord.uuidKey(deviceUuid) ?? ""
        let address = authority.lowercased()
        lock.lock()
        defer { lock.unlock() }
        reload()
        unsaved.removeAll(where: { IppTrustStore.replaces($0.pin, fingerprint: fingerprint, uuid: uuid, address: address) })
        file.certificates.removeAll(where: { IppTrustStore.replaces($0, fingerprint: fingerprint, uuid: uuid, address: address) })
        var pin = IppTrustedCertificate()
        pin.fingerprint = fingerprint
        pin.deviceUuid = uuid
        pin.addresses = [address]
        pin.name = name
        pin.trusted = Date()
        file.certificates.append(pin)
        if !save() {
            unsaved.append(UnsavedPin(pin: pin, address: address))
        }
    }

    /// Whether a certificate is trusted for this printer already (same UUID or address, see `check`).
    public func knows(deviceUuid: String?, authority: String) -> Bool {
        let uuid = IppTxtRecord.uuidKey(deviceUuid) ?? ""
        let address = authority.lowercased()
        lock.lock()
        defer { lock.unlock() }
        reload()
        return file.certificates.contains(where: { IppTrustStore.samePrinter($0, uuid: uuid, address: address) })
    }

    /// The trusted certificates.
    public var certificates: [IppTrustedCertificate] {
        lock.lock()
        defer { lock.unlock() }
        return file.certificates
    }

    /// Re-reads the file (with the lock held): another window of the app may have trusted or replaced
    /// a certificate meanwhile, and writing the copy loaded earlier would undo that. Certificates
    /// trusted here that could not be saved are applied to it again. A file that cannot be loaded
    /// keeps what is in memory, unsaved pins included.
    private func reload() {
        guard var loaded = StoreFiles.load(IppTrustFile.self, from: url) else { return }
        for entry in unsaved {
            loaded.certificates.removeAll(where: {
                IppTrustStore.replaces($0, fingerprint: entry.pin.fingerprint, uuid: entry.pin.deviceUuid,
                                       address: entry.address)
            })
            loaded.certificates.append(entry.pin)
        }
        file = loaded
    }

    /// Writes the file (with the lock held); false when it could not be written.
    @discardableResult
    private func save() -> Bool {
        guard StoreFiles.write(file, to: url) else { return false }
        unsaved.removeAll()
        return true
    }

    /// Whether trusting `fingerprint` for that printer replaces `entry`.
    private static func replaces(_ entry: IppTrustedCertificate, fingerprint: String, uuid: String,
                                 address: String) -> Bool {
        entry.fingerprint == fingerprint || samePrinter(entry, uuid: uuid, address: address)
    }

    private static func samePrinter(_ entry: IppTrustedCertificate, uuid: String, address: String) -> Bool {
        if !uuid.isEmpty && !entry.deviceUuid.isEmpty {
            return entry.deviceUuid == uuid
        }
        return entry.addresses.contains(address)
    }
}

/// A printer's certificate was refused: not trusted yet, changed, or unusable. The twin of C#
/// `IppCertificateException`, with the same messages. The client throws it as it is.
public struct IppCertificateError: Error, Equatable, LocalizedError, Sendable {
    public let verdict: IppTrustVerdict
    public let deviceName: String
    /// The printer's UUID as known when connecting; nil when unknown.
    public let deviceUuid: String?
    /// "host:port" the certificate was presented at.
    public let authority: String
    /// SPKI SHA-256 of the presented certificate, lowercase hex ("" when there was none).
    public let fingerprint: String
    /// The certificate's subject as the platform names it; "" when there was none.
    public let subject: String
    /// The previously trusted certificate, for `changed`.
    public let previous: IppTrustedCertificate?

    public init(verdict: IppTrustVerdict, deviceName: String, deviceUuid: String?, authority: String,
                fingerprint: String, subject: String, previous: IppTrustedCertificate? = nil) {
        self.verdict = verdict
        self.deviceName = deviceName
        self.deviceUuid = deviceUuid
        self.authority = authority
        self.fingerprint = fingerprint
        self.subject = subject
        self.previous = previous
    }

    /// The certificate can be trusted by the user (it exists and can be pinned).
    public var canTrust: Bool {
        (verdict == .unknown || verdict == .changed) && !fingerprint.isEmpty
    }

    public var message: String {
        switch verdict {
        case .changed:
            return "The security certificate of \(deviceName) has changed since you trusted it, so Lazy Print did not connect. "
                + "A firmware update or a reset of the printer can change it, but so can another device pretending to be your printer."
        case .invalid:
            return "\(deviceName) did not present a usable security certificate, so Lazy Print did not connect."
        default:
            return "\(deviceName) uses a security certificate that has not been trusted yet, so Lazy Print did not connect."
        }
    }

    public var errorDescription: String? { message }
}

/// Fingerprints of printer certificates.
public enum IppCertificates {
    /// SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex (the key, not the whole
    /// certificate, is pinned), from the certificate's DER (`SecCertificateCopyData`); nil when the
    /// bytes are not one well-formed certificate.
    public static func fingerprint(certificateDER: Data) -> String? {
        SpkiFingerprint.of(certificateDER).map(SpkiFingerprint.hex)
    }

    /// "AB:CD:..." for people to compare; groups of `bytesPerLine` bytes per line when positive.
    public static func format(_ fingerprint: String, bytesPerLine: Int = 0) -> String {
        let characters = Array(fingerprint)
        let pairs = stride(from: 0, to: characters.count - 1, by: 2)
            .map { String(characters[$0...$0 + 1]).uppercased() }
        if bytesPerLine <= 0 {
            return pairs.joined(separator: ":")
        }
        return stride(from: 0, to: pairs.count, by: bytesPerLine)
            .map { pairs[$0..<min($0 + bytesPerLine, pairs.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }
}

/// Checks the certificates one printer presents, against `IppTrustStore`. A certificate the system
/// accepts (valid chain, matching name) is trusted as is; any other is trusted only when pinned, or,
/// for `firstUse`, provisionally until `rememberDevice`. A refusal is kept for `takeRejection`, since
/// the HTTP stack reports it only as a failed connection. Safe to use from any thread.
///
/// `firstUse` is the fingerprint of a certificate the store does not know (`unknown`) that may be used
/// to ask the printer who it is: it is accepted without being pinned, and `rememberDevice` pins it once
/// the printer's UUID shows it is not another key for a printer trusted before (trust on first use).
public final class IppCertificateValidator: @unchecked Sendable {
    /// A certificate accepted, where, and whether it was pinned or only accepted as `firstUse`.
    private struct Accepted {
        let fingerprint: String
        let authority: String
        let subject: String
        var pinned: Bool
    }

    private let store: IppTrustStore
    private let lock = NSLock()
    private var rejection: IppCertificateError?
    /// The certificate accepted last.
    private var accepted: Accepted?
    private var firstUse: String?
    private var checks = 0

    public let deviceName: String
    public let deviceUuid: String?

    public init(store: IppTrustStore, deviceUuid: String?, deviceName: String, firstUse: String? = nil) {
        self.store = store
        self.deviceUuid = deviceUuid
        self.deviceName = deviceName
        self.firstUse = firstUse
    }

    /// The TLS check for a request to `url`: `certificateDER` is the leaf certificate the printer
    /// presented (nil when none), `subject` its subject as the platform names it, and `systemTrusted`
    /// whether the system's own evaluation accepted it. A certificate whose public key cannot be found
    /// is refused as `invalid`.
    public func validate(url: URL?, certificateDER: Data?, subject: String, systemTrusted: Bool) -> Bool {
        lock.lock()
        checks += 1
        lock.unlock()
        if systemTrusted && certificateDER != nil {
            return true
        }
        let authority = url.map(IppCertificateValidator.authorityOf) ?? ""
        guard let der = certificateDER else {
            setRejection(IppCertificateError(verdict: .invalid, deviceName: deviceName, deviceUuid: deviceUuid,
                                             authority: authority, fingerprint: "", subject: ""))
            return false
        }
        guard let fingerprint = IppCertificates.fingerprint(certificateDER: der) else {
            setRejection(IppCertificateError(verdict: .invalid, deviceName: deviceName, deviceUuid: deviceUuid,
                                             authority: authority, fingerprint: "", subject: subject))
            return false
        }
        let check = store.check(fingerprint, deviceUuid: deviceUuid, authority: authority)
        lock.lock()
        let isFirstUse = check.verdict == .unknown && fingerprint == firstUse
        if check.verdict == .trusted || isFirstUse {
            accepted = Accepted(fingerprint: fingerprint, authority: authority, subject: subject,
                                pinned: check.verdict == .trusted)
            lock.unlock()
            return true
        }
        lock.unlock()
        setRejection(IppCertificateError(verdict: check.verdict, deviceName: deviceName, deviceUuid: deviceUuid,
                                         authority: authority, fingerprint: fingerprint, subject: subject,
                                         previous: check.previous))
        return false
    }

    /// Checks the certificate the printer was reached through against the UUID it reported (its
    /// capabilities). A pinned certificate learns the UUID when it did not have it yet: a certificate
    /// trusted for an address added by hand then also identifies the printer when discovery finds it.
    /// A `firstUse` certificate is pinned now, with the UUID. Throws `IppCertificateError` (`changed`,
    /// nothing pinned or learned) when another certificate is trusted for that printer.
    public func rememberDevice(_ deviceUuid: String?) throws {
        lock.lock()
        let current = accepted
        lock.unlock()
        guard let chosen = current else { return }
        if chosen.pinned && deviceUuid == nil {
            return
        }
        let uuid = deviceUuid ?? self.deviceUuid
        let check = store.check(chosen.fingerprint, deviceUuid: uuid, authority: chosen.authority)
        if check.verdict == .changed {
            throw IppCertificateError(verdict: .changed, deviceName: deviceName, deviceUuid: uuid,
                                      authority: chosen.authority, fingerprint: chosen.fingerprint,
                                      subject: chosen.subject, previous: check.previous)
        }
        if chosen.pinned {
            return
        }
        if check.verdict == .unknown {
            try store.trust(chosen.fingerprint, deviceUuid: uuid, authority: chosen.authority, name: deviceName)
        }
        var updated = chosen
        updated.pinned = true
        lock.lock()
        firstUse = nil
        accepted = updated
        lock.unlock()
    }

    /// The last refusal, cleared by reading it; nil when nothing was refused since.
    @discardableResult
    public func takeRejection() -> IppCertificateError? {
        lock.lock()
        defer { lock.unlock() }
        let taken = rejection
        rejection = nil
        return taken
    }

    /// The printer is trusted for this address or UUID already: it must not be reached without TLS.
    public func knows(authority: String) -> Bool {
        store.knows(deviceUuid: deviceUuid, authority: authority)
    }

    /// A first-use certificate is waiting for `rememberDevice` to pin it.
    public var hasPendingFirstUse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstUse != nil
    }

    /// How many certificates were checked so far: a request after which it is unchanged never reached the check.
    public var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    /// "host:port" of a request, in the form `PrinterAddress.authority` uses.
    static func authorityOf(_ url: URL) -> String {
        IppUrlText.authority(url.absoluteString)
    }

    private func setRejection(_ error: IppCertificateError) {
        lock.lock()
        rejection = error
        lock.unlock()
    }
}
