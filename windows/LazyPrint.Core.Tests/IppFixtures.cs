using System.Runtime.CompilerServices;
using System.Security.Cryptography.X509Certificates;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

internal static class IppFixtures
{
    public static readonly string[] PrinterNames = ["hp-laserjet", "epson-ecotank", "brother-laser", "canon-pixma"];

    /// <summary>A TXT record in the shape HP all-in-ones advertise, one "key=value" entry per line.</summary>
    public const string HpTxtFile = "txt-hp.txt";

    /// <summary>Self-signed printer certificates (PEM) and the SHA-256 of their SubjectPublicKeyInfo.</summary>
    public static readonly (string File, string Fingerprint, string Subject)[] Certificates =
    [
        ("certificate-rsa2048.pem", "ef21ff96c67a12d62b5fd5bc7367fc0b265fe4da4e0e8ebc0a0d404457d7a74c",
         "CN=Lazy Scan test scanner RSA-2048"),
        ("certificate-p256.pem", "80c2501cf098b63f418350c6fea5a6e420362e6be8aff337c3aee239a40570a4",
         "CN=Lazy Scan test scanner P-256"),
        ("certificate-p384.pem", "c287be8b8476f2aaa5d6f61eee6f4a7b062c89222ad861abc1265383e5f8d9bb",
         "CN=Lazy Scan test scanner P-384"),
    ];

    /// <summary>A fixture's path in Tests/Fixtures/Ipp.</summary>
    public static string PathOf(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "Ipp", name);

    /// <summary>A text fixture with LF line breaks, whatever a checkout did to them.</summary>
    public static string Text(string name) => File.ReadAllText(PathOf(name)).ReplaceLineEndings("\n");

    /// <summary>A text fixture's non-empty lines.</summary>
    public static string[] Lines(string name) => [.. Text(name).Split('\n').Where(line => line.Length > 0)];

    /// <summary>The DER bytes of a PEM certificate fixture.</summary>
    public static byte[] CertificateDer(string name)
    {
        string body = string.Concat(Lines(name).Where(line => !line.StartsWith("-----", StringComparison.Ordinal)));
        return Convert.FromBase64String(body);
    }

    /// <summary>A PEM certificate fixture, loaded by .NET.</summary>
    public static X509Certificate2 Certificate(string name) => X509CertificateLoader.LoadCertificate(CertificateDer(name));

    public static byte[] Printer(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Ipp", "printers", name + ".bin"));

    public static PrinterCapabilities Capabilities(string name) =>
        PrinterCapabilities.From(IppMessage.Decode(Printer(name)).Message);

    /// <summary>
    /// Compares bytes with the golden file Tests/Fixtures/Ipp/folder/name.extension. With LAZYPRINT_WRITE_GOLDEN=1 the file is
    /// written instead, into the source tree (the build copies it on the next run); Swift only reads them.
    /// </summary>
    public static void Golden(string name, byte[] actual, string folder = "requests", string extension = ".bin", [CallerFilePath] string here = "")
    {
        if (Environment.GetEnvironmentVariable("LAZYPRINT_WRITE_GOLDEN") == "1")
        {
            string source = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "Tests", "Fixtures", "Ipp", folder));
            Directory.CreateDirectory(source);
            File.WriteAllBytes(Path.Combine(source, name + extension), actual);
            return;
        }
        byte[] expected = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Ipp", folder, name + extension));
        Assert.Equal(expected, actual);
    }
}
