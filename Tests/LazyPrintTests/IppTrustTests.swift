import XCTest
@testable import LazyPrintKit

// Mirrors windows/LazyPrint.Core.Tests/IppTrustTests.cs: the same cases. Certificate pinning for IPP
// over TLS and the ipp-trust.json file, including trust files written by either platform
// (Tests/Fixtures/Ipp). The checks through a real TLS connection come with the client's loopback
// printer. The validator gets a certificate's DER, its subject and the system's verdict, where the C#
// one gets an X509Certificate2 and SslPolicyErrors, so the certificates here are the shared fixtures
// and not ones made on the spot; the file that cannot be written is made so by a read-only folder.

final class IppTrustTests: XCTestCase {
    private let uuid = "564e4333-4230-3538-3930-a0b3cce51a2b"
    private let otherUuid = "cfe92100-67c4-11d4-a45f-f8d0273e1a0b"
    private let fakePrinterSubject = "CN=FakePrinter"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LazyPrintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> IppTrustStore {
        IppTrustStore(directory: directory)
    }

    private var trustFileURL: URL { directory.appendingPathComponent(IppTrustStore.fileName) }

    /// A made-up fingerprint: 64 times the letter n places after "a".
    private func fingerprint(_ n: Int) -> String {
        String(repeating: String(Character(Unicode.Scalar(UInt8(97 + n)))), count: 64)
    }

    private func fingerprints(_ certificates: [IppTrustedCertificate]) -> [String] {
        certificates.map { $0.fingerprint }
    }

    private func entry(_ certificates: [IppTrustedCertificate], _ fingerprint: String) -> IppTrustedCertificate? {
        certificates.first { $0.fingerprint == fingerprint }
    }

    private func files(in folder: URL, withPrefix prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
    }

    // MARK: - Trust store

