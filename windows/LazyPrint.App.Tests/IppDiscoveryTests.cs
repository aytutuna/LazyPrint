using LazyPrint.App.Services;
using Xunit;

namespace LazyPrint.App.Tests;

// What the device watcher reports for a DNS-SD service, as the IppService the merge reads.
public sealed class IppDiscoveryTests
{
    private const string Dnssd = "System.Devices.Dnssd.";

    private static Dictionary<string, object?> Properties(string service, params (string Key, object? Value)[] more)
    {
        var properties = new Dictionary<string, object?>
        {
            [Dnssd + "ServiceName"] = service,
            [Dnssd + "InstanceName"] = "HP LaserJet Pro M404 (A1B2C3)",
            [Dnssd + "HostName"] = "HPA1B2C3.local",
            [Dnssd + "PortNumber"] = (ushort)631,
            [Dnssd + "TextAttributes"] = new[] { "rp=ipp/print", "UUID=0b2f1a52-7c61-4f0e-9d6b-3a1c5e8d9f40" },
            ["System.Devices.IpAddress"] = new[] { "192.168.1.20", "fe80::1%12" },
        };
        foreach (var (key, value) in more) properties[key] = value;
        return properties;
    }

    [Fact]
    public void AServiceKeepsWhatTheWatcherReported()
    {
        var service = IppDiscovery.ToService("id-1", "fallback", false, Properties("_ipp._tcp.local"));

        Assert.Equal("id-1", service.Id);
        Assert.Equal("HP LaserJet Pro M404 (A1B2C3)", service.InstanceName);
        Assert.False(service.Secure);
        Assert.Equal("HPA1B2C3.local", service.HostName);
        Assert.Equal(631, service.Port);
        Assert.Equal(["192.168.1.20", "fe80::1%12"], service.Addresses);
        Assert.Equal(["rp=ipp/print", "UUID=0b2f1a52-7c61-4f0e-9d6b-3a1c5e8d9f40"], service.TextAttributes);
    }

    [Fact]
    public void TheServiceNameSaysWhetherItIsSecure()
    {
        Assert.True(IppDiscovery.ToService("a", "n", false, Properties("_ipps._tcp.local")).Secure);
        Assert.False(IppDiscovery.ToService("a", "n", true, Properties("_ipp._tcp.local")).Secure);
    }

    [Fact]
    public void TheWatchersTypeStandsWhenTheServiceNameIsMissing()
    {
        var properties = Properties("_ipp._tcp.local");
        properties.Remove(Dnssd + "ServiceName");

        Assert.True(IppDiscovery.ToService("a", "n", true, properties).Secure);
        Assert.False(IppDiscovery.ToService("a", "n", false, properties).Secure);
    }

    [Fact]
    public void TheDeviceNameStandsInForAMissingInstanceName()
    {
        var properties = Properties("_ipp._tcp.local", (Dnssd + "InstanceName", ""));

        Assert.Equal("Office printer", IppDiscovery.ToService("a", "Office printer", false, properties).InstanceName);
    }

    [Theory]
    [InlineData(8631)]
    [InlineData(8631u)]
    [InlineData("8631")]
    public void APortIsReadWhateverNumberTypeItCameIn(object port)
    {
        var properties = Properties("_ipps._tcp.local", (Dnssd + "PortNumber", port));

        Assert.Equal(8631, IppDiscovery.ToService("a", "n", true, properties).Port);
    }

    [Fact]
    public void APortThatIsMissingOrNotANumberIsZeroSoTheServiceIsSkipped()
    {
        var missing = Properties("_ipp._tcp.local");
        missing.Remove(Dnssd + "PortNumber");

        Assert.Equal(0, IppDiscovery.ToService("a", "n", false, missing).Port);
        Assert.Equal(0, IppDiscovery.ToService("a", "n", false, Properties("_ipp._tcp.local", (Dnssd + "PortNumber", "none"))).Port);
    }

    [Fact]
    public void ASingleAddressAndAListOfTextEntriesAreBothRead()
    {
        var properties = Properties("_ipp._tcp.local", ("System.Devices.IpAddress", "10.0.0.7"),
                                    (Dnssd + "TextAttributes", new List<string> { "ty=Model" }));
        var service = IppDiscovery.ToService("a", "n", false, properties);

        Assert.Equal(["10.0.0.7"], service.Addresses);
        Assert.Equal(["ty=Model"], service.TextAttributes);
    }

    [Fact]
    public void NothingReportedGivesAnEmptyService()
    {
        var service = IppDiscovery.ToService("a", "name", false, new Dictionary<string, object?>());

        Assert.Equal("name", service.InstanceName);
        Assert.Null(service.HostName);
        Assert.Empty(service.Addresses);
        Assert.Empty(service.TextAttributes);
        Assert.Equal(0, service.Port);
    }
}
