using System.IO;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

// Network printers in the view model's list, their status, the troubleshooter's snapshot and printers.txt, on stand-ins.
public sealed class NetworkListTests
{
    private const string Uuid = "0b2f1a52-7c61-4f0e-9d6b-3a1c5e8d9f40";

    private static IppService Service(string name = "HP LaserJet (A1B2C3)", string address = "192.168.1.20") =>
        new("dnssd:" + name, name, false, "hp.local", [address], 631, [$"UUID={Uuid}", "ty=HP LaserJet", "rp=ipp/print"]);

    private static AddressCheck Answer(PrinterCapabilities caps) => new(PrinterAddress.Parse("192.168.1.20"), caps, null, null);

    private static async Task Settle(Rig rig)
    {
        rig.Network.Raise();
        for (int i = 0; i < 100 && rig.Model.Printers.Count < 2; i++) await Task.Delay(20);
        await rig.Model.RefreshNetworkStatusAsync();
    }

    [Fact]
    public async Task APrinterFoundOnTheNetworkIsListedAndAskedForItsState()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        rig.Network.Answers["HP LaserJet"] = Answer(new PrinterCapabilities { State = IppPrinterState.Stopped, StateReasons = ["media-empty-error"] });
        rig.Model.StartNetwork();
        await Settle(rig);

