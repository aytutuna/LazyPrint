namespace LazyPrint.Core.Tests;

// Values both suites use for the phone link: the P-256 certificate of Tests/Fixtures/Ipp and the
// secret and token made of the bytes 0, 1, 2, ...
internal static class CompanionVectors
{
    public const string CertificateFile = "certificate-p256.pem";
    public const string FingerprintHex = "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4";
    public const string FingerprintText = "gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ";
    public const string CheckCode = "218140";

    public static byte[] Certificate => IppFixtures.CertificateDer(CertificateFile);
    public static byte[] Fingerprint => Convert.FromHexString(FingerprintHex);

    /// <summary>The bytes 0, 1, 2, ... as a device secret, its SHA-256 and its text.</summary>
    public static byte[] Secret => [.. Enumerable.Range(0, 32).Select(i => (byte)i)];
    public const string SecretHash = "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd";
    public const string SecretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

    /// <summary>The bytes 0...15 as a pairing token, and its text.</summary>
    public static byte[] Token => [.. Enumerable.Range(0, 16).Select(i => (byte)i)];
    public const string TokenText = "AAECAwQFBgcICQoLDA0ODw";
}
