using System.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class PrinterMappingTests
{
    // MARK: Queue status flags to states

    [Fact]
    public void AQueueWithNothingWrongHasNoStates()
    {
        Assert.Empty(PrinterMapping.QueueStates(PrintQueueStatus.None));
    }

    [Theory]
    [InlineData(PrintQueueStatus.Paused, SystemQueueState.Paused)]
    [InlineData(PrintQueueStatus.Error, SystemQueueState.Error)]
    [InlineData(PrintQueueStatus.PaperProblem, SystemQueueState.Error)]
    [InlineData(PrintQueueStatus.OutOfMemory, SystemQueueState.Error)]
    [InlineData(PrintQueueStatus.Offline, SystemQueueState.Offline)]
    [InlineData(PrintQueueStatus.NotAvailable, SystemQueueState.Offline)]
    [InlineData(PrintQueueStatus.PaperOut, SystemQueueState.PaperOut)]
    [InlineData(PrintQueueStatus.PaperJam, SystemQueueState.PaperJam)]
    [InlineData(PrintQueueStatus.DoorOpen, SystemQueueState.DoorOpen)]
    [InlineData(PrintQueueStatus.TonerLow, SystemQueueState.TonerLow)]
    [InlineData(PrintQueueStatus.NoToner, SystemQueueState.NoToner)]
    [InlineData(PrintQueueStatus.UserIntervention, SystemQueueState.UserIntervention)]
    [InlineData(PrintQueueStatus.ManualFeed, SystemQueueState.UserIntervention)]
    [InlineData(PrintQueueStatus.OutputBinFull, SystemQueueState.UserIntervention)]
    [InlineData(PrintQueueStatus.Printing, SystemQueueState.Busy)]
    [InlineData(PrintQueueStatus.Processing, SystemQueueState.Busy)]
    [InlineData(PrintQueueStatus.IOActive, SystemQueueState.Busy)]
    public void AFlagBecomesItsState(PrintQueueStatus flag, SystemQueueState expected)
    {
        Assert.Equal([expected], PrinterMapping.QueueStates(flag));
    }

    [Fact]
    public void SeveralFlagsGiveEachStateOnceInStateOrder()
    {
        var states = PrinterMapping.QueueStates(
            PrintQueueStatus.Printing | PrintQueueStatus.Busy | PrintQueueStatus.PaperOut | PrintQueueStatus.TonerLow | PrintQueueStatus.Error | PrintQueueStatus.PaperProblem);

        Assert.Equal([SystemQueueState.Error, SystemQueueState.PaperOut, SystemQueueState.TonerLow, SystemQueueState.Busy], states);
    }

    [Fact]
    public void FlagsThatSayNothingAreIgnored()
    {
        Assert.Empty(PrinterMapping.QueueStates(PrintQueueStatus.PowerSave | PrintQueueStatus.WarmingUp | PrintQueueStatus.Waiting));
    }

    [Fact]
    public void StatesBecomeTheProblemsTheSidebarShows()
    {
        var problems = SystemQueueProblems.Describe(PrinterMapping.QueueStates(PrintQueueStatus.PaperJam | PrintQueueStatus.TonerLow));

        Assert.Equal(["Paper jam", "Toner low"], problems.Select(p => p.Title));
    }

    // MARK: Jobs

    [Fact]
    public void NoJobsIsNone()
    {
        Assert.Equal(SystemQueueJobs.None, PrinterMapping.Jobs([], DateTime.Now));
    }

    [Fact]
    public void JobsAreCountedAndTheOldestSetsTheAge()
    {
        var now = new DateTime(2026, 11, 3, 12, 0, 0);
        var jobs = PrinterMapping.Jobs(
            [(PrintJobStatus.Spooling, now.AddMinutes(-2)), (PrintJobStatus.Printing, now.AddMinutes(-9))], now);

        Assert.Equal(new SystemQueueJobs(2, false, 9), jobs);
    }

    [Theory]
    [InlineData(PrintJobStatus.Error)]
    [InlineData(PrintJobStatus.Offline)]
    [InlineData(PrintJobStatus.PaperOut)]
    [InlineData(PrintJobStatus.UserIntervention)]
    [InlineData(PrintJobStatus.Blocked)]
    public void AJobInTroubleIsAJobInError(PrintJobStatus status)
    {
        var now = DateTime.Now;

        Assert.True(PrinterMapping.Jobs([(status, now)], now).AnyInError);
    }

    [Fact]
    public void AJobFromTheFutureIsNotNegativeAge()
    {
        var now = DateTime.Now;

        Assert.Equal(0, PrinterMapping.Jobs([(PrintJobStatus.Spooling, now.AddMinutes(3))], now).OldestMinutes);
    }

    // MARK: Ports

    [Theory]
    [InlineData("FILE:", true)]
    [InlineData("PORTPROMPT:", true)]
    [InlineData("nul:", true)]
    [InlineData("IP_192.168.1.20", false)]
    [InlineData("USB001", false)]
    [InlineData("WSD-1234", false)]
    [InlineData(null, false)]
    public void APortThatPrintsToNoDeviceIsVirtual(string? port, bool virtualPort)
    {
        Assert.Equal(virtualPort, PrinterMapping.IsVirtualPort(port));
    }

    // MARK: Papers

    [Fact]
    public void AnImageableAreaBecomesMarginsInHundredthsOfAMillimetre()
    {
        // Letter in 1/96 inch with 0.25 in (24) around the printable area.
        var entry = PrinterMapping.Entry(816, 1056, 24, 24, 768, 1008);

        Assert.Equal(21590, entry.Width);
        Assert.Equal(27940, entry.Height);
        Assert.Equal(new MediaMargins(635, 635, 635, 635), entry.Margins);
        Assert.False(entry.IsVariable);
    }

    [Fact]
    public void UnevenMarginsStayUneven()
    {
        var entry = PrinterMapping.Entry(100, 200, 4, 8, 90, 180);

        Assert.Equal(new MediaMargins(212, 106, 318, 159), entry.Margins);
    }

    [Fact]
    public void ABorderlessAreaHasZeroMargins()
    {
        var entry = PrinterMapping.Entry(384, 576, 0, 0, 384, 576);

        Assert.True(entry.Margins!.Value.IsZero);
        Assert.NotNull(entry.PrintableArea);
    }

    [Fact]
    public void AnAreaBiggerThanThePaperDoesNotGiveNegativeMargins()
    {
        var entry = PrinterMapping.Entry(100, 100, 0, 0, 120, 120);

        Assert.True(entry.Margins!.Value.IsZero);
    }

    [Fact]
    public void TheEntryLaysOutAsPoints()
    {
        var entry = PrinterMapping.Entry(816, 1056, 24, 24, 768, 1008);
        var area = entry.PrintableArea!.Value;

        Assert.Equal(612, area.Paper.Width, 0.5);
        Assert.Equal(792, area.Paper.Height, 0.5);
        Assert.Equal(18, area.Margins.Left, 0.5);
    }

    [Theory]
    [InlineData(816, 1056, true)]     // Letter
    [InlineData(793.7, 1122.5, true)] // A4
    [InlineData(384, 576, true)]      // 4 x 6 in
    [InlineData(1056, 816, false)]    // landscape
    [InlineData(1122.5, 1587.4, true)] // A3
    [InlineData(500, 700, false)]     // no name
    [InlineData(0, 0, false)]
    public void OnlyNamedAndPhotoPapersAreAskedForTheirArea(double width, double height, bool useful)
    {
        Assert.Equal(useful, PrinterMapping.IsUsefulPaper(width, height));
    }

    // MARK: Capabilities

    private static PrinterCapabilities Caps(
        Duplexing[]? duplex = null, OutputColor[]? colors = null, int? copies = null, Collation[]? collation = null,
        OutputQuality[]? quality = null) =>
        PrinterMapping.Capabilities("HP", "HP Driver", duplex ?? [], colors ?? [], copies, collation ?? [], quality ?? [], []);

    [Fact]
    public void TraysAndPaperTypesBecomeTheKeywordsAPrinterWouldList()
    {
        var caps = PrinterMapping.Capabilities("HP", null, [], [], null, [], [], [], false,
            [InputBin.AutoSelect, InputBin.Manual, InputBin.Cassette],
            [PageMediaType.Plain, PageMediaType.Stationery, PageMediaType.PhotographicGlossy, PageMediaType.Unknown]);
        Assert.Equal(["manual", "tray-1"], caps.MediaSourceSupported);
        Assert.Equal(["stationery", "photographic-glossy"], caps.MediaTypeSupported);
        Assert.Empty(Caps().MediaSourceSupported);
        Assert.Empty(Caps().MediaTypeSupported);
        Assert.Equal(InputBin.Manual, PrinterMapping.Tray("manual"));
        Assert.Null(PrinterMapping.Tray("tray-9"));
        Assert.Equal(PageMediaType.CardStock, PrinterMapping.PaperType("cardstock"));
    }

    [Fact]
    public void ADriverWithoutDuplexPrintsOneSide()
    {
        Assert.Equal(["one-sided"], Caps().SidesSupported);
    }

    [Fact]
    public void DuplexBecomesTheSidesTheLayoutAsksFor()
    {
        var caps = Caps(duplex: [Duplexing.OneSided, Duplexing.TwoSidedLongEdge, Duplexing.TwoSidedShortEdge]);

        Assert.Equal(["one-sided", "two-sided-long-edge", "two-sided-short-edge"], caps.SidesSupported);
    }

    [Fact]
    public void ShortEdgeAloneIsNotLongEdge()
    {
        Assert.DoesNotContain("two-sided-long-edge", Caps(duplex: [Duplexing.TwoSidedShortEdge]).SidesSupported);
    }

    [Fact]
    public void ColorAndGrayBecomeTheColorModes()
    {
        Assert.Equal(["color", "monochrome"], Caps(colors: [OutputColor.Color, OutputColor.Grayscale]).PrintColorModesSupported);
        Assert.Equal(["monochrome"], Caps(colors: [OutputColor.Monochrome]).PrintColorModesSupported);
    }

    [Fact]
    public void CopiesAndCollationAreTheDriversOwn()
    {
        var caps = Caps(copies: 999, collation: [Collation.Collated, Collation.Uncollated]);

        Assert.Equal((1, 999), caps.CopiesSupported);
        Assert.Contains("separate-documents-collated-copies", caps.MultipleDocumentHandlingSupported);
        Assert.Equal((1, 1), Caps().CopiesSupported);
        Assert.Empty(Caps(collation: [Collation.Uncollated]).MultipleDocumentHandlingSupported);
    }

    [Fact]
    public void QualityBecomesPrintQuality()
    {
        var caps = Caps(quality: [OutputQuality.Draft, OutputQuality.Normal, OutputQuality.High, OutputQuality.Photographic, OutputQuality.Automatic]);

        Assert.Equal([3, 4, 5], caps.PrintQualitySupported);
    }

    // MARK: Windows services and networks

    [Theory]
    [InlineData(WindowsSystemStatus.ServiceRunning, null, ServiceStatus.Running)]
    [InlineData(WindowsSystemStatus.ServiceStartPending, null, ServiceStatus.Starting)]
    [InlineData(WindowsSystemStatus.ServiceContinuePending, null, ServiceStatus.Starting)]
    [InlineData(WindowsSystemStatus.ServiceStopPending, null, ServiceStatus.Stopping)]
    [InlineData(WindowsSystemStatus.ServicePausePending, null, ServiceStatus.Paused)]
    [InlineData(WindowsSystemStatus.ServicePaused, null, ServiceStatus.Paused)]
    [InlineData(WindowsSystemStatus.ServiceStopped, null, ServiceStatus.Stopped)]
    [InlineData(WindowsSystemStatus.ServiceStopped, 3, ServiceStatus.Stopped)]
    [InlineData(WindowsSystemStatus.ServiceStopped, WindowsSystemStatus.ServiceDisabledStart, ServiceStatus.Disabled)]
    [InlineData(99, null, ServiceStatus.Unknown)]
    public void AServiceStateBecomesAStatus(int state, int? startType, ServiceStatus expected)
    {
        Assert.Equal(expected, WindowsSystemStatus.Service(state, startType));
    }

    [Theory]
    [InlineData(WindowsSystemStatus.NetworkCategoryPublic, NetworkStatus.PublicNetwork)]
    [InlineData(WindowsSystemStatus.NetworkCategoryPrivate, NetworkStatus.PrivateNetwork)]
    [InlineData(WindowsSystemStatus.NetworkCategoryDomainAuthenticated, NetworkStatus.DomainNetwork)]
    [InlineData(7, NetworkStatus.Unknown)]
    public void ANetworkCategoryBecomesAStatus(int category, NetworkStatus expected)
    {
        Assert.Equal(expected, WindowsSystemStatus.Network(category));
    }
}
