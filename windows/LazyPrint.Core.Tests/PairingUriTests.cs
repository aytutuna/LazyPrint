using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PairingUriTests.swift (same codes, same refusals).

public class PairingUriTests
{
    private const string DesktopId = "0123456789abcdef0123456789abcdef";

    private static PairingUri Sample() =>
        new(DesktopId, "Aytu's PC", CompanionVectors.FingerprintText, ["192.168.1.20", "fd00::1"], 52732, CompanionVectors.TokenText);

    private const string SampleText =
        "lazyprint://pair?v=1&id=0123456789abcdef0123456789abcdef&n=Aytu%27s%20PC"
        + "&fp=gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ&a=192.168.1.20,fd00%3A%3A1&p=52732&t=AAECAwQFBgcICQoLDA0ODw";

    [Fact]
    public void Format_WritesTheCode()
    {
        Assert.Equal(SampleText, Sample().Format());
        Assert.Equal(SampleText, Sample().ToString());
    }

    [Fact]
    public void Parse_ReadsTheCode()
    {
        var code = PairingUri.Parse(SampleText);
        Assert.Equal(Sample(), code);
        Assert.Equal(CompanionVectors.Fingerprint, code.FingerprintBytes);
    }

    [Fact]
    public void RoundTrip_KeepsNamesAndAddresses()
    {
        var code = new PairingUri(DesktopId, "Büro-PC 日本 & co = 100%", CompanionVectors.FingerprintText,
                                  ["10.0.0.5", "fe80::1%12", "::ffff:192.168.0.1", "2001:db8::8a2e:370:7334"], 1, CompanionVectors.TokenText);
        Assert.Equal(code, PairingUri.Parse(code.Format()));
        var noAddresses = code with { Addresses = [] };
        Assert.DoesNotContain("&a=", noAddresses.Format());
        Assert.Equal(noAddresses, PairingUri.Parse(noAddresses.Format()));
    }

    [Fact]
    public void Parse_IgnoresUnknownPartsAndTheSchemesCase()
    {
        var code = PairingUri.Parse(SampleText.Replace("lazyprint://pair?", "LazyPrint://PAIR?") + "&later=1&x");
        Assert.Equal(Sample(), code);
        Assert.Equal(Sample(), PairingUri.Parse(SampleText.Replace("&p=", "&&p=")));
    }

    [Theory]
    [InlineData("https://example.com/pair?v=1")]
    [InlineData("WIFI:S:Home;T:WPA;P:secret;;")]
    [InlineData("")]
    public void Parse_RefusesOtherCodes(string text) => AssertRefused(PairingUriErrorKind.NotPairingCode, text);

    [Fact]
    public void Parse_RefusesNewerVersions()
    {
        AssertRefused(PairingUriErrorKind.NewerVersion, "lazyprint://pair?v=2");
        AssertRefused(PairingUriErrorKind.NewerVersion, SampleText.Replace("v=1", "v=17"));
        Assert.Equal(PairingUri.NewerVersionMessage,
                     Assert.Throws<PairingUriException>(() => PairingUri.Parse("lazyprint://pair?v=2")).Message);
    }

    [Theory]
    [InlineData("lazyprint:pair?v=1")]
    [InlineData("lazyprint://other?v=1")]
    [InlineData("lazyprint://pair")]
    [InlineData("lazyprint://pair?v=0")]
    [InlineData("lazyprint://pair?v=one")]
    [InlineData("lazyprint://pair?id=x")]
    public void Parse_RefusesDamagedCodes(string text) => AssertRefused(PairingUriErrorKind.Damaged, text);

