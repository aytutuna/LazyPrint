using System.IO;
using LazyPrint.App;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

// The view model's printing flows against stand-in printers: the two-sided card, the Jobs tab, the demo printer.
public sealed class PrintFlowTests
{
    /// <summary>A rig whose printer prints one side only, with three letter pages added and two-sided asked for: two sheets by hand.</summary>
    private static async Task<Rig> ManualRig()
    {
        var rig = new Rig(demo: true);
        rig.Loader.Pages = [new LayoutSize(612, 792), new LayoutSize(612, 792), new LayoutSize(612, 792)];
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.SetDemoDuplexAsync(false);
        rig.Model.Settings.PaperId = "letter";
        rig.Model.Settings.Sides = Sides.LongEdge;
        await rig.Model.AddFilesAsync(["a.pdf"]);
        return rig;
    }

    [Fact]
    public async Task TheFrontsGoFirstThenTheCardWaitsForTheBacks()
    {
        using var rig = await ManualRig();
        Assert.Equal("Print the fronts", rig.Model.PrintLabel);
        await rig.Model.PrintAsync();

        Assert.Equal([0], rig.Sheets.Passes.Select(sent => sent.Pass));
        Assert.Equal(DuplexStep.Reload, rig.Model.ManualStep);
        Assert.Equal("Load the backs", rig.Model.ManualTitle);
        Assert.Equal("Take the 2 printed sheets out. Turn the stack over and put it back in the tray, top edge first.", rig.Model.ManualText);
        var record = Assert.Single(rig.Model.Jobs);
        Assert.Equal((JobState.NeedsUser, "Load the backs"), (record.State, record.Detail));
        Assert.False(rig.Model.IsBusy);
        Assert.False(rig.Model.CanPrint);
        Assert.Null(rig.Model.SentMessage);
    }

    [Fact]
    public async Task PrintingTheBacksSendsTheSecondPassOfTheSameJobAndFinishesIt()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.PrintBacksAsync();

