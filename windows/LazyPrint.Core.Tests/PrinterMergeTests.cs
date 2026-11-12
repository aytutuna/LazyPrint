using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrinterMergeTests.swift: the same cases.

public class PrinterMergeTests
{
    private const string HpUuid = "4509a320-00a0-008f-00b6-9c93b9a1c2d3";

    private static SystemPrinter Queue(string name, string? port = null, string? model = null, bool isDefault = false,
                                       bool isVirtual = false, SystemQueueState[]? states = null, string? uuid = null) =>
        new(name, model, port, isDefault, isVirtual, states ?? [], SystemQueueJobs.None, uuid);

    private static IppService Net(string instance, string? uuid = null, string address = "192.168.1.20", string? host = null,
                                  string model = "HP LaserJet Pro M404dn", bool secure = false)
    {
        var txt = new List<string> { $"ty={model}" };
        if (uuid is not null) txt.Add($"UUID={uuid}");
        return new IppService($"ipp:{instance}", instance, secure, host, [address], 631, txt);
    }

    private static IReadOnlyList<PrinterInfo> Merge(SystemPrinter[] system, IppService[] network, bool demo = false) =>
        PrinterMerge.Merge(system, network, demo);

    // MARK: - Matching a queue to its IPP printer

    public static TheoryData<string, SystemPrinter, IppService, bool> Pairs => new()
    {
        { "the queue's own UUID", Queue("Office", uuid: HpUuid.ToUpperInvariant()), Net("HP A1B2C3", HpUuid), true },
        { "a UUID in a dnssd URI", Queue("Office", "dnssd://Other%20name._ipp._tcp.local/?uuid=" + HpUuid), Net("HP A1B2C3", HpUuid), true },
        { "a different UUID is a different printer", Queue("HP LaserJet Pro M404dn", uuid: "11111111-2222-3333-4444-555555555555"), Net("HP LaserJet Pro M404dn", HpUuid), false },
        { "a standard TCP/IP port", Queue("Office", "IP_192.168.1.20"), Net("HP A1B2C3", HpUuid), true },
        { "a TCP/IP port with a suffix", Queue("Office", "IP_192.168.1.20_1"), Net("HP A1B2C3", HpUuid), true },
        { "a port with a socket", Queue("Office", "192.168.1.20:9100"), Net("HP A1B2C3", HpUuid), true },
        { "an IPP port URL", Queue("Office", "http://192.168.1.20:631/ipp/print"), Net("HP A1B2C3", HpUuid), true },
        { "an ipp URI with a host name", Queue("Office", "ipp://hpa1b2c3.local./ipp/print"), Net("HP A1B2C3", HpUuid, host: "HPA1B2C3.local"), true },
        { "an ipps URI with a user", Queue("Office", "ipps://me@192.168.1.20/ipp/print"), Net("HP A1B2C3", HpUuid, secure: true), true },
        { "another address", Queue("Office", "IP_192.168.1.21"), Net("HP A1B2C3", HpUuid), false },
        { "an address that only starts the same", Queue("Office", "IP_192.168.1.2"), Net("HP A1B2C3", HpUuid), false },
        { "a dnssd service name", Queue("Office", "dnssd://HP%20LaserJet%20Pro%20M404dn%20(A1B2C3)._ipp._tcp.local/"), Net("HP LaserJet Pro M404dn (A1B2C3)"), true },
        { "a WSD port says nothing", Queue("Office", "WSD-7a1b6c2e-0000-4a4e-8d2f-000000000001"), Net("HP A1B2C3"), false },
        { "the same name", Queue("hp laserjet pro m404dn"), Net("HP LaserJet Pro M404dn"), true },
        { "the same name without its copy number", Queue("HP LaserJet Pro M404dn (Copy 1)"), Net("HP LaserJet Pro M404dn"), true },
        { "the driver's name does not match", Queue("Office", model: "HP Universal Printing PCL 6"), Net("HP LaserJet Pro M404dn"), false },
        { "the model is the printer's name", Queue("Office", model: "HP LaserJet Pro M404dn"), Net("HP LaserJet Pro M404dn"), true },
        { "a similar name is not the same", Queue("HP LaserJet Pro M404n"), Net("HP LaserJet Pro M404dn"), false },
        { "the same name, but a port that points elsewhere", Queue("HP LaserJet Pro M404dn", "IP_192.168.1.22"), Net("HP A1B2C3", HpUuid), false },
        { "a name that is the service's name", Queue("HP LaserJet Pro M404dn (A1B2C3)"), Net("HP LaserJet Pro M404dn (A1B2C3)"), true },
        { "a name with another printer's mark", Queue("HP LaserJet Pro M404dn (D4E5F6)"), Net("HP LaserJet Pro M404dn (A1B2C3)"), false },
        { "a queue without anything to go by", Queue("Office"), Net("HP LaserJet Pro M404dn"), false },
    };

