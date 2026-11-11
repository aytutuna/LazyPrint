using System.IO;
using System.Net;
using System.Net.Sockets;
using LazyPrint.App.Services;
using LazyPrint.Core;
using LazyPrint.Core.Tests;
using Xunit;

namespace LazyPrint.App.Tests;

// Adding a printer by address, and keeping the listed addresses, against the Core tests' loopback printer.
public sealed class NetworkPrintersTests : IDisposable
{
    private readonly LoopbackIppPrinter _loopback = new();
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "lazyprint-network-" + Guid.NewGuid().ToString("N"));
    private readonly List<NetworkPrinters> _made = [];

    public NetworkPrintersTests() => Directory.CreateDirectory(_folder);

    public void Dispose()
    {
        foreach (var network in _made) network.Dispose();
        _loopback.Dispose();
        Directory.Delete(_folder, true);
    }

    private NetworkPrinters Network(TimeSpan? recheck = null)
    {
        var network = new NetworkPrinters(_folder, discover: false, recheck);
        _made.Add(network);
        return network;
    }

    private static async Task Until(Func<bool> condition)
    {
        for (int i = 0; i < 200 && !condition(); i++) await Task.Delay(25);
        Assert.True(condition(), "gave up waiting");
    }

    private static int ClosedPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    [Fact]
    public async Task APrinterThatAnswersIsCheckedWithGetPrinterAttributes()
    {
        var check = await Network().CheckAsync(_loopback.Address(), null, CancellationToken.None);

        Assert.NotNull(check.Capabilities);
        Assert.Null(check.Error);
        var request = Assert.Single(_loopback.Requests);
        Assert.Equal((ushort)IppOperation.GetPrinterAttributes, request.Ipp.Code);
    }

    [Fact]
    public async Task AnAddressNobodyAnswersAtSaysWhy()
    {
        var address = PrinterAddress.Parse($"127.0.0.1:{ClosedPort()}");

        var check = await Network().CheckAsync(address, null, CancellationToken.None);

        Assert.Null(check.Capabilities);
        Assert.Null(check.Certificate);
        Assert.StartsWith("Can't reach", check.Error);
    }

    [Fact]
    public async Task AnAddressThatIsNotAnIppPrinterIsNotAdded()
    {
        _loopback.Script(LoopbackAnswer.Http(404));

        var check = await Network().CheckAsync(_loopback.Address(), null, CancellationToken.None);

        Assert.Null(check.Capabilities);
        Assert.Contains("404", check.Error);
    }

    [Fact]
    public async Task AnAddedPrinterIsKeptInTheHostFileAndListedAtOnce()
    {
        var network = Network();
        var address = _loopback.Address();
        var check = await network.CheckAsync(address, null, CancellationToken.None);

        network.Add(address, check.Capabilities!);

        Assert.Equal([address], new IppHostList(_folder).Load());
        var host = Assert.Single(network.Hosts);
        Assert.True(host.Listed);
        var service = Assert.Single(network.Services);
        Assert.Equal(_loopback.Port, service.Port);
        Assert.Equal(["127.0.0.1"], service.Addresses);
        Assert.Contains(service.TextAttributes, entry => entry.StartsWith("rp=", StringComparison.Ordinal));
        Assert.False(service.Secure);
    }

    [Fact]
    public async Task AnAddedPrinterAndTheSamePrinterFoundOnTheNetworkAreOneRow()
    {
        var network = Network();
        var address = _loopback.Address();
        var caps = (await network.CheckAsync(address, null, CancellationToken.None)).Capabilities!;
        network.Add(address, caps);
        var announced = new IppService("dnssd", "HP LaserJet", false, "hp.local", ["192.168.1.20"], 631,
                                       [$"UUID={caps.Uuid}", "rp=ipp/print"]);

        var rows = PrinterMerge.Merge([], [announced, .. network.Services], demo: false);

        var row = Assert.Single(rows);
        Assert.Equal(PrinterRoute.Ipp, row.Route);
        Assert.Contains(row.IppEndpoint!.Addresses, a => a.Host == "127.0.0.1" && a.Port == _loopback.Port);
        Assert.Contains(row.IppEndpoint.Addresses, a => a.Host == "192.168.1.20");
    }

    [Fact]
    public async Task AListedPrinterIsReadThroughItsEndpoint()
    {
        var network = Network();
        var service = new IppService("dnssd", "HP LaserJet", false, null, ["127.0.0.1"], _loopback.Port, ["rp=ipp/print"]);
        var endpoint = Assert.Single(IppEndpoint.Choose([service]));

        var read = await network.ReadAsync(endpoint, CancellationToken.None);

        Assert.NotNull(read.Capabilities);
    }

    [Fact]
    public async Task AReadDoesNotPinANewCertificate()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        _loopback.Certificate = certificate;
        var network = Network();
        var service = new IppService("dnssd", "HP LaserJet", true, null, ["127.0.0.1"], _loopback.Port, ["rp=ipp/print"]);
        var endpoint = Assert.Single(IppEndpoint.Choose([service]));

        var read = await network.ReadAsync(endpoint, CancellationToken.None);

        Assert.Equal(IppTrustVerdict.Unknown, read.Certificate!.Verdict);
        Assert.Null(read.Capabilities);
        Assert.Empty(new IppTrustStore(_folder).Certificates);
    }

    [Fact]
    public async Task AReadOfAPrinterWithANewCertificateIsAnsweredByItsPlainAddress()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        _loopback.Certificate = certificate;
        var network = Network();
        var secure = new IppService("dnssd-s", "HP LaserJet", true, null, ["127.0.0.1"], _loopback.Port, ["rp=ipp/print"]);
        var plain = new IppService("dnssd-p", "HP LaserJet", false, null, ["127.0.0.1"], _loopback.Port, ["rp=ipp/print"]);
        var endpoint = Assert.Single(IppEndpoint.Choose([secure, plain]));

        var read = await network.ReadAsync(endpoint, CancellationToken.None);

        Assert.NotNull(read.Capabilities);
        Assert.Equal(IppTrustVerdict.Unknown, read.Certificate!.Verdict);
        Assert.Empty(new IppTrustStore(_folder).Certificates);
    }

    [Fact]
    public async Task AReadOfATrustedPrinterWithAChangedCertificateIsNotAnsweredByItsPlainAddress()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        _loopback.Certificate = certificate;
        const string uuid = "4509a320-00a0-008f-00b6-00e0b36a5c50";
        new IppTrustStore(_folder).Trust(new string('a', 64), uuid, "127.0.0.1:" + _loopback.Port, "HP LaserJet");
        var network = Network();
        string[] txt = ["rp=ipp/print", "UUID=" + uuid];
        var secure = new IppService("dnssd-s", "HP LaserJet", true, null, ["127.0.0.1"], _loopback.Port, txt);
        var plain = new IppService("dnssd-p", "HP LaserJet", false, null, ["127.0.0.1"], _loopback.Port, txt);
        var endpoint = Assert.Single(IppEndpoint.Choose([secure, plain]));

        var read = await network.ReadAsync(endpoint, CancellationToken.None);

        Assert.Equal(IppTrustVerdict.Changed, read.Certificate!.Verdict);
        Assert.Null(read.Capabilities);
        Assert.Equal(0, _loopback.PlainConnections);
    }

    [Fact]
    public async Task AnAddressThatDoesNotAnswerIsAskedAgainAndListedWhenItDoes()
    {
        new IppHostList(_folder).Add(_loopback.Address());
        _loopback.Script(LoopbackAnswer.Http(404));
        var network = Network(recheck: TimeSpan.FromMilliseconds(50));

        network.Start();

        await Until(() => network.Hosts.Count == 1 && network.Hosts[0].Listed);
        Assert.Single(network.Services);
        Assert.True(_loopback.Requests.Count >= 2);
    }

    [Fact]
    public async Task AnAddressThatNeverAnswersStaysUnlistedWithItsProblem()
    {
        var address = PrinterAddress.Parse($"127.0.0.1:{ClosedPort()}");
        new IppHostList(_folder).Add(address);
        var network = Network(recheck: TimeSpan.FromMinutes(5));

        network.Start();

        await Until(() => network.Hosts.Count == 1 && network.Hosts[0].Problem is not null);
        var host = network.Hosts[0];
        Assert.False(host.Listed);
        Assert.Equal(address.ToString(), host.Address);
        Assert.Empty(network.Services);
    }

    [Fact]
    public void AnAddressThatAnswersBecomesAServiceTheMergeReads()
    {
        var caps = new PrinterCapabilities { Name = "Office", MakeAndModel = "HP LaserJet", Uuid = "urn:uuid:0b2f1a52-7c61-4f0e-9d6b-3a1c5e8d9f40" };

        var byName = NetworkPrinters.ServiceOf(PrinterAddress.Parse("ipps://printer.local:8631/ipp/print"), caps);
        var byIp = NetworkPrinters.ServiceOf(PrinterAddress.Parse("10.0.0.7"), caps);

        Assert.True(byName.Secure);
        Assert.Equal("printer.local", byName.HostName);
        Assert.Empty(byName.Addresses);
        Assert.Equal(8631, byName.Port);
        Assert.Null(byIp.HostName);
        Assert.Equal(["10.0.0.7"], byIp.Addresses);
        Assert.Contains("UUID=urn:uuid:0b2f1a52-7c61-4f0e-9d6b-3a1c5e8d9f40", byIp.TextAttributes);
        Assert.Equal("Office", byIp.InstanceName);
    }
}