        Assert.Equal([0, 1], rig.Sheets.Passes.Select(sent => sent.Pass));
        Assert.Single(rig.Sheets.Jobs.Select(job => job.Id).Distinct());
        Assert.Equal(DuplexStep.None, rig.Model.ManualStep);
        Assert.Equal(JobState.Done, Assert.Single(rig.Model.Jobs).State);
        Assert.Equal("Sent 2 sheets to Demo Printer", rig.Model.SentMessage);
        Assert.True(rig.Model.CanPrint);
    }

    [Fact]
    public async Task ABackThatFailsLeavesTheCardUpToTryAgain()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        rig.Sheets.Fails = new PrintException(new PrintError.Unreachable("Demo Printer", "no answer"));
        await rig.Model.PrintBacksAsync();

        Assert.Equal(DuplexStep.Reload, rig.Model.ManualStep);
        Assert.NotNull(rig.Model.ErrorMessage);
        Assert.Equal(JobState.Failed, Assert.Single(rig.Model.Jobs).State);

        rig.Sheets.Fails = null;
        await rig.Model.PrintBacksAsync();
        Assert.Equal(DuplexStep.None, rig.Model.ManualStep);
        Assert.Equal(JobState.Done, Assert.Single(rig.Model.Jobs).State);
    }

    [Fact]
    public async Task CancellingTheCardLeavesTheFrontsPrintedAndFreesPrint()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        rig.Model.CancelManualDuplex();

        Assert.Equal(DuplexStep.None, rig.Model.ManualStep);
        Assert.Equal(JobState.Canceled, Assert.Single(rig.Model.Jobs).State);
        Assert.Equal([0], rig.Sheets.Passes.Select(sent => sent.Pass));
        Assert.True(rig.Model.CanPrint);
    }

    [Fact]
    public async Task CancellingTheWaitingJobInTheJobsTabEndsTheTwoSidedJob()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        rig.Model.CancelJob(rig.Model.Jobs[0].Id);

        Assert.Equal(DuplexStep.None, rig.Model.ManualStep);
        Assert.Equal(JobState.Canceled, Assert.Single(rig.Model.Jobs).State);
    }

    [Fact]
    public async Task TheCheckPrintsBothSidesOfOneSheetAndAsksHowTheArrowsPoint()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.CheckDuplexAsync();

        Assert.Equal(DuplexStep.CheckBack, rig.Model.ManualStep);
        Assert.Equal("Check with one sheet", rig.Model.ManualTitle);
        Assert.Equal("Take the 1 printed sheet out. Turn the stack over and put it back in the tray, top edge first.", rig.Model.ManualText);

        await rig.Model.PrintCheckBackAsync();
        Assert.Equal(DuplexStep.CheckAnswer, rig.Model.ManualStep);
        Assert.Equal(ManualDuplexText.CheckQuestion, rig.Model.ManualText);

        var (front, back) = ManualDuplex.CheckSheet(rig.Sheets.Jobs.First().Plan.Plan.Area);
        var checks = rig.Sheets.Jobs.Where(job => job.Items is not null).ToList();
        Assert.Equal(2, checks.Count);
        Assert.Equal(front, checks[0].Items![0].Items);
        Assert.Equal(back, checks[1].Items![0].Items);
        Assert.False(checks[1].Items![0].Turned);
    }

    [Fact]
    public async Task OppositeArrowsTurnTheBacksFromThenOnAndTheLessonIsKept()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.CheckDuplexAsync();
        await rig.Model.PrintCheckBackAsync();
        rig.Model.AnswerDuplexCheck(DuplexCheckAnswer.OppositeEdges);

        Assert.Equal(DuplexStep.Reload, rig.Model.ManualStep);
        await rig.Model.PrintBacksAsync();
        var backs = rig.Sheets.Passes[^1];
        Assert.Equal(1, backs.Pass);
        // Sheet 1's back holds page 2, upright until the check said the printer turns it.
        Assert.Equal(2, backs.Job.Plan.Passes[1].Sides[0].Placements[0].Turns);

        var next = rig.Open();
        await next.RefreshPrintersAsync();
        Assert.True(next.SelectedPrefs.PaperPath.TurnBacks);
        Assert.True(next.SelectedPrefs.PaperPath.Checked);
    }

    [Fact]
    public async Task ABackDrawnForTheCheckIsTurnedOnceThePathTurnsBacks()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.CheckDuplexAsync();
        await rig.Model.PrintCheckBackAsync();
        rig.Model.AnswerDuplexCheck(DuplexCheckAnswer.OppositeEdges);
        await rig.Model.CheckDuplexAsync();
        await rig.Model.PrintCheckBackAsync();

        Assert.True(rig.Sheets.Jobs.Last().Items![0].Turned);
    }

    [Fact]
    public async Task BothNumbersOnOneSideChangeHowTheStackGoesBackAndAskToCheckAgain()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.CheckDuplexAsync();
        await rig.Model.PrintCheckBackAsync();
        rig.Model.AnswerDuplexCheck(DuplexCheckAnswer.BothOnOneSide);

        Assert.Equal(DuplexStep.Reload, rig.Model.ManualStep);
        Assert.Equal("Put the stack back in the tray as it is, top edge first.", rig.Model.ManualText);
        Assert.False(rig.Model.SelectedPrefs.PaperPath.Checked);

        await rig.Model.PrintBacksAsync();
        // Reloaded as it lies, the last sheet is on top: the backs go in reverse, a blank one marked.
        var pass = rig.Sheets.Passes[^1].Job.Plan.Passes[1];
        Assert.Equal([0], pass.Marked);
    }

    [Fact]
    public async Task PrintIsNotOfferedWhileTheCardIsUp()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.PrintAsync();

        Assert.Single(rig.Sheets.Passes);
        Assert.Equal("Finish the two-sided job first", rig.Model.PrintDisabledReason);
    }

    // MARK: Jobs

    [Fact]
    public async Task JobsAreListedNewestFirstAndPrintAgainMakesAnotherOfTheSame()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        await rig.Model.PrintAsync();
        string first = rig.Model.Jobs[0].Id;
        rig.Model.Documents.Clear();
        await rig.Model.PrintAgainAsync(first);

        Assert.Equal(2, rig.Model.Jobs.Count);
        Assert.NotEqual(first, rig.Model.Jobs[0].Id);
        Assert.Equal(first, rig.Model.Jobs[1].Id);
        Assert.All(rig.Model.Jobs, job => Assert.Equal(JobState.Done, job.State));
        Assert.Equal(2, rig.Sheets.Passes.Count);
        Assert.Equal("a.pdf", rig.Sheets.Passes[1].Job.Name);
    }

    [Fact]
    public async Task CancellingARunningJobMarksItCanceledWithoutAnError()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        var started = new TaskCompletionSource();
        rig.Sheets.While = async (_, _, token) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        };
        var printing = rig.Model.PrintAsync();
        await started.Task;
        Assert.True(rig.Model.IsBusy);
        rig.Model.CancelJob(rig.Model.Jobs[0].Id);
        await printing;

        Assert.Equal(JobState.Canceled, Assert.Single(rig.Model.Jobs).State);
        Assert.Null(rig.Model.ErrorMessage);
        Assert.False(rig.Model.IsBusy);
    }

    [Fact]
    public async Task CancellingAndWaitingReturnsOnceTheJobHasEnded()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        var started = new TaskCompletionSource();
        rig.Sheets.While = async (_, _, token) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        };
        var printing = rig.Model.PrintAsync();
        await started.Task;
        Assert.True(await rig.Model.CancelJobAndWaitAsync());

        Assert.False(rig.Model.IsBusy);
        Assert.Equal(JobState.Canceled, Assert.Single(rig.Model.Jobs).State);
        await printing;
        Assert.False(await rig.Model.CancelJobAndWaitAsync());
    }

    [Fact]
    public async Task ATwoSidedJobWaitingForItsBacksIsHalfDone()
    {
        using var rig = await ManualRig();
        Assert.False(rig.Model.IsWaitingForBacks);
        await rig.Model.PrintAsync();
        Assert.True(rig.Model.IsWaitingForBacks);
        rig.Model.CancelManualDuplex();
        Assert.False(rig.Model.IsWaitingForBacks);
    }

    [Fact]
    public async Task APrinterThatStopsOnAProblemTitlesTheErrorBarWithIt()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Sheets.Fails = new PrinterProblemException(new PrinterProblem("Paper jam", "Clear the jammed paper, then press Resume.", true));
        await rig.Model.PrintAsync();

        Assert.Equal("Paper jam", rig.Model.ErrorTitle);
        Assert.Equal("Clear the jammed paper, then press Resume.", rig.Model.ErrorMessage);
        Assert.True(rig.Model.ErrorSuggestsTroubleshooter);
    }

    // MARK: The demo printer in the view model

    private sealed class DemoRig : IDisposable
    {
        private readonly Rig _rig = new();
        public DemoPrinterState Demo { get; }
        public AppViewModel Model { get; }
        public FakeDiagnostics Diagnostics => _rig.Diagnostics;
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "lazyprint-flow-" + Guid.NewGuid().ToString("N"));

        public DemoRig()
        {
            Demo = new DemoPrinterState { Root = Root };
            Model = new AppViewModel(_rig.Spooler, _rig.Loader, new DemoPrinter(new SolidPages(), Demo), _rig.Diagnostics, _rig.Directory, Demo);
            Model.Settings.PrinterId = PrinterMerge.DemoId;
        }

        public void Dispose()
        {
            _rig.Dispose();
            if (Directory.Exists(Root)) Directory.Delete(Root, true);
        }
    }

    [Fact]
    public async Task OutOfPaperOnTheDemoPrinterShowsInItsRowAndStopsTheJob()
    {
        using var rig = new DemoRig();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        rig.Model.SetDemoOutOfPaper(true);

        var row = Assert.Single(rig.Model.Printers);
        Assert.Equal("Out of paper", row.Problem);
        await rig.Model.PrintAsync();

        Assert.Equal("Out of paper", rig.Model.ErrorTitle);
        Assert.True(rig.Model.ErrorSuggestsTroubleshooter);
        Assert.Equal(JobState.Failed, Assert.Single(rig.Model.Jobs).State);
        Assert.Contains(rig.Model.TroubleshootSnapshot().Printers, p => p.Problems.Any(problem => problem.Title == "Out of paper"));

        rig.Model.SetDemoOutOfPaper(false);
        await rig.Model.PrintAsync();
        Assert.Equal(JobState.Done, rig.Model.Jobs[0].State);
        Assert.Equal("", rig.Model.Printers[0].Problem);
    }

    [Fact]
    public async Task ADemoJobHasAFolderTheJobsTabCanShow()
    {
        using var rig = new DemoRig();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.AddFilesAsync(["a.pdf"]);
        int inkBefore = rig.Model.Printers[0].Info.Supplies[0].Level!.Value;
        await rig.Model.PrintAsync();
        string id = rig.Model.Jobs[0].Id;

        Assert.True(Directory.Exists(rig.Model.DemoFolderOf(id)));
        rig.Model.ShowDemoFolder(id);
        Assert.Equal(rig.Model.DemoFolderOf(id), Assert.Single(rig.Diagnostics.Folders));
        Assert.True(rig.Model.Printers[0].Info.Supplies[0].Level < inkBefore);
        Assert.Null(rig.Model.DemoFolderOf("nothing"));
    }

    [Fact]
    public async Task TheTestPagePrintsOnTheDemoPrinterAsASheetPicture()
    {
        using var rig = new DemoRig();
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.TestPage);

        var record = Assert.Single(rig.Model.Jobs);
        Assert.Equal(("Test page", JobState.Done), (record.Name, record.State));
        Assert.Equal(["Sheet 1.png"], Directory.GetFiles(rig.Model.DemoFolderOf(record.Id)!).Select(Path.GetFileName));
    }

    [Fact]
    public async Task TheDemoPrinterSwitchChangesWhetherATaskGetsTwoSides()
    {
        using var rig = new DemoRig();
        await rig.Model.RefreshPrintersAsync();
        Assert.Contains("two-sided-long-edge", rig.Model.SelectedCapabilities!.SidesSupported);

        await rig.Model.SetDemoDuplexAsync(false);

        Assert.DoesNotContain("two-sided-long-edge", rig.Model.SelectedCapabilities!.SidesSupported);
    }

    [Fact]
    public async Task TheCutMarksOfAPhotoPrintAreInTheSidesTheJobSends()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.Photos);
        rig.Model.Settings.PaperId = "letter";
        rig.Model.Settings.PhotoSizeId = "4x6";
        await rig.Model.AddFilesAsync(["a.png"]);
        await rig.Model.PrintAsync();

        var side = JobSides.Of(rig.Sheets.Jobs.Single(), 0)[0];

        Assert.NotEmpty(side.Items!);
    }

    [Fact]
    public async Task TheCutMarksOfAPhotoSheetAreInTheSidesTheJobSends()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.PhotoSheet);
        rig.Model.Settings.PaperId = "letter";
        await rig.Model.AddFilesAsync(["a.png", "b.png", "c.png", "d.png"]);
        await rig.Model.PrintAsync();

        var side = JobSides.Of(rig.Sheets.Jobs.Single(), 0)[0];

        Assert.Equal(32, side.Items!.Count);
    }

    [Fact]
    public async Task TheReloadCardCountsTheCopiesThePrinterMakes()
    {
        using var rig = await ManualRig();
        rig.Model.Settings.Copies = 2;
        await rig.Model.PrintAsync();

        Assert.Equal(DuplexStep.Reload, rig.Model.ManualStep);
        Assert.Contains("Take the 4 printed sheets out", rig.Model.ManualText);
    }

    [Fact]
    public async Task TheStatusLineFollowsTheTwoSidedCheck()
    {
        using var rig = await ManualRig();
        await rig.Model.PrintAsync();
        await rig.Model.CheckDuplexAsync();

        Assert.Equal(DuplexStep.CheckBack, rig.Model.ManualStep);
        Assert.Equal(rig.Model.ManualTitle, rig.Model.StatusMessage);
    }

    [Fact]
    public async Task EditingTheSettingsClearsTheWordsAboutTheLastJob()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.StartTaskAsync(PrintTask.Document);
        await rig.Model.AddFilesAsync(["a.pdf"]);
        await rig.Model.PrintAsync();
        Assert.NotNull(rig.Model.SentMessage);

        rig.Model.Settings.Copies = 2;
        rig.Model.SettingsEdited();

        Assert.Null(rig.Model.SentMessage);
        Assert.NotEqual("Printed", rig.Model.StatusMessage);
    }

    [Fact]
    public void NotCollatedCopiesComeOutEachSheetInARow()
    {
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => { s.Copies = 3; s.Collate = false; }), 2);
        var sent = job.Plan.Passes[0].Sides;

        Assert.Equal([sent[0], sent[0], sent[0], sent[1], sent[1], sent[1]], JobSides.Of(job, 0).Select(d => d.Side));
    }

    [Fact]
    public void NotCollatedTwoSidedCopiesKeepAFrontAndItsBackTogether()
    {
        var caps = new PrinterCapabilities { SidesSupported = ["one-sided", "two-sided-long-edge"], CopiesSupported = (1, 1) };
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => { s.Copies = 2; s.Collate = false; s.Sides = Sides.LongEdge; }), 4, caps: caps);
        var sent = job.Plan.Passes[0].Sides;

        Assert.Equal([sent[0], sent[1], sent[0], sent[1], sent[2], sent[3], sent[2], sent[3]], JobSides.Of(job, 0).Select(d => d.Side));
    }

    [Fact]
    public void NotCollatedCopiesOfAPassDoneByHandRepeatEachSide()
    {
        var caps = new PrinterCapabilities { SidesSupported = ["one-sided"], CopiesSupported = (1, 1) };
        var job = PrintFixtures.Job(PrintFixtures.Letter(s => { s.Copies = 2; s.Collate = false; s.Sides = Sides.LongEdge; }), 4, caps: caps,
                                    prefs: new PrinterPrefs { PaperPath = new PaperPath { TurnStackOver = false, Checked = true } });
        var sent = job.Plan.Passes[1].Sides;

        Assert.True(job.Plan.ManualDuplex);
        Assert.Equal([sent[0], sent[0], sent[1], sent[1]], JobSides.Of(job, 1).Select(d => d.Side));
    }

    [Fact]
    public async Task APrinterRowIsUpdatedInPlace()
    {
        using var rig = new Rig(demo: true);
        await rig.Model.RefreshPrintersAsync();
        var row = rig.Model.Printers.Single();

        rig.Model.SetDemoOutOfPaper(true);

        Assert.Same(row, rig.Model.Printers.Single());
        Assert.Equal(PrinterState.Stopped, row.Info.State);
    }
}