    [Theory]
    [InlineData("&id=0123456789abcdef0123456789abcdef", "")]                                  // no id
    [InlineData("&id=0123456789abcdef0123456789abcdef", "&id=short")]                         // id too short
    [InlineData("&id=0123456789abcdef0123456789abcdef", "&id=0123456789abcdef0123456789abcdef&id=0123456789abcdef0123456789abcdef")]
    [InlineData("&n=Aytu%27s%20PC", "&n=")]                                                   // empty name
    [InlineData("&n=Aytu%27s%20PC", "&n=Tab%09name")]                                         // control character
    [InlineData("&n=Aytu%27s%20PC", "&n=%FF")]                                                // not UTF-8
    [InlineData("&n=Aytu%27s%20PC", "&n=bad%2")]                                              // cut escape
    [InlineData("&n=Aytu%27s%20PC", "&n=bad%zz")]                                             // not hex
    [InlineData("&n=Aytu%27s%20PC", "&n=a b")]                                                // unescaped space
    [InlineData("&fp=gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ", "&fp=gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcK")] // 31 bytes
    [InlineData("&fp=gMJQHPCYtj9Bg1DG_qWm5CA2Lmvor_M3w67iOaQFcKQ", "&fp=gMJQHPCYtj9Bg1DG/qWm5CA2Lmvor_M3w67iOaQFcKQ")] // base64, not url
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=192.168.1.256")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=192.168.01.2")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=printer.local")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=192.168.1.20,")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=1%3A2%3A3")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=1%3A%3A2%3A%3A3")]
    [InlineData("&a=192.168.1.20,fd00%3A%3A1", "&a=1,2,3,4,5,6,7,8,9")]
    [InlineData("&p=52732", "&p=0")]
    [InlineData("&p=52732", "&p=65536")]
    [InlineData("&p=52732", "&p=-1")]
    [InlineData("&p=52732", "")]
    [InlineData("&t=AAECAwQFBgcICQoLDA0ODw", "&t=AAECAwQFBgcICQoLDA0O")]                        // 15 bytes
    [InlineData("&t=AAECAwQFBgcICQoLDA0ODw", "")]
    public void Parse_RefusesBadParts(string part, string replacement) =>
        AssertRefused(PairingUriErrorKind.Damaged, SampleText.Replace(part, replacement));

    [Fact]
    public void Parse_RefusesFragmentsAndOverlongCodes()
    {
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "#top");
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "&pad=" + new string('a', PairingUri.MaxLength));
    }

    [Fact]
    public void Parse_RefusesAnythingButPrintableAscii()
    {
        // A combining mark after a separator, an unknown key that is not ASCII, a space or a line
        // break in a key: refused alike on both platforms.
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "&\u0301x=1");
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "&caf\u00E9=1");
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "&a b=1");
        AssertRefused(PairingUriErrorKind.Damaged, SampleText + "\r\n&x=1");
        // Only ASCII letters ignore case in the scheme.
        AssertRefused(PairingUriErrorKind.NotPairingCode, "complete\u017Fcanner://pair?v=1");
    }

    [Fact]
    public void Format_RefusesWhatParseWould()
    {
        Assert.Throws<ArgumentException>(() => (Sample() with { Port = 0 }).Format());
        Assert.Throws<ArgumentException>(() => (Sample() with { Name = "" }).Format());
        Assert.Throws<ArgumentException>(() => (Sample() with { Addresses = ["host.local"] }).Format());
        Assert.Throws<ArgumentException>(() => (Sample() with { Token = "short" }).Format());
    }

    [Theory]
    [InlineData("0.0.0.0", true)]
    [InlineData("255.255.255.255", true)]
    [InlineData("::", true)]
    [InlineData("::1", true)]
    [InlineData("fe80::1%eth0", true)]
    [InlineData("1:2:3:4:5:6:7:8", true)]
    [InlineData("1:2:3:4:5:6:192.168.0.1", true)]
    [InlineData("1:2:3:4:5:6:7:8:9", false)]
    [InlineData("1:2:3:4:5:6:7", false)]
    [InlineData("12345::", false)]
    [InlineData("fe80::1%", false)]
    [InlineData("1.2.3", false)]
    [InlineData("1.2.3.4.5", false)]
    [InlineData("", false)]
    public void IsValidAddress_ChecksIPLiterals(string address, bool valid) => Assert.Equal(valid, PairingUri.IsValidAddress(address));

    [Fact]
    public void PercentEncoding_KeepsUnreservedCharactersOnly()
    {
        Assert.Equal("a-._~Z9%20%2C%26%3D%25%C3%A9", PairingUri.PercentEncode("a-._~Z9 ,&=%é"));
        Assert.Equal("a-._~Z9 ,&=%é", PairingUri.PercentDecode("a-._~Z9%20%2C%26%3D%25%C3%A9"));
        Assert.Equal("é", PairingUri.PercentDecode("%c3%a9"));
        Assert.Null(PairingUri.PercentDecode("a&b"));
        Assert.Null(PairingUri.PercentDecode("%C3"));
    }

    private static void AssertRefused(PairingUriErrorKind kind, string text)
    {
        var error = Assert.Throws<PairingUriException>(() => PairingUri.Parse(text));
        Assert.Equal(kind, error.Kind);
        Assert.Null(PairingUri.TryParse(text, out var again));
        Assert.Equal(kind, again?.Kind);
    }
}
