using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppTrustTests.swift: the same cases. Certificate pinning for IPP
// over TLS and the ipp-trust.json file, including trust files written by either platform
// (Tests/Fixtures/Ipp). The checks through a real TLS connection come with the client's loopback
// printer.

public sealed class IppTrustTests : IDisposable
{
    private const string Uuid = "564e4333-4230-3538-3930-a0b3cce51a2b";
    private const string OtherUuid = "cfe92100-67c4-11d4-a45f-f8d0273e1a0b";
    private readonly string _directory;

    public IppTrustTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private static X509Certificate2 SelfSigned(string subject)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={subject}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var ephemeral = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        // Reloaded from PKCS#12, as a certificate a TLS stack can serve is.
        return X509CertificateLoader.LoadPkcs12(ephemeral.Export(X509ContentType.Pfx), null);
    }

    private static string Fingerprint(int n) => new string((char)('a' + n), 64);

    // MARK: - Trust store

    [Fact]
    public void FirstUseIsUnknownThenTrustedEverywhere()
    {
        var store = new IppTrustStore(_directory);
        Assert.Equal(IppTrustVerdict.Unknown, store.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out var previous));
        Assert.Null(previous);

        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out _));
        // The pinned key is trusted at another address too (DHCP), and that address is remembered.
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(0), null, "HPA1B2C3.local:443", out _));
        var entry = Assert.Single(new IppTrustStore(_directory).Certificates);
        Assert.Equal(Fingerprint(0), entry.Fingerprint);
        Assert.Equal("564e4333423035383930a0b3cce51a2b", entry.DeviceUuid);
        Assert.Equal(["192.168.1.20:443", "hpa1b2c3.local:443"], entry.Addresses);
        Assert.Equal("HP M479", entry.Name);
        Assert.NotNull(entry.Trusted);
    }

    [Fact]
    public void ANewKeyForATrustedPrinterIsAChange()
    {
        var store = new IppTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");

        // Same UUID, anywhere.
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(1), Uuid.ToUpperInvariant(), "10.0.0.5:443", out var previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);
        // Same address, UUID unknown (an address added by hand).
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(1), null, "192.168.1.20:443", out _));
        // Same address but another printer's UUID: a different device took the address.
        Assert.Equal(IppTrustVerdict.Unknown, store.Check(Fingerprint(1), OtherUuid, "192.168.1.20:443", out _));
        // Another port is another endpoint.
        Assert.Equal(IppTrustVerdict.Unknown, store.Check(Fingerprint(1), null, "192.168.1.20:8443", out _));
        Assert.Equal(IppTrustVerdict.Invalid, store.Check("", Uuid, "192.168.1.20:443", out _));
    }

    [Fact]
    public void TrustingTheNewKeyReplacesTheOldOne()
    {
        var store = new IppTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        store.Trust(Fingerprint(5), null, "10.0.0.9:443", "Other printer");
        store.Trust(Fingerprint(1), Uuid, "192.168.1.20:443", "HP M479");

        var reloaded = new IppTrustStore(_directory);
        Assert.Equal([Fingerprint(5), Fingerprint(1)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(IppTrustVerdict.Trusted, reloaded.Check(Fingerprint(1), Uuid, "192.168.1.20:443", out _));
        Assert.Equal(IppTrustVerdict.Changed, reloaded.Check(Fingerprint(0), Uuid, "192.168.1.20:443", out _));
        Assert.Throws<ArgumentException>(() => reloaded.Trust("", Uuid, "x:1", "x"));
    }

    [Fact]
    public void LearningAnAddressKeepsWhatAnotherWindowTrusted()
    {
        const string printerS = "192.168.1.20:443", printerY = "192.168.1.30:443";
        var setup = new IppTrustStore(_directory);
        setup.Trust(Fingerprint(0), Uuid, printerS, "S");
        setup.Trust(Fingerprint(3), OtherUuid, printerY, "Y");

        // Two windows of the app, each with the file as it was when it started.
        var windowA = new IppTrustStore(_directory);
        var windowB = new IppTrustStore(_directory);
        // B trusts S's new certificate, and a printer A has never seen.
        windowB.Trust(Fingerprint(1), Uuid, printerS, "S");
        windowB.Trust(Fingerprint(4), null, "10.0.0.7:443", "X");

        // A reaches Y at a new address (DHCP): the address is learned without undoing B's changes.
        Assert.Equal(IppTrustVerdict.Trusted, windowA.Check(Fingerprint(3), OtherUuid, "192.168.1.31:443", out _));
        var reloaded = new IppTrustStore(_directory);
        Assert.Equal([Fingerprint(3), Fingerprint(1), Fingerprint(4)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(["192.168.1.30:443", "192.168.1.31:443"],
                     reloaded.Certificates.Single(c => c.Fingerprint == Fingerprint(3)).Addresses);

        // A also sees B's pins: S's new key is trusted, the old one is a change.
        var windowA2 = new IppTrustStore(_directory);
        var stale = new IppTrustStore(_directory);
        windowB.Trust(Fingerprint(2), Uuid, printerS, "S");
        Assert.Equal(IppTrustVerdict.Trusted, stale.Check(Fingerprint(2), Uuid, printerS, out _));
        Assert.Equal(IppTrustVerdict.Changed, windowA2.Check(Fingerprint(1), Uuid, printerS, out var previous));
        Assert.Equal(Fingerprint(2), previous?.Fingerprint);
        Assert.Equal(IppTrustVerdict.Trusted, windowA.Check(Fingerprint(4), null, "10.0.0.7:443", out _));
    }

    [Fact]
    public void APinnedKeyDoesNotVouchForAnotherPrintersUuid()
    {
        var store = new IppTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");
        // Pinned for an address added by hand, the printer's UUID not known yet.
        store.Trust(Fingerprint(1), null, "hp.local:443", "hp.local");
        store.Trust(Fingerprint(2), OtherUuid, "10.0.0.9:443", "Other");

        // The key pinned by address claims the trusted printer's UUID: a change, nothing learned.
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(1), Uuid, "hp.local:443", out var previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);
        Assert.Equal("", new IppTrustStore(_directory).Certificates.Single(c => c.Fingerprint == Fingerprint(1)).DeviceUuid);
        // Another printer's key claiming it, at the trusted printer's own address too.
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(2), Uuid, "192.168.1.20:443", out previous));
        Assert.Equal(Fingerprint(0), previous?.Fingerprint);

        // Without a UUID, or with its own, a pinned key is still trusted anywhere.
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(1), null, "hp.local:443", out _));
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(2), OtherUuid, "10.0.0.10:443", out _));
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(0), Uuid, "10.0.0.11:443", out _));
        // A UUID nobody holds is learned.
        const string ThirdUuid = "e3248000-80ce-11db-8000-30055c773bcf";
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(1), ThirdUuid, "hp.local:443", out _));
        Assert.Equal("e324800080ce11db800030055c773bcf",
                     new IppTrustStore(_directory).Certificates.Single(c => c.Fingerprint == Fingerprint(1)).DeviceUuid);

        // Trusting the key for the printer it claims replaces that printer's pin.
        store.Trust(Fingerprint(2), Uuid, "192.168.1.20:443", "HP M479");
        Assert.Equal([Fingerprint(1), Fingerprint(2)], new IppTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
    }

    [Fact]
    public void TrustedCertificatesStayTrustedWhenTheFileCannotBeWritten()
    {
        string path = Path.Combine(_directory, "ipp-trust.json");
        var store = new IppTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "S");

        // Writes fail from here on (the temporary file cannot be created); the file still reads.
        Directory.CreateDirectory(path + ".tmp");
        store.Trust(Fingerprint(1), OtherUuid, "192.168.1.30:443", "Y");
        Assert.Equal([Fingerprint(0)], new IppTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out _));
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(1), null, "192.168.1.31:443", out _));
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(5), OtherUuid, "10.0.0.5:443", out var previous));
        Assert.Equal(Fingerprint(1), previous?.Fingerprint);

        // Another window changes the file meanwhile: its pins count, and the unsaved one is kept.
        File.WriteAllText(path, $$"""
            {"certificates": [
              {"fingerprint": "{{Fingerprint(0)}}", "deviceUuid": "564e4333423035383930a0b3cce51a2b", "addresses": ["192.168.1.20:443"], "name": "S"},
              {"fingerprint": "{{Fingerprint(4)}}", "deviceUuid": "", "addresses": ["10.0.0.7:443"], "name": "X"}
            ]}
            """);
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(4), null, "10.0.0.7:443", out _));
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out _));

        // A later trust for the same printer replaces the unsaved one, which does not come back.
        store.Trust(Fingerprint(2), OtherUuid, "192.168.1.30:443", "Y");
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(1), OtherUuid, "192.168.1.30:443", out previous));
        Assert.Equal(Fingerprint(2), previous?.Fingerprint);

        // Once the file can be written, the next write saves what was not saved.
        Directory.Delete(path + ".tmp");
        Assert.Equal(IppTrustVerdict.Trusted, store.Check(Fingerprint(2), OtherUuid, "192.168.1.32:443", out _));
        var reloaded = new IppTrustStore(_directory);
        Assert.Equal([Fingerprint(0), Fingerprint(4), Fingerprint(2)], reloaded.Certificates.Select(c => c.Fingerprint));
        Assert.Equal(["192.168.1.30:443", "192.168.1.32:443"],
                     reloaded.Certificates.Single(c => c.Fingerprint == Fingerprint(2)).Addresses);
    }

    [Fact]
    public void AnUndecodableTrustFileIsKeptAside()
    {
        string path = Path.Combine(_directory, "ipp-trust.json");
        File.WriteAllText(path, "{ not json");
        var store = new IppTrustStore(_directory);
        Assert.Empty(store.Certificates);
        Assert.Single(Directory.GetFiles(_directory, "ipp-trust.unreadable-*.json"));

        // A field of the wrong type resets only that field.
        File.WriteAllText(path, $$"""
            {"certificates": [{"fingerprint": "{{Fingerprint(2)}}", "deviceUuid": 42, "addresses": ["a:1"], "name": "Kept"}]}
            """);
        var entry = Assert.Single(new IppTrustStore(_directory).Certificates);
        Assert.Equal(Fingerprint(2), entry.Fingerprint);
        Assert.Equal("", entry.DeviceUuid);
        Assert.Equal("Kept", entry.Name);
    }

    [Fact]
    public void TrustFilesFromEitherPlatformLoad()
    {
        const string p256 = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4";
        const string rsa = "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c";
        foreach (string name in new[] { "ipp-trust-windows.json", "ipp-trust-apple.json" })
        {
            string directory = Path.Combine(_directory, name);
            Directory.CreateDirectory(directory);
            File.Copy(IppFixtures.PathOf(name), Path.Combine(directory, "ipp-trust.json"));
            var store = new IppTrustStore(directory);
            Assert.Equal([p256, rsa], store.Certificates.Select(c => c.Fingerprint));
            var printer = store.Certificates[0];
            Assert.Equal("564e4333423035383930a0b3cce51a2b", printer.DeviceUuid);
            Assert.Equal(["192.168.1.20:443", "hpa1b2c3.local:443"], printer.Addresses);
            Assert.Equal("HP Color LaserJet MFP M479fdw", printer.Name);
            var byAddress = store.Certificates[1];
            Assert.Equal("", byAddress.DeviceUuid);
            Assert.Equal(["[fe80::1%12]:443"], byAddress.Addresses);
            Assert.Equal("fe80::1%12", byAddress.Name);
            // Each platform writes the date its own way; the other platform's reads as unknown.
            if (name == "ipp-trust-windows.json")
            {
                Assert.Equal(DateTimeOffset.Parse("2026-10-21T14:26:48.7107503-04:00", System.Globalization.CultureInfo.InvariantCulture),
                             printer.Trusted);
            }
            else
            {
                Assert.Null(printer.Trusted);
            }
            Assert.Empty(Directory.GetFiles(directory, "ipp-trust.unreadable-*.json"));
            Assert.Equal(IppTrustVerdict.Trusted, store.Check(p256, Uuid.ToUpperInvariant(), "10.0.0.20:443", out _));
            Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(1), null, "[fe80::1%12]:443", out var previous));
            Assert.Equal(rsa, previous?.Fingerprint);
        }
    }

    [Fact]
    public void FingerprintsArePublicKeyHashesFormattedForPeople()
    {
        using var certificate = SelfSigned("FakePrinter");
        string fingerprint = IppCertificates.Fingerprint(certificate);
        Assert.Equal(64, fingerprint.Length);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo())), fingerprint);
        foreach (var (file, expected, _) in IppFixtures.Certificates)
        {
            using var shared = IppFixtures.Certificate(file);
            Assert.Equal(expected, IppCertificates.Fingerprint(shared));
        }
        Assert.Equal("AB:CD:01", IppCertificates.Format("abcd01"));
        Assert.Equal("AA:BB\nCC", IppCertificates.Format("aabbcc", bytesPerLine: 2));
    }

    // MARK: - Validator

    [Fact]
    public void TheValidatorTrustsWindowsValidCertificatesAndPinnedOnes()
    {
        using var certificate = SelfSigned("FakePrinter");
        var store = new IppTrustStore(_directory);
        var validator = new IppCertificateValidator(store, Uuid, "Fake MFP");
        var uri = new Uri("https://192.168.1.20/ipp/print");

        Assert.True(validator.Validate(uri, certificate, SslPolicyErrors.None));
        Assert.Null(validator.TakeRejection());

        Assert.False(validator.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        var rejection = validator.TakeRejection();
        Assert.NotNull(rejection);
        Assert.Equal(IppTrustVerdict.Unknown, rejection.Verdict);
        Assert.True(rejection.CanTrust);
        Assert.Equal("192.168.1.20:443", rejection.Authority);
        Assert.Equal("CN=FakePrinter", rejection.Subject);
        Assert.Equal(IppCertificates.Fingerprint(certificate), rejection.Fingerprint);
        Assert.Equal("Fake MFP uses a security certificate that has not been trusted yet, so Lazy Print did not connect.",
                     rejection.Message);
        Assert.Null(validator.TakeRejection()); // taken once

        store.Trust(rejection.Fingerprint, rejection.DeviceUuid, rejection.Authority, "Fake MFP");
        Assert.True(validator.Validate(uri, certificate,
                                       SslPolicyErrors.RemoteCertificateChainErrors | SslPolicyErrors.RemoteCertificateNameMismatch));

        Assert.False(validator.Validate(uri, null, SslPolicyErrors.RemoteCertificateNotAvailable));
        var missing = validator.TakeRejection()!;
        Assert.Equal(IppTrustVerdict.Invalid, missing.Verdict);
        Assert.False(missing.CanTrust);
    }

    [Fact]
    public void APinMadeByAddressLearnsThePrintersUuid()
    {
        using var certificate = SelfSigned("FakePrinter");
        var store = new IppTrustStore(_directory);
        string fingerprint = IppCertificates.Fingerprint(certificate);
        store.Trust(fingerprint, null, "10.0.0.7:443", "10.0.0.7");
        var validator = new IppCertificateValidator(store, deviceUuid: null, "10.0.0.7");
        validator.RememberDevice(Uuid); // nothing accepted yet: nothing to learn
        Assert.Equal("", Assert.Single(store.Certificates).DeviceUuid);

        Assert.True(validator.Validate(new Uri("https://10.0.0.7/ipp/print"), certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        validator.RememberDevice(Uuid);
        Assert.Equal("564e4333423035383930a0b3cce51a2b", Assert.Single(new IppTrustStore(_directory).Certificates).DeviceUuid);
        // Discovery later finds the printer by its UUID at another address, with another key.
        Assert.Equal(IppTrustVerdict.Changed, store.Check(Fingerprint(3), Uuid, "192.168.1.20:443", out _));
    }

    [Fact]
    public void TheValidatorPinsAFirstUseCertificateOnlyOnceItsUuidIsChecked()
    {
        using var certificate = IppFixtures.Certificate("certificate-p256.pem");
        string presented = IppCertificates.Fingerprint(certificate);
        var uri = new Uri("https://10.0.0.30/ipp/print");
        var store = new IppTrustStore(_directory);
        store.Trust(Fingerprint(0), Uuid, "192.168.1.20:443", "HP M479");

        // Not the certificate allowed for first use: refused.
        var other = new IppCertificateValidator(store, null, "10.0.0.30", firstUse: Fingerprint(7));
        Assert.False(other.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.Equal(IppTrustVerdict.Unknown, other.TakeRejection()?.Verdict);

        // The first-use certificate is accepted without being pinned; it claims the trusted printer's
        // UUID, so it is a change and stays unpinned.
        var claims = new IppCertificateValidator(store, null, "10.0.0.30", firstUse: presented);
        Assert.True(claims.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.Equal([Fingerprint(0)], store.Certificates.Select(c => c.Fingerprint));
        var changed = Assert.Throws<IppCertificateException>(() => claims.RememberDevice(Uuid));
        Assert.Equal(IppTrustVerdict.Changed, changed.Verdict);
        Assert.Equal(Fingerprint(0), changed.Previous?.Fingerprint);
        Assert.Equal(presented, changed.Fingerprint);
        Assert.Equal("10.0.0.30:443", changed.Authority);
        Assert.True(changed.CanTrust);
        Assert.Equal([Fingerprint(0)], new IppTrustStore(_directory).Certificates.Select(c => c.Fingerprint));

        // A printer nobody trusted: pinned with its UUID once it answered.
        var fresh = new IppCertificateValidator(store, null, "10.0.0.30", firstUse: presented);
        Assert.True(fresh.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        fresh.RememberDevice(OtherUuid);
        var pin = new IppTrustStore(_directory).Certificates.Single(c => c.Fingerprint == presented);
        Assert.Equal("cfe9210067c411d4a45ff8d0273e1a0b", pin.DeviceUuid);
        Assert.Equal(["10.0.0.30:443"], pin.Addresses);
        // Pinned now: the same validator accepts it as a pinned key, and nothing changes.
        Assert.True(fresh.Validate(uri, certificate, SslPolicyErrors.RemoteCertificateChainErrors));
        fresh.RememberDevice(OtherUuid);
        Assert.Equal([Fingerprint(0), presented], new IppTrustStore(_directory).Certificates.Select(c => c.Fingerprint));
    }

    [Fact]
    public void AuthoritiesMatchTheAddressForm()
    {
        Assert.Equal("[fe80::1%12]:8631",
                     IppCertificateValidator.AuthorityOf(PrinterAddress.Parse("[fe80::1%12]:8631").RequestUri));
        Assert.Equal("printer.local:443", IppCertificateValidator.AuthorityOf(new Uri("https://Printer.Local/ipp/print")));
        Assert.Equal(PrinterAddress.Parse("ipps://10.0.0.7:8443").Authority,
                     IppCertificateValidator.AuthorityOf(PrinterAddress.Parse("ipps://10.0.0.7:8443").RequestUri));
    }
}