    func testFirstUseIsUnknownThenTrustedEverywhere() throws {
        let store = makeStore()
        let first = store.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443")
        XCTAssertEqual(first.verdict, .unknown)
        XCTAssertNil(first.previous)

        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .trusted)
        // The pinned key is trusted at another address too (DHCP), and that address is remembered.
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: nil, authority: "HPA1B2C3.local:443").verdict, .trusted)
        let certificates = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        let pinned = try XCTUnwrap(certificates.first)
        XCTAssertEqual(pinned.fingerprint, fingerprint(0))
        XCTAssertEqual(pinned.deviceUuid, "564e4333423035383930a0b3cce51a2b")
        XCTAssertEqual(pinned.addresses, ["192.168.1.20:443", "hpa1b2c3.local:443"])
        XCTAssertEqual(pinned.name, "HP M479")
        XCTAssertNotNil(pinned.trusted)
    }

    func testANewKeyForATrustedPrinterIsAChange() throws {
        let store = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        // Same UUID, anywhere.
        let sameUuid = store.check(fingerprint(1), deviceUuid: uuid.uppercased(), authority: "10.0.0.5:443")
        XCTAssertEqual(sameUuid.verdict, .changed)
        XCTAssertEqual(sameUuid.previous?.fingerprint, fingerprint(0))
        // Same address, UUID unknown (an address added by hand).
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.20:443").verdict, .changed)
        // Same address but another printer's UUID: a different device took the address.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.20:443").verdict, .unknown)
        // Another port is another endpoint.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.20:8443").verdict, .unknown)
        XCTAssertEqual(store.check("", deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .invalid)
    }

    func testTrustingTheNewKeyReplacesTheOldOne() throws {
        let store = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        try store.trust(fingerprint(5), deviceUuid: nil, authority: "10.0.0.9:443", name: "Other printer")
        try store.trust(fingerprint(1), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        let reloaded = makeStore()
        XCTAssertEqual(fingerprints(reloaded.certificates), [fingerprint(5), fingerprint(1)])
        XCTAssertEqual(reloaded.check(fingerprint(1), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .trusted)
        XCTAssertEqual(reloaded.check(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .changed)
        XCTAssertThrowsError(try reloaded.trust("", deviceUuid: uuid, authority: "x:1", name: "x")) { error in
            XCTAssertEqual(error as? IppTrustStoreError, .noCertificate)
        }
    }

    func testLearningAnAddressKeepsWhatAnotherWindowTrusted() throws {
        let printerS = "192.168.1.20:443"
        let printerY = "192.168.1.30:443"
        let setup = makeStore()
        try setup.trust(fingerprint(0), deviceUuid: uuid, authority: printerS, name: "S")
        try setup.trust(fingerprint(3), deviceUuid: otherUuid, authority: printerY, name: "Y")

        // Two windows of the app, each with the file as it was when it started.
        let windowA = makeStore()
        let windowB = makeStore()
        // B trusts S's new certificate, and a printer A has never seen.
        try windowB.trust(fingerprint(1), deviceUuid: uuid, authority: printerS, name: "S")
        try windowB.trust(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443", name: "X")

        // A reaches Y at a new address (DHCP): the address is learned without undoing B's changes.
        XCTAssertEqual(windowA.check(fingerprint(3), deviceUuid: otherUuid, authority: "192.168.1.31:443").verdict, .trusted)
        let reloaded = makeStore().certificates
        XCTAssertEqual(fingerprints(reloaded), [fingerprint(3), fingerprint(1), fingerprint(4)])
        XCTAssertEqual(entry(reloaded, fingerprint(3))?.addresses, ["192.168.1.30:443", "192.168.1.31:443"])

        // A also sees B's pins: S's new key is trusted, the old one is a change.
        let windowA2 = makeStore()
        let stale = makeStore()
        try windowB.trust(fingerprint(2), deviceUuid: uuid, authority: printerS, name: "S")
        XCTAssertEqual(stale.check(fingerprint(2), deviceUuid: uuid, authority: printerS).verdict, .trusted)
        let old = windowA2.check(fingerprint(1), deviceUuid: uuid, authority: printerS)
        XCTAssertEqual(old.verdict, .changed)
        XCTAssertEqual(old.previous?.fingerprint, fingerprint(2))
        XCTAssertEqual(windowA.check(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443").verdict, .trusted)
    }

    func testAPinnedKeyDoesNotVouchForAnotherPrintersUuid() throws {
        let store = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        // Pinned for an address added by hand, the printer's UUID not known yet.
        try store.trust(fingerprint(1), deviceUuid: nil, authority: "hp.local:443", name: "hp.local")
        try store.trust(fingerprint(2), deviceUuid: otherUuid, authority: "10.0.0.9:443", name: "Other")

        // The key pinned by address claims the trusted printer's UUID: a change, nothing learned.
        var check = store.check(fingerprint(1), deviceUuid: uuid, authority: "hp.local:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(0))
        XCTAssertEqual(entry(makeStore().certificates, fingerprint(1))?.deviceUuid, "")
        // Another printer's key claiming it, at the trusted printer's own address too.
        check = store.check(fingerprint(2), deviceUuid: uuid, authority: "192.168.1.20:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(0))

        // Without a UUID, or with its own, a pinned key is still trusted anywhere.
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "hp.local:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(2), deviceUuid: otherUuid, authority: "10.0.0.10:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(0), deviceUuid: uuid, authority: "10.0.0.11:443").verdict, .trusted)
        // A UUID nobody holds is learned.
        let thirdUuid = "e3248000-80ce-11db-8000-30055c773bcf"
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: thirdUuid, authority: "hp.local:443").verdict, .trusted)
        XCTAssertEqual(entry(makeStore().certificates, fingerprint(1))?.deviceUuid, "e324800080ce11db800030055c773bcf")

        // Trusting the key for the printer it claims replaces that printer's pin.
        try store.trust(fingerprint(2), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(1), fingerprint(2)])
    }

    func testTrustedCertificatesStayTrustedWhenTheFileCannotBeWritten() throws {
        let store = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "S")

        // Writes fail from here on (the folder takes no new files, so the file cannot be replaced); the
        // file still reads. C# makes its temporary file's name a folder instead; Foundation's atomic
        // write picks its own temporary file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path),
                      "The tests run with permissions that ignore a read-only folder.")
        try store.trust(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443", name: "Y")
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0)])
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: nil, authority: "192.168.1.31:443").verdict, .trusted)
        var check = store.check(fingerprint(5), deviceUuid: otherUuid, authority: "10.0.0.5:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(1))

        // Another window changes the file meanwhile: its pins count, and the unsaved one is kept.
        let changedFile = """
            {"certificates": [
              {"fingerprint": "\(fingerprint(0))", "deviceUuid": "564e4333423035383930a0b3cce51a2b", "addresses": ["192.168.1.20:443"], "name": "S"},
              {"fingerprint": "\(fingerprint(4))", "deviceUuid": "", "addresses": ["10.0.0.7:443"], "name": "X"}
            ]}
            """
        try changedFile.write(to: trustFileURL, atomically: false, encoding: .utf8)
        XCTAssertEqual(store.check(fingerprint(4), deviceUuid: nil, authority: "10.0.0.7:443").verdict, .trusted)
        XCTAssertEqual(store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443").verdict, .trusted)

        // A later trust for the same printer replaces the unsaved one, which does not come back.
        try store.trust(fingerprint(2), deviceUuid: otherUuid, authority: "192.168.1.30:443", name: "Y")
        check = store.check(fingerprint(1), deviceUuid: otherUuid, authority: "192.168.1.30:443")
        XCTAssertEqual(check.verdict, .changed)
        XCTAssertEqual(check.previous?.fingerprint, fingerprint(2))

        // Once the file can be written, the next write saves what was not saved.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertEqual(store.check(fingerprint(2), deviceUuid: otherUuid, authority: "192.168.1.32:443").verdict, .trusted)
        let reloaded = makeStore().certificates
        XCTAssertEqual(fingerprints(reloaded), [fingerprint(0), fingerprint(4), fingerprint(2)])
        XCTAssertEqual(entry(reloaded, fingerprint(2))?.addresses, ["192.168.1.30:443", "192.168.1.32:443"])
    }

    func testAnUndecodableTrustFileIsKeptAside() throws {
        try "{ not json".write(to: trustFileURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertTrue(store.certificates.isEmpty)
        XCTAssertEqual(try files(in: directory, withPrefix: "ipp-trust.unreadable-").count, 1)

        // A field of the wrong type resets only that field.
        let text = """
            {"certificates": [{"fingerprint": "\(fingerprint(2))", "deviceUuid": 42, "addresses": ["a:1"], "name": "Kept"}]}
            """
        try text.write(to: trustFileURL, atomically: true, encoding: .utf8)
        let certificates = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        let kept = try XCTUnwrap(certificates.first)
        XCTAssertEqual(kept.fingerprint, fingerprint(2))
        XCTAssertEqual(kept.deviceUuid, "")
        XCTAssertEqual(kept.name, "Kept")
    }

    func testTrustFilesFromEitherPlatformLoad() throws {
        let p256 = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4"
        let rsa = "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c"
        for name in ["ipp-trust-windows.json", "ipp-trust-apple.json"] {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: IppFixtures.url(name), to: folder.appendingPathComponent(IppTrustStore.fileName))
            let store = IppTrustStore(directory: folder)
            let certificates = store.certificates
            XCTAssertEqual(fingerprints(certificates), [p256, rsa], name)
            guard certificates.count == 2 else { continue }
            let printer = certificates[0]
            XCTAssertEqual(printer.deviceUuid, "564e4333423035383930a0b3cce51a2b", name)
            XCTAssertEqual(printer.addresses, ["192.168.1.20:443", "hpa1b2c3.local:443"], name)
            XCTAssertEqual(printer.name, "HP Color LaserJet MFP M479fdw", name)
            let byAddress = certificates[1]
            XCTAssertEqual(byAddress.deviceUuid, "", name)
            XCTAssertEqual(byAddress.addresses, ["[fe80::1%12]:443"], name)
            XCTAssertEqual(byAddress.name, "fe80::1%12", name)
            // Each platform writes the date its own way; the other platform's reads as unknown.
            if name == "ipp-trust-apple.json" {
                XCTAssertEqual(printer.trusted, Date(timeIntervalSinceReferenceDate: 814_300_008.71075), name)
            } else {
                XCTAssertNil(printer.trusted, name)
            }
            XCTAssertEqual(try files(in: folder, withPrefix: "ipp-trust.unreadable-"), [], name)
            XCTAssertEqual(store.check(p256, deviceUuid: uuid.uppercased(), authority: "10.0.0.20:443").verdict, .trusted, name)
            let changed = store.check(fingerprint(1), deviceUuid: nil, authority: "[fe80::1%12]:443")
            XCTAssertEqual(changed.verdict, .changed, name)
            XCTAssertEqual(changed.previous?.fingerprint, rsa, name)
        }
    }

    func testFingerprintsArePublicKeyHashesFormattedForPeople() throws {
        for vector in IppFixtures.certificates {
            let der = try IppFixtures.certificateDER(vector.file)
            let value = try XCTUnwrap(IppCertificates.fingerprint(certificateDER: der), vector.file)
            XCTAssertEqual(value.count, 64, vector.file)
            XCTAssertEqual(value, vector.fingerprint, vector.file)
        }
        XCTAssertNil(IppCertificates.fingerprint(certificateDER: Data([0x30, 0x00])))
        XCTAssertEqual(IppCertificates.format("abcd01"), "AB:CD:01")
        XCTAssertEqual(IppCertificates.format("aabbcc", bytesPerLine: 2), "AA:BB\nCC")
    }

    // MARK: - Validator

    func testTheValidatorTrustsWindowsValidCertificatesAndPinnedOnes() throws {
        // "Windows valid" in the C# name: here, valid for the system's own evaluation.
        let der = try IppFixtures.certificateDER("certificate-p256.pem")
        let store = makeStore()
        let validator = IppCertificateValidator(store: store, deviceUuid: uuid, deviceName: "Fake MFP")
        let url = try XCTUnwrap(URL(string: "https://192.168.1.20/ipp/print"))

        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: true))
        XCTAssertNil(validator.takeRejection())

        XCTAssertFalse(validator.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        let rejection = try XCTUnwrap(validator.takeRejection())
        XCTAssertEqual(rejection.verdict, .unknown)
        XCTAssertTrue(rejection.canTrust)
        XCTAssertEqual(rejection.authority, "192.168.1.20:443")
        XCTAssertEqual(rejection.subject, "CN=FakePrinter")
        XCTAssertEqual(rejection.fingerprint, IppCertificates.fingerprint(certificateDER: der))
        XCTAssertEqual(rejection.message,
                       "Fake MFP uses a security certificate that has not been trusted yet, so Lazy Print did not connect.")
        XCTAssertNil(validator.takeRejection())   // taken once

        try store.trust(rejection.fingerprint, deviceUuid: rejection.deviceUuid, authority: rejection.authority, name: "Fake MFP")
        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))

        XCTAssertFalse(validator.validate(url: url, certificateDER: nil, subject: "", systemTrusted: false))
        let missing = try XCTUnwrap(validator.takeRejection())
        XCTAssertEqual(missing.verdict, .invalid)
        XCTAssertFalse(missing.canTrust)
        // Bytes that are not a certificate cannot be pinned either.
        XCTAssertFalse(validator.validate(url: url, certificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x00]),
                                          subject: "", systemTrusted: false))
        XCTAssertEqual(validator.takeRejection()?.verdict, .invalid)
    }

    func testAPinMadeByAddressLearnsThePrintersUuid() throws {
        let der = try IppFixtures.certificateDER("certificate-p256.pem")
        let store = makeStore()
        let pinned = try XCTUnwrap(IppCertificates.fingerprint(certificateDER: der))
        try store.trust(pinned, deviceUuid: nil, authority: "10.0.0.7:443", name: "10.0.0.7")
        let validator = IppCertificateValidator(store: store, deviceUuid: nil, deviceName: "10.0.0.7")
        try validator.rememberDevice(uuid)   // nothing accepted yet: nothing to learn
        XCTAssertEqual(store.certificates.count, 1)
        XCTAssertEqual(store.certificates.first?.deviceUuid, "")

        let url = try XCTUnwrap(URL(string: "https://10.0.0.7/ipp/print"))
        XCTAssertTrue(validator.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        try validator.rememberDevice(uuid)
        let certificates = makeStore().certificates
        XCTAssertEqual(certificates.count, 1)
        XCTAssertEqual(certificates.first?.deviceUuid, "564e4333423035383930a0b3cce51a2b")
        // Discovery later finds the printer by its UUID at another address, with another key.
        XCTAssertEqual(store.check(fingerprint(3), deviceUuid: uuid, authority: "192.168.1.20:443").verdict, .changed)
    }

    func testTheValidatorPinsAFirstUseCertificateOnlyOnceItsUuidIsChecked() throws {
        let der = try IppFixtures.certificateDER("certificate-p256.pem")
        let presented = try XCTUnwrap(IppCertificates.fingerprint(certificateDER: der))
        let url = try XCTUnwrap(URL(string: "https://10.0.0.30/ipp/print"))
        let store = makeStore()
        try store.trust(fingerprint(0), deviceUuid: uuid, authority: "192.168.1.20:443", name: "HP M479")

        // Not the certificate allowed for first use: refused.
        let other = IppCertificateValidator(store: store, deviceUuid: nil, deviceName: "10.0.0.30", firstUse: fingerprint(7))
        XCTAssertFalse(other.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        XCTAssertEqual(other.takeRejection()?.verdict, .unknown)

        // The first-use certificate is accepted without being pinned; it claims the trusted printer's
        // UUID, so it is a change and stays unpinned.
        let claims = IppCertificateValidator(store: store, deviceUuid: nil, deviceName: "10.0.0.30", firstUse: presented)
        XCTAssertTrue(claims.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        XCTAssertEqual(fingerprints(store.certificates), [fingerprint(0)])
        XCTAssertThrowsError(try claims.rememberDevice(uuid)) { error in
            guard let changed = error as? IppCertificateError else {
                XCTFail("Not a certificate error: \(error)")
                return
            }
            XCTAssertEqual(changed.verdict, .changed)
            XCTAssertEqual(changed.previous?.fingerprint, self.fingerprint(0))
            XCTAssertEqual(changed.fingerprint, presented)
            XCTAssertEqual(changed.authority, "10.0.0.30:443")
            XCTAssertTrue(changed.canTrust)
        }
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0)])

        // A printer nobody trusted: pinned with its UUID once it answered.
        let fresh = IppCertificateValidator(store: store, deviceUuid: nil, deviceName: "10.0.0.30", firstUse: presented)
        XCTAssertTrue(fresh.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        try fresh.rememberDevice(otherUuid)
        let pin = try XCTUnwrap(entry(makeStore().certificates, presented))
        XCTAssertEqual(pin.deviceUuid, "cfe9210067c411d4a45ff8d0273e1a0b")
        XCTAssertEqual(pin.addresses, ["10.0.0.30:443"])
        // Pinned now: the same validator accepts it as a pinned key, and nothing changes.
        XCTAssertTrue(fresh.validate(url: url, certificateDER: der, subject: fakePrinterSubject, systemTrusted: false))
        try fresh.rememberDevice(otherUuid)
        XCTAssertEqual(fingerprints(makeStore().certificates), [fingerprint(0), presented])
    }

    func testAuthoritiesMatchTheAddressForm() throws {
        let zoned = try PrinterAddress.parse("[fe80::1%12]:8631")
        XCTAssertEqual(IppUrlText.authority(zoned.requestURLText), "[fe80::1%12]:8631")
        let named = try XCTUnwrap(URL(string: "https://Printer.Local/ipp/print"))
        XCTAssertEqual(IppCertificateValidator.authorityOf(named), "printer.local:443")
        let address = try PrinterAddress.parse("ipps://10.0.0.7:8443")
        let request = try XCTUnwrap(address.requestURL)
        XCTAssertEqual(IppCertificateValidator.authorityOf(request), address.authority)
    }
}
