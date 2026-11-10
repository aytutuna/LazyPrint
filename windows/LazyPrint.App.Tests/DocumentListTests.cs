using LazyPrint.App;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>The documents of a print: their order, removing them, and what the real loader's files plan to.</summary>
public sealed class DocumentListTests
{
    private static string[] Names(Rig rig) => [.. rig.Model.Documents.Select(d => d.Name)];

    [Fact]
    public async Task ADocumentMovesEarlierAndLater()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync(["a.pdf", "b.pdf", "c.pdf"]);

        rig.Model.MoveDocument(rig.Model.Documents[2], -1);
        Assert.Equal(["a.pdf", "c.pdf", "b.pdf"], Names(rig));

        rig.Model.MoveDocument(rig.Model.Documents[0], 1);
        Assert.Equal(["c.pdf", "a.pdf", "b.pdf"], Names(rig));
    }

    [Fact]
    public async Task EqualDocumentsAreToldApartByReference()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync(["a.pdf", "a.pdf", "b.pdf"]);
        var first = rig.Model.Documents[0];
        var second = rig.Model.Documents[1];
        Assert.Equal(first, second);

        rig.Model.MoveDocument(second, 1);
        Assert.Same(first, rig.Model.Documents[0]);
        Assert.Equal(["a.pdf", "b.pdf", "a.pdf"], Names(rig));
        Assert.Same(second, rig.Model.Documents[2]);

        rig.Model.RemoveDocument(second);
        Assert.Equal(["a.pdf", "b.pdf"], Names(rig));
        Assert.Same(first, rig.Model.Documents[0]);
    }

    [Fact]
    public async Task TheEndsOfTheListStopAMove()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync(["a.pdf", "b.pdf"]);

        rig.Model.MoveDocument(rig.Model.Documents[0], -1);
        rig.Model.MoveDocument(rig.Model.Documents[1], 1);

        Assert.Equal(["a.pdf", "b.pdf"], Names(rig));
    }

    [Fact]
    public async Task ARemovedDocumentTakesItsPagesOutOfThePlan()
    {
        using var rig = new Rig();
        rig.Loader.Pages = [new LayoutSize(612, 792), new LayoutSize(612, 792)];
        await rig.Model.AddFilesAsync(["a.pdf", "b.pdf"]);
        Assert.Equal(4, rig.Model.PageCount);

        rig.Model.RemoveDocument(rig.Model.Documents[0]);

        Assert.Equal(["b.pdf"], Names(rig));
        Assert.Equal(2, rig.Model.PageCount);
        Assert.Equal("Print 2 sheets", rig.Model.PrintLabel);
    }

    [Fact]
    public async Task NothingChangesWhileAJobIsRunning()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        var printing = new TaskCompletionSource();
        var slow = new SlowSheetPrinter(printing.Task);
        var busy = new AppViewModel(rig.Spooler, rig.Loader, slow, rig.Diagnostics, rig.Directory);
        await busy.RefreshPrintersAsync();
        await busy.AddFilesAsync(["a.pdf", "b.pdf"]);

        var job = busy.PrintAsync();
        busy.MoveDocument(busy.Documents[1], -1);
        busy.RemoveDocument(busy.Documents[0]);
        printing.SetResult();
        await job;

        Assert.Equal(["a.pdf", "b.pdf"], busy.Documents.Select(d => d.Name));
    }

    [Fact]
    public async Task RealFilesPlanTheirSheets()
    {
        using var rig = new Rig();
        var model = new AppViewModel(rig.Spooler, new DocumentLoader(), rig.Sheets, rig.Diagnostics, rig.Directory);
        model.Settings.PaperId = "letter";

        await model.AddFilesAsync([DocumentFixtures.PathOf("mixed.pdf"), DocumentFixtures.PathOf("halves-300dpi.png")]);

        Assert.Equal(["mixed.pdf", "halves-300dpi.png"], model.Documents.Select(d => d.Name));
        Assert.Equal(4, model.PageCount);
        var plan = model.Plan()!;
        Assert.Equal(4, plan.Plan.Sheets.Count);
        Assert.Equal("Print 4 sheets", model.PrintLabel);
        // The A4 page does not fit Letter's printable area at real size; shrinking it goes unsaid.
        Assert.Empty(plan.Notes);
    }

    [Fact]
    public async Task ARefusedFileSaysWhyAndTheOthersGoIn()
    {
        using var rig = new Rig();
        var model = new AppViewModel(rig.Spooler, new DocumentLoader(), rig.Sheets, rig.Diagnostics, rig.Directory);

        await model.AddFilesAsync([DocumentFixtures.PathOf("locked.pdf"), DocumentFixtures.PathOf("red-letter.pdf")]);

        Assert.Equal(["red-letter.pdf"], model.Documents.Select(d => d.Name));
        Assert.Equal("Not added", model.ErrorTitle);
        Assert.Equal("locked.pdf: " + DocumentText.LockedPdf, model.ErrorMessage);
    }

    [Fact]
    public async Task TheCutMarksOfAPhotoPrintAreDrawnOnItsSheet()
    {
        using var rig = new Rig();
        var model = new AppViewModel(rig.Spooler, new DocumentLoader(), rig.Sheets, rig.Diagnostics, rig.Directory);
        await model.StartTaskAsync(PrintTask.Photos);
        model.Settings.PhotoSizeId = "4x6";
        model.Settings.PaperId = "letter";
        await model.AddFilesAsync([DocumentFixtures.PathOf("halves-300dpi.png")]);
        var plan = model.Plan()!;

        var marks = model.CutMarks(plan.Plan.Sheets[0].Front, plan.Plan.Area);
        model.Settings.CutMarks = false;

        Assert.NotEmpty(marks);
        Assert.Empty(model.CutMarks(plan.Plan.Sheets[0].Front, plan.Plan.Area));
    }

    private sealed class SlowSheetPrinter(Task release) : ISheetPrinter
    {
        public async Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token) => await release;
    }
}