        var row = Assert.Single(rig.Model.Printers, p => p.Info.Route == PrinterRoute.Ipp);
        Assert.Equal("ipp:" + Uuid, row.Id);
        Assert.Equal("Out of paper", row.Problem);
        Assert.Equal(PrinterState.Stopped, row.Info.State);
    }

    [Fact]
    public async Task ThePrinterInUseGetsItsCapabilitiesFromTheNetwork()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        rig.Network.Answers["HP LaserJet"] = Answer(Rig.Duplex());
        rig.Model.StartNetwork();
        await Settle(rig);

        await rig.Model.SelectPrinterAsync("ipp:" + Uuid);

        Assert.Equal("ipp:" + Uuid, rig.Model.SelectedPrinter?.Id);
        Assert.Contains("two-sided-long-edge", rig.Model.SelectedCapabilities!.SidesSupported);
    }

    [Fact]
    public async Task AQueueThatPointsAtANetworkPrinterShowsItsInkAndKeepsItsRoute()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Network.Found.Add(Service());
        rig.Network.Answers["HP LaserJet"] = Answer(new PrinterCapabilities
        {
            Supplies = [new MarkerSupply("Black", "#000000", "toner", 12, 15, null)],
        });
        await rig.Model.RefreshPrintersAsync();
        rig.Model.StartNetwork();
        await Settle(rig);

        var row = rig.Model.Printers.Single(p => p.Id == "system:HP LaserJet");
        Assert.Equal(PrinterRoute.System, row.Info.Route);
        Assert.NotNull(row.Info.IppEndpoint);
        var supply = Assert.Single(row.Info.Supplies);
        Assert.True(supply.IsLow);
        Assert.DoesNotContain(rig.Model.Printers, p => p.Info.Route == PrinterRoute.Ipp);
    }

    [Fact]
    public async Task ANetworkPrinterThatDoesNotAnswerIsOffline()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        rig.Model.StartNetwork();
        await Settle(rig);

        var row = Assert.Single(rig.Model.Printers, p => p.Info.Route == PrinterRoute.Ipp);
        Assert.Equal(PrinterState.Offline, row.Info.State);
        Assert.Equal("Printer offline", row.Problem);
    }

    [Fact]
    public async Task TheStatusIsAskedAgainOnEveryRefreshAndOnlyNewPrintersOtherwise()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        rig.Network.Answers["HP LaserJet"] = Answer(Rig.Duplex());
        rig.Model.StartNetwork();
        await Settle(rig);
        int first = rig.Network.Reads;

        await rig.Model.RefreshNetworkStatusAsync(onlyNew: true);
        Assert.Equal(first, rig.Network.Reads);

        await rig.Model.RefreshNetworkStatusAsync();
        Assert.Equal(first + 1, rig.Network.Reads);
    }

    [Fact]
    public async Task RefreshAsksTheNetworkToSearchAgain()
    {
        using var rig = new Rig();
        rig.Model.RefreshNetwork();

        Assert.Equal(1, rig.Network.Restarts);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task TheSnapshotHasTheSearchTheAddressesTheSpoolerAndTheNetwork()
    {
        using var rig = new Rig();
        rig.Diagnostics.SpoolerState = ServiceStatus.Stopped;
        rig.Diagnostics.NetworkState = NetworkStatus.PublicNetwork;
        rig.Network.State = DiscoveryStatus.Unavailable;
        rig.Network.Detail = "access denied";
        rig.Network.HostList.Add(new ManualHostStatus("192.168.1.99", false, "Can't reach 192.168.1.99: it did not answer in time"));
        await rig.Model.ReadSystemStateAsync();

        var snapshot = rig.Model.TroubleshootSnapshot();

        Assert.Equal(AppPlatform.Windows, snapshot.Platform);
        Assert.Equal(ServiceStatus.Stopped, snapshot.Spooler);
        Assert.Equal(NetworkStatus.PublicNetwork, snapshot.Network);
        Assert.Equal(DiscoveryStatus.Unavailable, snapshot.Discovery);
        Assert.Equal("access denied", snapshot.DiscoveryDetail);
        Assert.Equal("192.168.1.99", Assert.Single(snapshot.ManualHosts).Address);

        var ids = Troubleshooter.Diagnose(snapshot).Select(check => check.Id).ToList();
        Assert.Contains("spooler", ids);
        Assert.Contains("network", ids);
        Assert.Contains("discovery", ids);
        Assert.Contains("manualHost:192.168.1.99", ids);
    }

    [Fact]
    public async Task CopyDiagnosticsHasThePrintersThenTheChecks()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Network.Found.Add(Service("Brother (D4E5F6)", "192.168.1.30"));
        await rig.Model.RefreshPrintersAsync();
        rig.Model.StartNetwork();
        await Settle(rig);

        Assert.True(rig.Model.CopyDiagnostics(rig.Model.TroubleshootSnapshot()));

        string text = rig.Diagnostics.Copied!;
        Assert.StartsWith("Why isn't my printer listed?", text);
        Assert.Contains("Print queues", text);
        Assert.Contains("HP LaserJet | driver Driver | port IP_192.168.1.20", text);
        Assert.Contains("Brother (D4E5F6) | ipp | hp.local | 192.168.1.30 | port 631", text);
        Assert.Contains("system:HP LaserJet | System", text);
        Assert.Contains("printer found", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task PrintersTxtIsWrittenWhenThingsChange()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        await rig.Model.RefreshPrintersAsync();

        string path = Path.Combine(rig.LogDirectory, "printers.txt");
        Assert.Contains("system:HP LaserJet", File.ReadAllText(path));

        rig.Spooler.Queue.Add(Rig.Queue("Brother"));
        await rig.Model.RefreshPrintersAsync();
        Assert.Contains("system:Brother", File.ReadAllText(path));
    }

    [Fact]
    public async Task AChangedCertificateIsAskedAboutWhenThePrinterIsChosenAndTrustedOnYes()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        var certificate = new IppCertificateException(IppTrustVerdict.Changed, "HP LaserJet", Uuid, "192.168.1.20:631", "ab12cd34", "CN=HP");
        rig.Network.Answers["HP LaserJet"] = new AddressCheck(PrinterAddress.Parse("ipps://192.168.1.20"), null, certificate, null);
        var asked = new List<IppCertificateException>();
        rig.Model.ConfirmCertificate = c =>
        {
            asked.Add(c);
            rig.Network.Answers["HP LaserJet"] = Answer(Rig.Duplex());
            return Task.FromResult(true);
        };
        rig.Model.StartNetwork();
        await Settle(rig);
        Assert.Empty(asked); // the background read never asks

        await rig.Model.SelectPrinterAsync("ipp:" + Uuid);

        Assert.Same(certificate, Assert.Single(asked));
        Assert.Same(certificate, Assert.Single(rig.Network.Trusted));
        Assert.NotNull(rig.Model.SelectedCapabilities);
    }

    [Fact]
    public async Task ARefusedCertificateTrustsNothing()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        var certificate = new IppCertificateException(IppTrustVerdict.Unknown, "HP LaserJet", Uuid, "192.168.1.20:631", "ab12cd34", "CN=HP");
        rig.Network.Answers["HP LaserJet"] = new AddressCheck(PrinterAddress.Parse("ipps://192.168.1.20"), null, certificate, null);
        rig.Model.ConfirmCertificate = _ => Task.FromResult(false);
        rig.Model.StartNetwork();
        await Settle(rig);

        await rig.Model.SelectPrinterAsync("ipp:" + Uuid);

        Assert.Empty(rig.Network.Trusted);
        Assert.Null(rig.Model.SelectedCapabilities);
    }

    [Fact]
    public async Task APrinterAddedByAddressIsListedAndChosen()
    {
        using var rig = new Rig();
        rig.Network.Found.Add(Service());
        rig.Network.Answers["HP LaserJet"] = Answer(Rig.Duplex());
        rig.Model.StartNetwork();
        await Settle(rig);

        await rig.Model.SelectAddedAsync(PrinterAddress.Parse("192.168.1.20"));

        Assert.Equal("ipp:" + Uuid, rig.Model.SelectedPrinter?.Id);
    }
}
