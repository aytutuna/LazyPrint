using System.Net.NetworkInformation;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppDiscoveryTests.swift: the same cases (the TXT record is the
// shared fixture Tests/Fixtures/Ipp/txt-hp.txt). Covers what discovery hands over: TXT records, the
// addresses users type, and how a printer's DNS-SD services become one endpoint.

public class IppDiscoveryTests
{
    // MARK: - TXT records

    /// <summary>A TXT record in the shape HP all-in-ones advertise.</summary>
    private static string[] HpTxt => IppFixtures.Lines(IppFixtures.HpTxtFile);

    [Fact]
    public void TxtRecordReadsTheIppKeys()
    {
        var txt = IppTxtRecord.Parse(HpTxt);
        Assert.Equal("ipp/print", txt.ResourcePath);
        Assert.Equal("HP Color LaserJet MFP M479fdw", txt.Model);
        Assert.Equal("(HP Color LaserJet MFP M479fdw)", txt.Product);
        Assert.Equal("564e4333-4230-3538-3930-a0b3cce51a2b", txt.Uuid);
        Assert.Equal("http://HPA1B2C3.local./#hId-pgAirPrint", txt.AdminUrl);
        Assert.Equal("Office", txt.Note);
        Assert.True(txt.Color);
        Assert.True(txt.Duplex);
        Assert.Equal(["application/octet-stream", "application/pdf", "image/jpeg", "image/urf", "image/pwg-raster"], txt.DocumentFormats);
        Assert.Equal(["CP1", "MT1-2-8-9-10-11", "OB10", "PQ3-4-5", "RS300-600", "SRGB24", "W8", "DM1", "IS1-4", "V1.4", "IFU0"], txt.Urf);
        Assert.Equal("1.2", txt.Tls);
        Assert.Equal(["document", "envelope", "photo"], txt.Kind);
        Assert.Equal("legal-A4", txt.PaperMax);
    }

    [Fact]
    public void TxtRecordDefaultsAndOddEntries()
    {
        var empty = IppTxtRecord.Parse([]);
        Assert.Equal("ipp/print", empty.ResourcePath);
        Assert.Null(empty.Model);
        Assert.Null(empty.Uuid);
        Assert.Null(empty.Color);
        Assert.Null(empty.Duplex);
        Assert.Empty(empty.DocumentFormats);
        Assert.Empty(empty.Urf);

        var odd = IppTxtRecord.Parse(
        [
            "RP=/printers/office/",   // keys ignore case; slashes are trimmed
            "ty=First", "ty=Second",  // only the first occurrence counts
            "duplex=f", "flag", "=novalue", "kind=Document, PHOTO ,document",
            "URF=none",
        ]);
        Assert.Equal("printers/office", odd.ResourcePath);
        Assert.Equal("First", odd.Model);
        Assert.False(odd.Duplex);
        Assert.Equal(["document", "photo"], odd.Kind);
        Assert.Empty(odd.Urf);

        // A present but empty rp means the root of the host.
        Assert.Equal("", IppTxtRecord.Parse(["rp="]).ResourcePath);
        Assert.Null(IppTxtRecord.Parse(["Color=maybe"]).Color);
    }

    [Theory]
    [InlineData("564E4333-4230-3538-3930-A0B3CCE51A2B", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("urn:uuid:564e4333-4230-3538-3930-a0b3cce51a2b", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("{564e4333-4230-3538-3930-a0b3cce51a2b}", "564e4333423035383930a0b3cce51a2b")]
    [InlineData("  ", null)]
    [InlineData(null, null)]
    public void UuidKeysCompareTheFormsPrintersUse(string? uuid, string? key)
    {
        Assert.Equal(key, IppTxtRecord.UuidKey(uuid));
    }

    // MARK: - Addresses users type

    [Theory]
    [InlineData("192.168.1.50", false, "192.168.1.50", 631, "ipp/print", "192.168.1.50", "ipp://192.168.1.50:631/ipp/print", "http://192.168.1.50:631/ipp/print")]
    [InlineData(" 192.168.001.050 ", false, "192.168.1.50", 631, "ipp/print", "192.168.1.50", "ipp://192.168.1.50:631/ipp/print", "http://192.168.1.50:631/ipp/print")]
    [InlineData("Printer.Local", false, "printer.local", 631, "ipp/print", "printer.local", "ipp://printer.local:631/ipp/print", "http://printer.local:631/ipp/print")]
    [InlineData("epson.local:8631", false, "epson.local", 8631, "ipp/print", "epson.local:8631", "ipp://epson.local:8631/ipp/print", "http://epson.local:8631/ipp/print")]
    [InlineData("ipp://192.168.1.50", false, "192.168.1.50", 631, "ipp/print", "192.168.1.50", "ipp://192.168.1.50:631/ipp/print", "http://192.168.1.50:631/ipp/print")]
    [InlineData("ipps://10.0.0.7", true, "10.0.0.7", 631, "ipp/print", "ipps://10.0.0.7", "ipps://10.0.0.7:631/ipp/print", "https://10.0.0.7:631/ipp/print")]
    [InlineData("ipps://10.0.0.7:8443/ipp/print/", true, "10.0.0.7", 8443, "ipp/print", "ipps://10.0.0.7:8443", "ipps://10.0.0.7:8443/ipp/print", "https://10.0.0.7:8443/ipp/print")]
    [InlineData("ipp://host:8631/printers/Office", false, "host", 8631, "printers/Office", "ipp://host:8631/printers/Office", "ipp://host:8631/printers/Office", "http://host:8631/printers/Office")]
    [InlineData("http://10.0.0.7", false, "10.0.0.7", 80, "ipp/print", "10.0.0.7:80", "ipp://10.0.0.7:80/ipp/print", "http://10.0.0.7/ipp/print")]
    [InlineData("https://10.0.0.7", true, "10.0.0.7", 443, "ipp/print", "ipps://10.0.0.7:443", "ipps://10.0.0.7:443/ipp/print", "https://10.0.0.7/ipp/print")]
    [InlineData("http://host:9090/printers/a%20b", false, "host", 9090, "printers/a b", "ipp://host:9090/printers/a%20b", "ipp://host:9090/printers/a%20b", "http://host:9090/printers/a%20b")]
    [InlineData("10.0.0.7/ipp/print", false, "10.0.0.7", 631, "ipp/print", "10.0.0.7", "ipp://10.0.0.7:631/ipp/print", "http://10.0.0.7:631/ipp/print")]
    [InlineData("[fe80::1%12]:8631", false, "fe80::1%12", 8631, "ipp/print", "[fe80::1%12]:8631", "ipp://[fe80::1]:8631/ipp/print", "http://[fe80::1]:8631/ipp/print")]
    [InlineData("2001:DB8::5", false, "2001:db8::5", 631, "ipp/print", "[2001:db8::5]", "ipp://[2001:db8::5]:631/ipp/print", "http://[2001:db8::5]:631/ipp/print")]
    [InlineData("[2001:db8::5]", false, "2001:db8::5", 631, "ipp/print", "[2001:db8::5]", "ipp://[2001:db8::5]:631/ipp/print", "http://[2001:db8::5]:631/ipp/print")]
    [InlineData("ipps://[2001:db8::5]", true, "2001:db8::5", 631, "ipp/print", "ipps://[2001:db8::5]", "ipps://[2001:db8::5]:631/ipp/print", "https://[2001:db8::5]:631/ipp/print")]
    [InlineData("https://[2001:db8::5]:9443", true, "2001:db8::5", 9443, "ipp/print", "ipps://[2001:db8::5]:9443", "ipps://[2001:db8::5]:9443/ipp/print", "https://[2001:db8::5]:9443/ipp/print")]
    public void AddressesParseAndNormalize(string text, bool secure, string host, int port, string path,
                                           string canonical, string printerUri, string requestUri)
    {
        Assert.True(PrinterAddress.TryParse(text, out var address, out string error), error);
        Assert.Equal(secure, address!.Secure);
        Assert.Equal(host, address.Host);
        Assert.Equal(port, address.Port);
        Assert.Equal(path, address.ResourcePath);
        Assert.Equal(canonical, address.ToString());
        Assert.Equal(printerUri, address.PrinterUri);
        Assert.Equal(requestUri, address.RequestUri.AbsoluteUri);
        // The canonical text reads back as the same address.
        Assert.Equal(address, PrinterAddress.Parse(canonical));
    }

    [Fact]
    public void ZonedIPv6AddressesStayUsable()
    {
        var address = PrinterAddress.Parse("[fe80::1%12]:8631");
        var uri = address.RequestUri;
        Assert.Equal(System.UriHostNameType.IPv6, uri.HostNameType);
        Assert.Equal("fe80::1%12", uri.DnsSafeHost);
        Assert.Equal(8631, uri.Port);
        Assert.Equal("[fe80::1%12]:8631", address.Authority);
    }

    /// <summary>The loopback interface's name, as the system's interface-name lookup takes it.</summary>
    private static string LoopbackName =>
        OperatingSystem.IsWindows() ? "loopback_0" : OperatingSystem.IsMacOS() ? "lo0" : "lo";

    [Fact]
    public void NamedZonesReadAsTheirInterfaceIndex()
    {
        int index = NetworkInterface.IPv6LoopbackInterfaceIndex;
        Assert.True(index > 0);
        var address = PrinterAddress.Parse($"[fe80::1%{LoopbackName}]:8631");
        Assert.Equal($"fe80::1%{index}", address.Host);
        Assert.Equal($"[fe80::1%{index}]:8631", address.ToString());
        Assert.Equal(address, PrinterAddress.Parse(address.ToString()));
        Assert.Equal($"fe80::1%{index}", PrinterAddress.Parse($"ipp://[fe80::1%{LoopbackName}]:8631").Host);
        // A zone of 0 or none at all is no zone; one that names no interface is refused, not dropped.
        Assert.Equal("2001:db8::1", PrinterAddress.Parse("[2001:db8::1%0]").Host);
        Assert.Equal("2001:db8::1", PrinterAddress.Parse("[2001:db8::1%]").Host);
        Assert.False(PrinterAddress.TryParse("[fe80::1%nosuch0]", out _, out _));
    }

    [Theory]
    [InlineData("", "Enter the printer's IP address or host name.")]
    [InlineData("   ", "Enter the printer's IP address or host name.")]
    [InlineData("192.168.1", "\"192.168.1\" is not a valid IP address or host name.")]
    [InlineData("300.1.1.1", "\"300.1.1.1\" is not a valid IP address or host name.")]
    [InlineData("printer:0", "The port must be a number from 1 to 65535.")]
    [InlineData("printer:70000", "The port must be a number from 1 to 65535.")]
    [InlineData("printer:ipp", "The port must be a number from 1 to 65535.")]
    [InlineData("my printer", "An address cannot contain spaces.")]
    [InlineData("ftp://10.0.0.7", "Use an address that starts with ipp://, ipps://, http:// or https://, or just the IP address or host name.")]
    [InlineData("socket://10.0.0.7:9100", "Use an address that starts with ipp://, ipps://, http:// or https://, or just the IP address or host name.")]
    [InlineData("ipp://user:pw@10.0.0.7", "Leave out the user name and password; printers do not need them.")]
    [InlineData("[fe80::1", "An IPv6 address in brackets needs its closing \"]\".")]
    [InlineData("[fe80::1]x", "That is not a valid address.")]
    [InlineData("bad_host!", "\"bad_host!\" is not a valid IP address or host name.")]
    [InlineData("[fe80::1%nosuch0]", "\"fe80::1%nosuch0\" is not a valid IP address or host name.")]
    [InlineData("fe80::1%99999999999", "\"fe80::1%99999999999\" is not a valid IP address or host name.")]
    [InlineData("ipp://[fe80::1%nosuch0]:8631", "That is not a valid address.")]
    [InlineData("fe80::1a2b:3c4d:5e6f:7a8b", "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12.")]
    [InlineData("[fe80::1%0]:8631", "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12.")]
    [InlineData("ipp://[fe80::1]", "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12.")]
    public void BadAddressesSayWhatIsWrong(string text, string message)
    {
        Assert.False(PrinterAddress.TryParse(text, out var address, out string error));
        Assert.Null(address);
        Assert.Equal(message, error);
        Assert.Equal(message, Assert.Throws<FormatException>(() => PrinterAddress.Parse(text)).Message);
    }

    [Fact]
    public void AddressesCompareByTheirCanonicalForm()
    {
        Assert.Equal(PrinterAddress.Parse("ipp://PRINTER.local:631/ipp/print"), PrinterAddress.Parse("printer.local"));
        Assert.NotEqual(PrinterAddress.Parse("ipps://printer.local"), PrinterAddress.Parse("printer.local"));
        Assert.NotEqual(PrinterAddress.Parse("printer.local:8631"), PrinterAddress.Parse("printer.local"));
        Assert.NotEqual(PrinterAddress.Parse("printer.local/printers/a"), PrinterAddress.Parse("printer.local"));
        Assert.Null(PrinterAddress.Create(false, "host", 0, "ipp/print"));
        Assert.Null(PrinterAddress.Create(false, "not a host", 631, "ipp/print"));
        Assert.Equal("ipp://host:631/", PrinterAddress.Create(false, "host", 631, "")!.PrinterUri);
    }

    [Fact]
    public void ABareHostThatDidNotAnswerIsTriedOverIpps()
    {
        var plain = PrinterAddress.Parse("192.168.1.50");
        Assert.Equal("ipps://192.168.1.50", plain.HttpsFallback("192.168.1.50")!.ToString());
        Assert.Null(plain.HttpsFallback("ipp://192.168.1.50"));
        Assert.Null(plain.HttpsFallback("192.168.1.50/ipp/print"));
        Assert.Null(PrinterAddress.Parse("192.168.1.50:8631").HttpsFallback("192.168.1.50:8631"));
        Assert.Null(PrinterAddress.Parse("ipps://192.168.1.50").HttpsFallback("ipps://192.168.1.50"));
        Assert.Null(PrinterAddress.Parse("192.168.1.50/printers/a").HttpsFallback("192.168.1.50"));
    }

    // MARK: - Services → endpoints

    private static IppService Service(string instance, bool secure, string[] addresses, string[] txt,
                                      int port = 631, string? host = "HPA1B2C3.local") =>
        new($"id-{instance}-{secure}", instance, secure, host, addresses, port, txt);

    [Fact]
    public void BothServicesOfOnePrinterMergeIppsFirst()
    {
        var endpoints = IppEndpoint.Choose(
        [
            Service("HP M479 (A1B2C3)", secure: false, ["fe80::1", "192.168.1.20", "2001:db8::20"], HpTxt),
            Service("HP M479 (A1B2C3)", secure: true, ["192.168.1.20"], HpTxt),
        ]);
        var endpoint = Assert.Single(endpoints);
        Assert.Equal("uuid:564e4333423035383930a0b3cce51a2b", endpoint.Key);
        Assert.Equal("HP Color LaserJet MFP M479fdw", endpoint.Name);
        Assert.Equal("564e4333-4230-3538-3930-a0b3cce51a2b", endpoint.Uuid);
        Assert.Equal(["HP M479 (A1B2C3)"], endpoint.InstanceNames);
        // ipps first; IPv4, then the host name, then IPv6; link-local without a zone skipped.
        Assert.Equal(
        [
            "ipps://192.168.1.20", "ipps://hpa1b2c3.local",
            "192.168.1.20", "hpa1b2c3.local", "[2001:db8::20]",
        ], endpoint.Addresses.Select(a => a.ToString()));
    }

    [Fact]
    public void AnEndpointCanTryOneOfItsAddressesFirst()
    {
        var endpoint = Assert.Single(IppEndpoint.Choose([Service("HP M479 (A1B2C3)", secure: false, ["192.168.1.20", "192.168.1.21"], HpTxt)]));
        var second = endpoint.Addresses[1];
        var preferred = endpoint.Preferring(second);
        Assert.Equal(second, preferred.Addresses[0]);
        Assert.Equal(endpoint.Addresses.Count, preferred.Addresses.Count);
        Assert.Same(endpoint, endpoint.Preferring(endpoint.Addresses[0]));
        Assert.Same(endpoint, endpoint.Preferring(PrinterAddress.Parse("192.168.1.99")));
        Assert.NotEqual(Printer(endpoint), Printer(preferred));
    }

    private static PrinterInfo Printer(IppEndpoint endpoint) =>
        new("ipp:x", "HP", null, null, PrinterRoute.Ipp, endpoint, false, PrinterState.Idle, [], []);

    [Fact]
    public void EndpointsKeepTheResourcePathPortAndZonedAddresses()
    {
        var endpoint = Assert.Single(IppEndpoint.Choose(
        [
            Service("Canon", secure: false, ["fe80::5%7"], ["rp=/printers/Canon", "ty=Canon MF743C"], port: 8631, host: null),
        ]));
        Assert.Equal("name:canon", endpoint.Key);
        Assert.Null(endpoint.Uuid);
        var address = Assert.Single(endpoint.Addresses);
        Assert.Equal("ipp://[fe80::5]:8631/printers/Canon", address.PrinterUri);
        Assert.Equal("fe80::5%7", address.RequestUri.DnsSafeHost);
    }

    [Fact]
    public void AddressesWhoseZoneNamesNoInterfaceAreSkipped()
    {
        var endpoint = Assert.Single(IppEndpoint.Choose(
        [
            Service("Canon", secure: false, ["fe80::5%nosuch0", "2001:db8::9%nosuch0", $"fe80::6%{LoopbackName}"],
                    ["ty=Canon MF743C"], host: null),
        ]));
        Assert.Equal([$"[fe80::6%{NetworkInterface.IPv6LoopbackInterfaceIndex}]"], endpoint.Addresses.Select(a => a.ToString()));
    }

    [Fact]
    public void PrintersStayApartAndUnusableServicesAreDropped()
    {
        string[] other = ["ty=Epson ET-4850", "UUID=cfe92100-67c4-11d4-a45f-f8d0273e1a0b"];
        var endpoints = IppEndpoint.Choose(
        [
            Service("HP", secure: false, ["192.168.1.20"], HpTxt),
            Service("Epson", secure: false, ["192.168.1.30"], other),
            Service("Broken port", secure: false, ["192.168.1.40"], ["ty=X"], port: 70000),
            Service("No address", secure: false, ["fe80::9"], ["ty=Y"], host: null),
            // The _ipps service of the HP without a UUID of its own: the instance name ties it.
            Service("HP", secure: true, ["192.168.1.20"], ["ty=HP Color LaserJet MFP M479fdw"]),
        ]);
        Assert.Equal(["HP Color LaserJet MFP M479fdw", "Epson ET-4850"], endpoints.Select(e => e.Name));
        Assert.Equal("ipps://192.168.1.20", endpoints[0].Addresses[0].ToString());
        Assert.Equal("uuid:cfe9210067c411d4a45ff8d0273e1a0b", endpoints[1].Key);
    }

    [Fact]
    public void WithoutAModelTheInstanceNameIsTheName()
    {
        var endpoint = Assert.Single(IppEndpoint.Choose([Service("Office printer", false, ["10.0.0.9"], [])]));
        Assert.Equal("Office printer", endpoint.Name);
        Assert.Equal("ipp/print", endpoint.Txt.ResourcePath);
    }
}
