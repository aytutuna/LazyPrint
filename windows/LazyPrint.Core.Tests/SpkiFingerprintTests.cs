using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/SpkiFingerprintTests.swift: the same vectors, from the
// certificates in Tests/Fixtures/Ipp. C#-only case: MatchesDotNetSubjectPublicKeyInfo (makes
// certificates with CertificateRequest, which Swift lacks).

public class SpkiFingerprintTests
{
    private const string P256File = "certificate-p256.pem";
    private const string P256Fingerprint = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4";
    private const string P256Text = "gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ";
    private const string P256CheckCode = "218140";

    private static byte[] Fingerprint => Convert.FromHexString(P256Fingerprint);

    [Fact]
    public void SharedCertificates_HaveTheSharedFingerprints()
    {
        // RSA-2048, P-256 and P-384, the key types printers use.
        foreach (var (file, fingerprint, subject) in IppFixtures.Certificates)
        {
            byte[] der = IppFixtures.CertificateDer(file);
            var digest = SpkiFingerprint.Of(der);
            Assert.NotNull(digest);
            Assert.Equal(fingerprint, SpkiFingerprint.Hex(digest));
            using var certificate = IppFixtures.Certificate(file);
            Assert.Equal(subject, certificate.Subject);
            Assert.Equal(certificate.PublicKey.ExportSubjectPublicKeyInfo(), SpkiFingerprint.SubjectPublicKeyInfo(der));
            Assert.Equal(fingerprint, IppCertificates.Fingerprint(certificate));
        }
    }

    [Fact]
    public void Fingerprint_HasItsHexAndTextForms()
    {
        byte[] der = IppFixtures.CertificateDer(P256File);
        var spki = SpkiFingerprint.SubjectPublicKeyInfo(der);
        Assert.NotNull(spki);
        var fingerprint = SpkiFingerprint.Of(der)!;
        Assert.Equal(SpkiFingerprint.ByteCount, fingerprint.Length);
        Assert.Equal(P256Fingerprint, SpkiFingerprint.Hex(fingerprint));
        Assert.Equal(P256Text, SpkiFingerprint.Text(fingerprint));
        Assert.Equal(P256Fingerprint, SpkiFingerprint.Hex(SpkiFingerprint.OfSubjectPublicKeyInfo(spki)));
    }

    [Fact]
    public void P256Point_RebuildsTheSubjectPublicKeyInfo()
    {
        byte[] spki = SpkiFingerprint.SubjectPublicKeyInfo(IppFixtures.CertificateDer(P256File))!;
        byte[] point = spki[^SpkiFingerprint.P256PointByteCount..];
        Assert.Equal(spki, SpkiFingerprint.P256SubjectPublicKeyInfo(point));
        Assert.Equal(spki[..26], SpkiFingerprint.P256Prefix.ToArray());
        Assert.Null(SpkiFingerprint.P256SubjectPublicKeyInfo(point[..64]));
        var compressed = (byte[])point.Clone();
        compressed[0] = 0x02;
        Assert.Null(SpkiFingerprint.P256SubjectPublicKeyInfo(compressed));
    }

    [Fact]
    public void CheckCode_IsSixDigitsOfTheFingerprint()
    {
        Assert.Equal(P256CheckCode, SpkiFingerprint.CheckCode(Fingerprint));
        Assert.Equal("218 140", SpkiFingerprint.FormatCheckCode(P256CheckCode));
        Assert.Equal("000000", SpkiFingerprint.CheckCode(new byte[32]));
        // 0x000F4240 = 1,000,000 → 0; 0x000F4241 → 1, with leading zeros.
        Assert.Equal("000001", SpkiFingerprint.CheckCode([0x00, 0x0F, 0x42, 0x41, .. new byte[28]]));
        Assert.Equal("", SpkiFingerprint.CheckCode([1, 2, 3]));
        Assert.Equal("12345", SpkiFingerprint.FormatCheckCode("12345"));
    }

    [Fact]
    public void Matches_ComparesWholeFingerprints()
    {
        var fingerprint = Fingerprint;
        Assert.True(SpkiFingerprint.Matches(fingerprint, (byte[])fingerprint.Clone()));
        var other = (byte[])fingerprint.Clone();
        other[31] ^= 1;
        Assert.False(SpkiFingerprint.Matches(fingerprint, other));
        Assert.False(SpkiFingerprint.Matches(fingerprint[..31], fingerprint[..31]));
        Assert.False(SpkiFingerprint.Matches([], []));
    }

    [Fact]
    public void MalformedCertificates_HaveNoFingerprint()
    {
        byte[] good = IppFixtures.CertificateDer(P256File);
        Assert.Null(SpkiFingerprint.Of([]));
        Assert.Null(SpkiFingerprint.Of([0x30]));
        Assert.Null(SpkiFingerprint.Of(good[..100]));
        Assert.Null(SpkiFingerprint.Of(good[..^1]));
        Assert.Null(SpkiFingerprint.Of([.. good, 0x00]));
        Assert.Null(SpkiFingerprint.Of(With(good, 0, 0x31)));                 // not a SEQUENCE
        Assert.Null(SpkiFingerprint.Of(With(good, 1, 0x80)));                 // indefinite length
        Assert.Null(SpkiFingerprint.Of(With(good, 1, 0x85)));                 // a length of five bytes
        Assert.Null(SpkiFingerprint.Of([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])); // longer than the data
        Assert.Null(SpkiFingerprint.Of(With(good, 4, 0x31)));                 // tbsCertificate not a SEQUENCE
        Assert.Null(SpkiFingerprint.Of(With(good, 8, 0xBF)));                 // a high tag number
    }

    [Fact]
    public void MatchesDotNetSubjectPublicKeyInfo()
    {
        using var ec = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var ecCertificate = new CertificateRequest("CN=EC", ec, HashAlgorithmName.SHA256)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        using var rsa = RSA.Create(2048);
        using var rsaCertificate = new CertificateRequest("CN=RSA", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        foreach (var certificate in new[] { ecCertificate, rsaCertificate })
        {
            Assert.Equal(certificate.PublicKey.ExportSubjectPublicKeyInfo(), SpkiFingerprint.SubjectPublicKeyInfo(certificate.RawData));
            Assert.Equal(IppCertificates.Fingerprint(certificate), SpkiFingerprint.Hex(SpkiFingerprint.Of(certificate.RawData)!));
        }
        byte[] point = ec.ExportSubjectPublicKeyInfo()[^65..];
        Assert.Equal(ec.ExportSubjectPublicKeyInfo(), SpkiFingerprint.P256SubjectPublicKeyInfo(point));
    }

    private static byte[] With(byte[] data, int index, byte value)
    {
        var copy = (byte[])data.Clone();
        copy[index] = value;
        return copy;
    }
}
