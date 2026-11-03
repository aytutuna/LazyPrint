using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class DemoPrinterFilesTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lazyprint-demo-" + Guid.NewGuid().ToString("N"));
    private readonly DemoPrinterState _state;

    public DemoPrinterFilesTests() => _state = new DemoPrinterState { Root = _root };

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, true);
    }

    private static SheetJob Job(Action<PrintSettings> edit, int pages, string id = "job", bool duplex = true) =>
        PrintFixtures.Job(PrintFixtures.Letter(edit), pages, PrintFixtures.Printer(PrinterRoute.Demo), DemoPrinter.Capabilities(duplex), id: id);

    private DemoPrinter Printer() => new(new SolidPages(), _state);

    private IEnumerable<string> Files(string id) =>
        Directory.GetFiles(_state.Folders[id]).Select(Path.GetFileName).Order()!;

    [Fact]
    public async Task EachSideIsAPngInAFolderOfTheJob()
    {
        var job = Job(s => s.Sides = Sides.LongEdge, pages: 3);
        await Printer().PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);

        Assert.StartsWith(_root, _state.Folders["job"]);
        Assert.EndsWith("Letter.pdf", _state.Folders["job"]);
        Assert.Equal(["Sheet 1 back.png", "Sheet 1 front.png", "Sheet 2 back.png", "Sheet 2 front.png"], Files("job"));
    }

    [Fact]
    public async Task APngIsASheetAt150DotsToTheInch()
    {
        await Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None);

        using var file = File.OpenRead(Path.Combine(_state.Folders["job"], "Sheet 1.png"));
        var frame = new PngBitmapDecoder(file, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
        Assert.Equal((1275, 1650), (frame.PixelWidth, frame.PixelHeight));
    }

    [Fact]
    public async Task AGrayJobIsGrayPictures()
    {
        await Printer().PrintAsync(Job(s => s.Color = ColorChoice.Gray, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None);

        using var file = File.OpenRead(Path.Combine(_state.Folders["job"], "Sheet 1.png"));
        Assert.Equal(PixelFormats.Gray8, new PngBitmapDecoder(file, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0].Format);
    }

    [Fact]
    public async Task BothPassesOfAJobDoneByHandGoToTheSameFolder()
    {
        var job = Job(s => s.Sides = Sides.LongEdge, pages: 3, duplex: false);
        var printer = Printer();
        await printer.PrintAsync(job, 0, new Reports<JobStatus>(), CancellationToken.None);
        await printer.PrintAsync(job, 1, new Reports<JobStatus>(), CancellationToken.None);

        Assert.Single(Directory.GetDirectories(_root));
        Assert.Equal(["Backs 1.png", "Backs 2.png", "Fronts 1.png", "Fronts 2.png"], Files("job"));
    }

    [Fact]
    public async Task TheInkGoesDownALittleWithEachJob()
    {
        var before = _state.Supplies().Select(s => s.Level).ToList();
        await Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None);
        var color = _state.Supplies().Select(s => s.Level).ToList();
        await Printer().PrintAsync(Job(s => s.Color = ColorChoice.Gray, pages: 1, id: "gray"), 0, new Reports<JobStatus>(), CancellationToken.None);
        var gray = _state.Supplies().Select(s => s.Level).ToList();

        Assert.All(before.Zip(color), pair => Assert.True(pair.Second < pair.First));
        Assert.Equal(color[..3], gray[..3]);
        Assert.True(gray[3] < color[3]);
    }

    [Fact]
    public async Task WhenItIsOutOfPaperTheJobStopsWithThatProblemAndPrintsNothing()
    {
        _state.OutOfPaper = true;
        var error = await Assert.ThrowsAsync<PrinterProblemException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), CancellationToken.None));

        Assert.Equal("Out of paper", error.Problem.Title);
        Assert.False(Directory.Exists(_root));
    }

    [Fact]
    public async Task ACancelledJobStopsBeforeItsFirstSide()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => Printer().PrintAsync(Job(_ => { }, pages: 1), 0, new Reports<JobStatus>(), cancellation.Token));
        Assert.False(Directory.Exists(_root));
    }
}
