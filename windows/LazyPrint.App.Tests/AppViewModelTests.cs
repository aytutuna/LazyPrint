using System.IO;
using LazyPrint.App;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class AppViewModelTests
{
    // MARK: The printer list

    [Fact]
    public async Task PrinterListIsTheSpoolersQueuesThenTheDemoPrinter()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Queue.Add(Rig.Queue("Brother"));
        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(["system:HP LaserJet", "system:Brother", "demo"], rig.Model.Printers.Select(p => p.Id));
        Assert.True(rig.Model.HasRealPrinters);
    }

    [Fact]
    public async Task VirtualQueuesAreLeftOut()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("Microsoft Print to PDF"));
        rig.Spooler.Queue.Add(Rig.Queue("OneNote (Desktop)"));
        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(["demo"], rig.Model.Printers.Select(p => p.Id));
        Assert.False(rig.Model.HasRealPrinters);
    }

    [Fact]
    public async Task DemoPrinterIsUsedOnlyWhenItIsChosen()
    {
        using var rig = new Rig();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);

        Assert.Null(rig.Model.SelectedPrinter);
        Assert.Null(rig.Model.SelectedCapabilities);
        Assert.False(rig.Model.CanPrint);
        Assert.Equal(PrintText.NoPrinterReason, rig.Model.PrintDisabledReason);

        await rig.Model.SelectPrinterAsync("demo");

        Assert.Equal("demo", rig.Model.SelectedPrinter?.Id);
        Assert.NotNull(rig.Model.SelectedCapabilities);
        Assert.True(rig.Model.CanPrint);
    }

    [Fact]
    public async Task ATextDocumentIsLaidOutOnTheChosenPaper()
    {
        using var rig = new Rig();
        await rig.Model.RefreshPrintersAsync();
        rig.Model.Settings.PaperId = "letter";
        await rig.Model.AddFilesAsync(["a.txt", "b.pdf"]);
        var letter = PaperSizes.PointsOf("letter")!.Value;
        Assert.Equal(letter, rig.Model.Documents[0].Pages[0]);

        rig.Model.Settings.PaperId = "a5";
        rig.Model.SettingsEdited();

        var a5 = PaperSizes.PointsOf("a5")!.Value;
        Assert.Equal(a5, Assert.Single(rig.Model.Documents[0].Pages));
        Assert.Equal(letter, rig.Model.Documents[1].Pages[0]);
        Assert.Equal(a5, rig.Model.Plan()!.Plan.Sheets[0].Front.Placements[0].Page.Size);
    }

    [Fact]
    public async Task TheDefaultPrinterIsUsedUntilOneIsChosen()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet"));
        rig.Spooler.Queue.Add(Rig.Queue("Brother", isDefault: true));
        await rig.Model.RefreshPrintersAsync();
        Assert.Equal("system:Brother", rig.Model.SelectedPrinter?.Id);

        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        Assert.Equal("system:HP LaserJet", rig.Model.SelectedPrinter?.Id);
    }

    [Fact]
    public async Task APrinterThatWentAwayIsNotUsed()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Queue.Add(Rig.Queue("Brother"));
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.SelectPrinterAsync("system:Brother");

        rig.Spooler.Queue.RemoveAt(1);
        await rig.Model.RefreshPrintersAsync();

        Assert.Equal("system:HP LaserJet", rig.Model.SelectedPrinter?.Id);
    }

    [Fact]
    public async Task TheDefaultStandingInForAGonePrinterDoesNotTakeItsPaper()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Queue.Add(Rig.Queue("Brother"));
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        rig.Model.Settings.PaperId = "a5";
        rig.Model.SettingsEdited();
        await rig.Model.SelectPrinterAsync("system:Brother");
        rig.Spooler.Queue.RemoveAt(1);
        await rig.Model.RefreshPrintersAsync();

        rig.Model.Settings.PaperId = "legal";
        rig.Model.SettingsEdited();
        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        Assert.Equal("a5", rig.Model.Settings.PaperId);
    }

    [Fact]
    public async Task ARowSaysWhatIsWrongWithItsPrinter()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", true, SystemQueueState.PaperOut));
        await rig.Model.RefreshPrintersAsync();

        var row = rig.Model.Printers[0];
        Assert.Equal("Out of paper", row.Problem);
        Assert.Contains("Out of paper", row.Description);
    }

    [Fact]
    public async Task ASpoolerThatDoesNotAnswerKeepsTheQueuesLastRead()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        await rig.Model.RefreshPrintersAsync();

        rig.Spooler.Throws = true;
        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(["system:HP LaserJet", "demo"], rig.Model.Printers.Select(p => p.Id));
    }

    [Fact]
    public async Task ThePrintersCapabilitiesAreReadOnceAndKept()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.RefreshPrintersAsync();

        Assert.Contains("two-sided-long-edge", rig.Model.SelectedCapabilities!.SidesSupported);
    }

    [Fact]
    public async Task AFailedCapabilitiesReadIsTriedAgainAfterHalfAMinute()
    {
        using var rig = new Rig();
        var now = DateTimeOffset.UtcNow;
        rig.Model.Now = () => now;
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        rig.Spooler.CapabilityFailures = 1;
        await rig.Model.RefreshPrintersAsync();
        Assert.Null(rig.Model.SelectedCapabilities);

        await rig.Model.RefreshPrintersAsync();
        Assert.Null(rig.Model.SelectedCapabilities);

        now += TimeSpan.FromSeconds(31);
        await rig.Model.RefreshPrintersAsync();

        Assert.Contains("two-sided-long-edge", rig.Model.SelectedCapabilities!.SidesSupported);
    }

    // MARK: Tasks

    [Fact]
    public async Task ABookletTaskSetsTheBookletAndKeepsTheRest()
    {
        using var rig = new Rig();
        rig.Model.Settings.Copies = 3;
        await rig.Model.StartTaskAsync(PrintTask.Booklet);

        var s = rig.Model.Settings;
        Assert.True(s.Booklet);
        Assert.Equal(Sides.LongEdge, s.Sides);
        Assert.Equal("booklet", s.TaskId);
        Assert.Equal(PrintTask.Booklet, rig.Model.SelectedTask);
        Assert.Equal(3, s.Copies);
    }

    [Fact]
    public async Task AHandoutsTaskSetsTwoPerSideWithBorders()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Handouts);

        Assert.Equal(2, rig.Model.Settings.PagesPerSheet);
        Assert.True(rig.Model.Settings.PageBorders);
    }

    [Fact]
    public async Task APhotoTaskSetsTheSizeAndTheBestQuality()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Photos);

        Assert.Equal("4x6", rig.Model.Settings.PhotoSizeId);
        Assert.Equal(QualityChoice.Best, rig.Model.Settings.Quality);
    }

    [Fact]
    public async Task ADocumentIsTwoSidedOnlyWhenThePrinterCanTurnTheSheet()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        Assert.Equal(Sides.LongEdge, rig.Model.Settings.Sides);

        await rig.Model.SelectPrinterAsync("demo");
        rig.Model.Settings.Sides = Sides.OneSided;
        await rig.Model.StartTaskAsync(PrintTask.Document);
        // The demo printer prints both sides too.
        Assert.Equal(Sides.LongEdge, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task ADocumentPickedBeforeThePrinterIsReadIsTwoSidedOnceItIs()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        Assert.Equal(Sides.OneSided, rig.Model.Settings.Sides);

        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(Sides.LongEdge, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task AFirstRunStartsInTheDocumentTaskAndLeavingItIsKept()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        Assert.Equal(PrintTask.Document, rig.Model.SelectedTask);
        Assert.Equal(Sides.OneSided, rig.Model.Settings.Sides);

        await rig.Model.RefreshPrintersAsync();
        Assert.Equal(Sides.LongEdge, rig.Model.Settings.Sides);

        rig.Model.ClearTask();
        rig.Model.FlushSettings();
        var next = rig.Open();
        Assert.False(next.IsFirstRun);
        Assert.Null(next.SelectedTask);
        Assert.Equal(Sides.LongEdge, next.Settings.Sides);
    }

    [Fact]
    public async Task SidesTheUserChangedBeforeThePrinterIsReadAreKept()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        rig.Model.Settings.Sides = Sides.ShortEdge;
        rig.Model.SettingsEdited();

        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(Sides.ShortEdge, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task SidesTheUserChangedAndChangedBackBeforeThePrinterIsReadAreKept()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        rig.Model.Settings.Sides = Sides.LongEdge;
        rig.Model.SettingsEdited();
        rig.Model.Settings.Sides = Sides.OneSided;
        rig.Model.SettingsEdited();

        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(Sides.OneSided, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task ADocumentPickedBeforeAnyPrinterIsListedFollowsThePrinterThatAppears()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        await rig.Model.RefreshPrintersAsync();
        Assert.Equal(Sides.OneSided, rig.Model.Settings.Sides);

        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = Rig.Duplex();
        await rig.Model.RefreshPrintersAsync();

        Assert.Equal("HP LaserJet", rig.Model.SelectedPrinter?.Name);
        Assert.Equal(Sides.LongEdge, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task ADocumentPickedBeforeAPrinterThatCannotTurnTheSheetIsReadStaysOneSided()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Capable["HP LaserJet"] = new PrinterCapabilities { SidesSupported = ["one-sided"] };
        await rig.Model.StartTaskAsync(PrintTask.Document);

        await rig.Model.RefreshPrintersAsync();

        Assert.Equal(Sides.OneSided, rig.Model.Settings.Sides);
    }

    [Fact]
    public async Task OnlyScanAndPrintNeedsLazyScan()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        var unavailable = TaskCatalog.Tasks(AppPlatform.Windows).Where(d => !rig.Model.AvailabilityOf(d.Task).IsAvailable).ToList();

        var scan = Assert.Single(unavailable);
        Assert.Equal(PrintTask.ScanAndPrint, scan.Task);
        Assert.Equal("Needs Lazy Scan", rig.Model.AvailabilityOf(scan.Task).Reason);
    }

    [Fact]
    public void TheTestPageWaitsForAPrinter()
    {
        using var rig = new Rig();
        var availability = rig.Model.AvailabilityOf(PrintTask.TestPage);

        Assert.False(availability.IsAvailable);
        Assert.Equal("Needs a printer", availability.Reason);
    }

    [Fact]
    public async Task ScanAndPrintOpensLazyScanWhenItIsInstalled()
    {
        using var rig = new Rig();
        rig.Diagnostics.LazyScan = true;
        var model = rig.Open();
        model.ClearTask();
        await model.RefreshLazyScanAsync();

        Assert.True(model.AvailabilityOf(PrintTask.ScanAndPrint).IsAvailable);
        await model.StartTaskAsync(PrintTask.ScanAndPrint);

        Assert.True(rig.Diagnostics.LazyScanOpened);
        Assert.Null(model.SelectedTask);
    }

    [Fact]
    public async Task AnUnavailableTaskDoesNothing()
    {
        using var rig = new Rig();
        rig.Model.ClearTask();
        await rig.Model.StartTaskAsync(PrintTask.ScanAndPrint);

        Assert.False(rig.Diagnostics.LazyScanOpened);
        Assert.Null(rig.Model.SelectedTask);
    }

    [Fact]
    public async Task TheTestPagePrintsAtOnceOnThePrinterInUse()
    {
        using var rig = new Rig(demo: true);
        rig.Model.ClearTask();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.TestPage);

        var test = Assert.Single(rig.Sheets.Jobs);
        Assert.Equal("demo", test.Printer.Id);
        Assert.NotEmpty(Assert.Single(test.Items!).Items);
        Assert.Null(rig.Model.SelectedTask);
        Assert.Equal("Sent 1 sheet to Demo Printer", rig.Model.SentMessage);
    }

    [Fact]
    public async Task APhoneTaskOpensThePhoneWindowAndChangesNothing()
    {
        using var rig = new Rig();
        rig.Model.ClearTask();
        int opened = 0;
        rig.Model.PhoneWindowRequested += () => opened++;
        await rig.Model.StartTaskAsync(PrintTask.FromPhone);

        Assert.Equal(1, opened);
        Assert.Null(rig.Model.ErrorMessage);
        Assert.Null(rig.Model.SelectedTask);
    }

    [Fact]
    public async Task LeavingTheTaskKeepsTheSettings()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Handouts);
        rig.Model.ClearTask();

        Assert.Null(rig.Model.SelectedTask);
        Assert.Equal(2, rig.Model.Settings.PagesPerSheet);
    }

    // MARK: Settings

    [Fact]
    public async Task SettingsAreSavedAndComeBackOnTheNextStart()
    {
        using var rig = new Rig();
        Assert.True(rig.Model.IsFirstRun);
        await rig.Model.StartTaskAsync(PrintTask.Handouts);
        rig.Model.Settings.Copies = 4;
        rig.Model.Settings.Collate = false;
        rig.Model.SettingsEdited();
        rig.Model.FlushSettings();

        var next = rig.Open();
        Assert.False(next.IsFirstRun);
        Assert.Equal(1, next.Settings.Copies);
        Assert.False(next.Settings.Collate);
        Assert.Equal(2, next.Settings.PagesPerSheet);
        Assert.Equal(PrintTask.Handouts, next.SelectedTask);
    }

    [Fact]
    public async Task TheChosenPrinterIsRemembered()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet"));
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        rig.Model.FlushSettings();

        Assert.Equal("system:HP LaserJet", rig.Open().Settings.PrinterId);
    }

    [Fact]
    public async Task EachPrinterBringsBackItsOwnPaperSidesColorAndQuality()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        rig.Spooler.Queue.Add(Rig.Queue("Brother"));
        await rig.Model.RefreshPrintersAsync();

        rig.Model.Settings.PaperId = "a5";
        rig.Model.Settings.Color = ColorChoice.Gray;
        rig.Model.Settings.Quality = QualityChoice.Best;
        rig.Model.Settings.Copies = 3;
        rig.Model.SettingsEdited();

        // A printer never used keeps what is in front of the user, and then remembers it too.
        await rig.Model.SelectPrinterAsync("system:Brother");
        Assert.Equal("a5", rig.Model.Settings.PaperId);
        rig.Model.Settings.PaperId = "legal";
        rig.Model.Settings.Color = ColorChoice.Color;
        rig.Model.SettingsEdited();

        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        Assert.Equal("a5", rig.Model.Settings.PaperId);
        Assert.Equal(ColorChoice.Gray, rig.Model.Settings.Color);
        Assert.Equal(3, rig.Model.Settings.Copies);

        await rig.Model.SelectPrinterAsync("system:Brother");
        Assert.Equal("legal", rig.Model.Settings.PaperId);
        Assert.Equal(ColorChoice.Color, rig.Model.Settings.Color);
        Assert.Equal(QualityChoice.Best, rig.Model.Settings.Quality);

        // They are kept across a restart.
        var next = rig.Open();
        await next.RefreshPrintersAsync();
        await next.SelectPrinterAsync("system:HP LaserJet");
        Assert.Equal("a5", next.Settings.PaperId);
    }

    [Fact]
    public void ACopyCountIsKeptInRange()
    {
        using var rig = new Rig();
        rig.Model.Settings.Copies = 500;
        rig.Model.SettingsEdited();

        Assert.Equal(PrintCopies.MaxCount, rig.Model.Settings.Copies);
    }

    // MARK: Documents and printing

    [Fact]
    public async Task PrintNeedsADocument()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();

        Assert.False(rig.Model.CanPrint);
        Assert.Equal("Add files to print", rig.Model.PrintDisabledReason);
        Assert.Equal("Print", rig.Model.PrintLabel);
    }

    [Fact]
    public async Task PrintSaysHowManySheetsItWillUse()
    {
        using var rig = new Rig(demo: true);
        rig.Loader.Pages = [new LayoutSize(612, 792), new LayoutSize(612, 792), new LayoutSize(612, 792)];
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);

        Assert.True(rig.Model.CanPrint);
        Assert.Equal("Print 2 sheets", rig.Model.PrintLabel);
        rig.Model.SetPageRange("1-2");
        Assert.Equal("Print 1 sheet", rig.Model.PrintLabel);
    }

    [Fact]
    public async Task CopiesShowOnThePrintButtonAndTheSentBar()
    {
        using var rig = new Rig(demo: true);
        rig.Loader.Pages = [new LayoutSize(612, 792), new LayoutSize(612, 792)];
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Model.Settings.Copies = 3;
        rig.Model.SettingsEdited();

        Assert.Equal("Print 1 sheet × 3", rig.Model.PrintLabel);
        await rig.Model.PrintAsync();
        Assert.Equal("Sent 1 sheet × 3 to Demo Printer", rig.Model.SentMessage);
    }

    [Fact]
    public async Task AWaitingJobWithADetailShowsTheDetailInsteadOfTheCount()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Sheets.Report = new JobStatus(JobState.Waiting, 0, "Out of paper");
        rig.Sheets.While = (_, _, token) => Task.Delay(Timeout.Infinite, token);

        var printing = rig.Model.PrintAsync();
        for (var tries = 0; tries < 200 && rig.Model.StatusMessage != "Waiting for Demo Printer: Out of paper"; tries++) await Task.Delay(10);

        Assert.Equal("Waiting for Demo Printer: Out of paper", rig.Model.StatusMessage);
        rig.Model.CancelJob();
        await printing;
    }

    [Fact]
    public async Task APageRangePastTheEndIsReportedAndStopsPrint()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Model.SetPageRange("9");

        Assert.NotNull(rig.Model.PageRangeError);
        Assert.False(rig.Model.CanPrint);
    }

    [Fact]
    public async Task AFileThatCannotBeReadIsReportedAndTheOthersGoIn()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync(["a.bad", "b.pdf"]);

        Assert.Equal(["b.pdf"], rig.Model.Documents.Select(d => d.Name));
        Assert.Contains("a.bad: ", rig.Model.ErrorMessage);
        Assert.Contains("PDFs and pictures", rig.Model.ErrorMessage);
    }

    [Fact]
    public async Task EveryFileThatCannotBeReadIsNamedAndALongListIsCut()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync(["a.bad", "b.bad", "c.bad", "d.bad", "e.bad", "f.pdf"]);

        Assert.Equal(["f.pdf"], rig.Model.Documents.Select(d => d.Name));
        string[] lines = rig.Model.ErrorMessage!.Split('\n');
        Assert.Equal(4, lines.Length);
        Assert.StartsWith("a.bad: ", lines[0]);
        Assert.StartsWith("c.bad: ", lines[2]);
        Assert.Equal("and 2 more", lines[3]);
    }

    [Fact]
    public async Task APrintedJobIsRecordedAndSaysWhatWasSent()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        await rig.Model.PrintAsync();

        var job = Assert.Single(rig.Sheets.Jobs);
        Assert.Equal("a.pdf", job.Name);
        Assert.Equal("demo", job.Printer.Id);
        Assert.Equal("Sent 1 sheet to Demo Printer", rig.Model.SentMessage);
        Assert.Equal(JobState.Done, Assert.Single(rig.Model.Jobs).State);
        Assert.False(rig.Model.IsBusy);
    }

    [Fact]
    public async Task AFailedJobPutsItsProblemInTheErrorBar()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Sheets.Fails = new PrintException(new PrintError.Unreachable("Demo Printer", "no answer"));
        await rig.Model.PrintAsync();

        Assert.Equal("Couldn't print", rig.Model.ErrorTitle);
        Assert.Contains("Demo Printer", rig.Model.ErrorMessage);
        Assert.True(rig.Model.ErrorSuggestsTroubleshooter);
        Assert.Null(rig.Model.SentMessage);
        Assert.Equal(JobState.Failed, Assert.Single(rig.Model.Jobs).State);
        Assert.False(rig.Model.IsBusy);
    }

    [Fact]
    public async Task ALostContactAfterTheJobWasSentSaysSoAndOffersTheTroubleshooter()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Sheets.Fails = new PrintException(new PrintError.LostContact("Demo Printer"));
        await rig.Model.PrintAsync();

        Assert.Equal("Lost contact with Demo Printer", rig.Model.ErrorTitle);
        Assert.Equal("The job was sent before the printer stopped answering. Check the printer before printing it again.", rig.Model.ErrorMessage);
        Assert.True(rig.Model.ErrorSuggestsTroubleshooter);
    }

    [Fact]
    public async Task AJobThatIsNotAboutReachingThePrinterDoesNotOfferTheTroubleshooter()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Sheets.Fails = new IOException("The disk is full.");
        await rig.Model.PrintAsync();

        Assert.False(rig.Model.ErrorSuggestsTroubleshooter);
    }

    [Fact]
    public async Task DismissingTheErrorAndTheSentBarClearsThem()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.bad"]);
        Assert.NotNull(rig.Model.ErrorMessage);
        rig.Model.DismissError();
        Assert.Null(rig.Model.ErrorMessage);

        await rig.Model.AddFilesAsync(["a.pdf"]);
        await rig.Model.PrintAsync();
        Assert.NotNull(rig.Model.SentMessage);
        rig.Model.DismissSent();
        Assert.Null(rig.Model.SentMessage);
    }

    // MARK: Troubleshooter

    [Fact]
    public async Task TheSnapshotHoldsThePrintersAndWhatTheSystemSaid()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", true, SystemQueueState.PaperOut));
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.ReadSystemStateAsync();

        var snapshot = rig.Model.TroubleshootSnapshot();
        Assert.Equal(ServiceStatus.Running, snapshot.Spooler);
        Assert.Equal(NetworkStatus.PrivateNetwork, snapshot.Network);
        Assert.Equal(1, snapshot.ListedPrinterCount);
        Assert.Contains(Troubleshooter.Diagnose(snapshot), c => c.Id.StartsWith("printer:", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CopyingTheDiagnosticsPutsTheChecksOnTheClipboard()
    {
        using var rig = new Rig();
        await rig.Model.RefreshPrintersAsync();

        Assert.True(rig.Model.CopyDiagnostics(rig.Model.TroubleshootSnapshot()));
        Assert.StartsWith("Why isn't my printer listed?", rig.Diagnostics.Copied);
    }

    [Fact]
    public async Task ClearingStuckJobsAsksTheSpoolerForThatQueue()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet"));
        await rig.Model.RefreshPrintersAsync();

        Assert.True(await rig.Model.ClearStuckJobsAsync("system:HP LaserJet"));
        Assert.Equal(["HP LaserJet"], rig.Spooler.Cleared);
        Assert.False(await rig.Model.ClearStuckJobsAsync("demo"));
    }

    [Fact]
    public async Task ResumingAPrinterAsksTheSpoolerForThatQueue()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet"));
        await rig.Model.RefreshPrintersAsync();

        Assert.True(await rig.Model.ResumePrinterAsync("system:HP LaserJet"));
        Assert.Equal(["HP LaserJet"], rig.Spooler.Resumed);
    }

    // MARK: Status line

    [Fact]
    public async Task TheStatusNamesThePrinterThenTheTask()
    {
        using var rig = new Rig(demo: true);
        rig.Model.ClearTask();
        Assert.Equal("Looking for printers…", rig.Model.StatusMessage);

        await rig.Model.RefreshPrintersAsync();
        Assert.Equal("Demo Printer", rig.Model.StatusMessage);

        await rig.Model.StartTaskAsync(PrintTask.Booklet);
        Assert.Equal("Ready for “Booklet”.", rig.Model.StatusMessage);
        Assert.Equal("Ready — Demo Printer", StatusLine.Short(rig.Model.StatusMessage, "Demo Printer"));
    }
}