    [Theory]
    [MemberData(nameof(Pairs))]
    public void Merge_FollowsTheRules(string name, SystemPrinter queue, IppService service, bool merged)
    {
        var rows = Merge([queue], [service]);
        Assert.True(merged == (rows.Count == 1), name);
        if (merged)
        {
            Assert.Equal(PrinterRoute.System, rows[0].Route);
            Assert.NotNull(rows[0].IppEndpoint);
        }
        else
        {
            Assert.Equal([PrinterRoute.System, PrinterRoute.Ipp], rows.Select(r => r.Route));
        }
    }

    [Fact]
    public void Merge_UuidBeatsAHostThatPointsElsewhere()
    {
        var other = Net("Other printer", "99999999-0000-0000-0000-000000000000", "192.168.1.30", model: "Other");
        var mine = Net("HP A1B2C3", HpUuid);
        var rows = Merge([Queue("Office", "IP_192.168.1.30", uuid: HpUuid)], [other, mine]);
        Assert.Equal("system:Office", rows[0].Id);
        Assert.Equal(["Office", "Other"], rows.Select(r => r.Name));
    }

    [Fact]
    public void Merge_AMergedRow_IsRoutedThroughTheQueueAndKeepsTheEndpoint()
    {
        var row = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20", model: "HP Universal Printing PCL 6", isDefault: true)],
                                      [Net("HP A1B2C3", HpUuid)]));
        Assert.Equal("system:Office", row.Id);
        Assert.Equal("Office", row.Name);
        Assert.Equal("HP LaserJet Pro M404dn", row.Model);
        Assert.Equal("192.168.1.20", row.Address);
        Assert.Equal(PrinterRoute.System, row.Route);
        Assert.Equal("uuid:4509a32000a0008f00b69c93b9a1c2d3", row.IppEndpoint!.Key);
        Assert.True(row.IsDefault);
    }

    [Fact]
    public void Merge_AWsdPortWithAServiceSuffix_HasNoAddress()
    {
        var row = Assert.Single(Merge([Queue("Office", "WSD-7a1b6c2e-0000-4a4e-8d2f-000000000001.0064")], []));
        Assert.Null(row.Address);
    }

    [Fact]
    public void Merge_ASecondQueueForTheSamePrinter_IsARowOfItsOwn()
    {
        var rows = Merge([Queue("HP A", "IP_192.168.1.20"), Queue("HP B", "IP_192.168.1.20")], [Net("HP A1B2C3", HpUuid)]);
        Assert.Equal(["system:HP A", "system:HP B"], rows.Select(r => r.Id));
        Assert.Null(rows[1].IppEndpoint);
    }

    [Fact]
    public void Merge_TwoPrintersOfOneModel_AreNotSwapped()
    {
        var a = Net("HP LaserJet Pro M404dn (AAAAAA)", "aaaaaaaa-0000-0000-0000-000000000001", "192.168.1.20");
        var b = Net("HP LaserJet Pro M404dn (BBBBBB)", "bbbbbbbb-0000-0000-0000-000000000002", "192.168.1.30");
        var rows = Merge([Queue("HP LaserJet Pro M404dn (BBBBBB)"), Queue("HP LaserJet Pro M404dn (AAAAAA)")], [a, b]);
        Assert.Equal(["192.168.1.30", "192.168.1.20"], rows.Select(r => r.Address));
        Assert.Equal(["bbbbbbbb-0000-0000-0000-000000000002", "aaaaaaaa-0000-0000-0000-000000000001"],
                     rows.Select(r => r.IppEndpoint!.Uuid!.ToLowerInvariant()));
    }

    [Fact]
    public void Merge_ANameThatFitsTwoPrinters_MatchesNone()
    {
        var a = Net("HP LaserJet Pro M404dn (AAAAAA)", "aaaaaaaa-0000-0000-0000-000000000001", "192.168.1.20");
        var b = Net("HP LaserJet Pro M404dn (BBBBBB)", "bbbbbbbb-0000-0000-0000-000000000002", "192.168.1.30");
        var rows = Merge([Queue("HP LaserJet Pro M404dn")], [a, b]);
        Assert.Equal([PrinterRoute.System, PrinterRoute.Ipp, PrinterRoute.Ipp], rows.Select(r => r.Route));
        Assert.Null(rows[0].IppEndpoint);
    }

    [Fact]
    public void Merge_AWeakNameMatch_DoesNotTakeThePrinterFromTheQueueThatPointsAtIt()
    {
        var rows = Merge([Queue("HP LaserJet Pro M404dn", "USB001"), Queue("Office", "IP_192.168.1.20")], [Net("HP A1B2C3", HpUuid)]);
        Assert.Equal(["system:HP LaserJet Pro M404dn", "system:Office"], rows.Select(r => r.Id));
        Assert.Null(rows[0].IppEndpoint);
        Assert.NotNull(rows[1].IppEndpoint);
    }

    [Fact]
    public void Merge_ASystemRowsId_DoesNotDependOnFindingItsTwin()
    {
        var found = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20")], [Net("HP A1B2C3", HpUuid)]));
        var asleep = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20")], []));
        Assert.Equal("system:Office", found.Id);
        Assert.Equal(found.Id, asleep.Id);
    }

    // MARK: - Ids, order, left-out queues

    [Fact]
    public void Merge_Ids_AreStable()
    {
        var rows = Merge([Queue("Brother HL"), Queue("Office", "IP_192.168.1.20")],
                         [Net("HP A1B2C3", HpUuid), Net("Epson", "AAAAAAAA-0000-0000-0000-000000000001", "192.168.1.40", model: "Epson ET"),
                          Net("Canon", null, "192.168.1.50", model: "Canon")],
                         demo: true);
        Assert.Equal(["system:Brother HL", "system:Office", "ipp:aaaaaaaa-0000-0000-0000-000000000001", "ipp:name:canon", "demo"],
                     rows.Select(r => r.Id));
        Assert.Equal([PrinterRoute.System, PrinterRoute.System, PrinterRoute.Ipp, PrinterRoute.Ipp, PrinterRoute.Demo],
                     rows.Select(r => r.Route));
    }

    [Fact]
    public void Merge_ANetworkPrinter_IsAnIppRowWithItsAddress()
    {
        var row = Assert.Single(Merge([], [Net("HP A1B2C3", HpUuid)]));
        Assert.Equal("HP LaserJet Pro M404dn", row.Name);
        Assert.Equal("192.168.1.20", row.Address);
        Assert.Equal(PrinterState.Unknown, row.State);
        Assert.False(row.IsDefault);
        Assert.Empty(row.Problems);
    }

    [Theory]
    [InlineData("Microsoft Print to PDF")]
    [InlineData("Microsoft XPS Document Writer")]
    [InlineData("OneNote (Desktop)")]
    [InlineData("Send To OneNote 16")]
    [InlineData("Fax")]
    [InlineData("Brother MFC-L2710DW (FAX)")]
    public void Merge_VirtualQueues_AreLeftOut(string name)
    {
        Assert.Empty(Merge([Queue(name)], []));
    }

    [Fact]
    public void Merge_AQueueTheSystemCallsVirtual_IsLeftOut()
    {
        Assert.Empty(Merge([Queue("Save as PDF", isVirtual: true), Queue("Anything", "PORTPROMPT:"), Queue("Anything else", "SHRFAX:")], []));
        Assert.Equal(["Faxon Laser", "Brother FAX-2840"], Merge([Queue("Faxon Laser"), Queue("Brother FAX-2840", "USB001")], []).Select(r => r.Name));
    }

    [Fact]
    public void Merge_TheDemoPrinter_IsLastAndOnlyWhenAsked()
    {
        var system = new[] { Queue("Office") };
        var network = new[] { Net("HP A1B2C3", HpUuid) };
        Assert.DoesNotContain(Merge(system, network), r => r.Route == PrinterRoute.Demo);
        var rows = Merge(system, network, demo: true);
        Assert.Equal(PrinterRoute.Demo, rows[^1].Route);
        Assert.Equal("demo", rows[^1].Id);
        Assert.Equal("Demo Printer", rows[^1].Name);
        Assert.Equal(PrinterState.Idle, rows[^1].State);
        Assert.Equal([PrinterRoute.System, PrinterRoute.Ipp, PrinterRoute.Demo], rows.Select(r => r.Route));
        Assert.Equal(["demo"], Merge([], [], demo: true).Select(r => r.Id));
    }

    // MARK: - States and problems of a queue

    [Fact]
    public void Merge_AQueuesStates_BecomeStateAndProblems()
    {
        var rows = Merge(
        [
            Queue("A"),
            Queue("B", states: [SystemQueueState.Busy]),
            Queue("C", states: [SystemQueueState.PaperOut, SystemQueueState.TonerLow]),
            Queue("D", states: [SystemQueueState.Offline, SystemQueueState.PaperJam]),
            Queue("E", states: [SystemQueueState.TonerLow]),
        ], []);
        Assert.Equal([PrinterState.Idle, PrinterState.Printing, PrinterState.Stopped, PrinterState.Offline, PrinterState.Idle],
                     rows.Select(r => r.State));
        Assert.Equal(["Out of paper", "Toner low"], rows[2].Problems.Select(p => p.Title));
        Assert.Equal(["Printer offline"], rows[3].Problems.Select(p => p.Title));
        Assert.Empty(rows[0].Problems);
        Assert.Empty(rows[1].Problems);
    }

    // MARK: - Refresh

    [Fact]
    public void Refresh_TakesStateProblemsAndSuppliesFromTheCapabilities()
    {
        var row = Assert.Single(Merge([], [Net("Epson", "AAAAAAAA-0000-0000-0000-000000000001")]));
        var caps = IppFixtures.Capabilities("epson-ecotank");
        var refreshed = PrinterMerge.Refresh(row, caps);
        Assert.Equal(PrinterState.Idle, refreshed.State);
        Assert.Equal(["Black", "Cyan", "Magenta", "Yellow"], refreshed.Supplies.Select(s => s.Name));
        Assert.Equal([80, 55, 40, 70], refreshed.Supplies.Select(s => s.Level));
        Assert.Equal("#FF00FF", refreshed.Supplies[2].Color);
        Assert.Equal(row.Id, refreshed.Id);
    }

    [Fact]
    public void Refresh_LowSuppliesAndProblems()
    {
        var row = Assert.Single(Merge([], [Net("Canon", "AAAAAAAA-0000-0000-0000-000000000001")]));
        var refreshed = PrinterMerge.Refresh(row, IppFixtures.Capabilities("canon-pixma"));
        Assert.Equal(["Ink low"], refreshed.Problems.Select(p => p.Title));
        Assert.Contains(refreshed.Supplies, s => s.IsLow);
        Assert.Contains(refreshed.Supplies, s => !s.IsLow);
    }

    [Fact]
    public void Refresh_SuppliesWithoutALevel_HaveNone_AndWasteIsLeftOut()
    {
        var caps = new PrinterCapabilities
        {
            Supplies =
            [
                new MarkerSupply("Black", "", "toner", -3, null, null),
                new MarkerSupply("Cyan", "#00FFFF", "ink", -1, 10, 100),
                new MarkerSupply("Magenta", "#FF00FF", "ink", 5, 10, 100),
                new MarkerSupply("Yellow", "#FFFF00", "ink", 10, 10, 100),
                new MarkerSupply("Waste", "", "waste-toner", 90, null, null),
            ],
        };
        var refreshed = PrinterMerge.Refresh(Assert.Single(Merge([Queue("Office")], [])), caps);
        Assert.Equal(
            [new Supply("Black", null, null, false), new Supply("Cyan", "#00FFFF", null, false),
             new Supply("Magenta", "#FF00FF", 5, true), new Supply("Yellow", "#FFFF00", 10, true)],
            refreshed.Supplies);
    }

    [Fact]
    public void Refresh_StoppedAndProcessing()
    {
        var row = Assert.Single(Merge([], [Net("HP A1B2C3", HpUuid)]));
        var stopped = PrinterMerge.Refresh(row, new PrinterCapabilities { State = IppPrinterState.Stopped, StateReasons = ["media-empty-error"] });
        Assert.Equal(PrinterState.Stopped, stopped.State);
        Assert.Equal(["Out of paper"], stopped.Problems.Select(p => p.Title));
        Assert.Equal(PrinterState.Printing, PrinterMerge.Refresh(row, new PrinterCapabilities { State = IppPrinterState.Processing }).State);
    }

    [Fact]
    public void Refresh_ASystemRow_KeepsItsQueuesProblemsAndState()
    {
        var row = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20", states: [SystemQueueState.Paused, SystemQueueState.PaperOut])],
                                      [Net("HP A1B2C3", HpUuid)]));
        var caps = new PrinterCapabilities { State = IppPrinterState.Idle, StateReasons = ["media-empty-error"] };
        var refreshed = PrinterMerge.Refresh(row, caps);
        Assert.Equal(PrinterState.Stopped, refreshed.State);
        Assert.Equal(["Printer paused", "Out of paper"], refreshed.Problems.Select(p => p.Title));
        Assert.Equal(refreshed, PrinterMerge.Refresh(refreshed, caps));

        var healthy = PrinterMerge.Refresh(Assert.Single(Merge([Queue("Office", "IP_192.168.1.20")], [Net("HP A1B2C3", HpUuid)])), caps);
        Assert.Equal(PrinterState.Idle, healthy.State);
        Assert.Equal(["Out of paper"], healthy.Problems.Select(p => p.Title));
    }

    [Fact]
    public void Refresh_ASystemRowWhoseTwinDidNotAnswer_IsAsTheQueueSays()
    {
        var idle = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20")], [Net("HP A1B2C3", HpUuid)]));
        var unanswered = PrinterMerge.Refresh(idle, null);
        Assert.Equal(PrinterState.Idle, unanswered.State);
        Assert.Empty(unanswered.Problems);

        var paused = Assert.Single(Merge([Queue("Office", "IP_192.168.1.20", states: [SystemQueueState.Paused])], [Net("HP A1B2C3", HpUuid)]));
        var still = PrinterMerge.Refresh(PrinterMerge.Refresh(paused, IppFixtures.Capabilities("hp-laserjet")), null);
        Assert.Equal(PrinterState.Stopped, still.State);
        Assert.Equal(["Printer paused"], still.Problems.Select(p => p.Title));
    }

    [Fact]
    public void Refresh_APrinterThatDidNotAnswer_IsOffline()
    {
        var row = PrinterMerge.Refresh(Assert.Single(Merge([], [Net("HP A1B2C3", HpUuid)])), IppFixtures.Capabilities("hp-laserjet"));
        var offline = PrinterMerge.Refresh(row, null);
        Assert.Equal(PrinterState.Offline, offline.State);
        Assert.Equal(["Printer offline"], offline.Problems.Select(p => p.Title));
        Assert.Empty(offline.Supplies);
    }
}
