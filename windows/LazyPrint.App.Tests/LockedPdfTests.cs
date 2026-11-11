using LazyPrint.App;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>A PDF that needs a password: asked for, kept for its document, used by the preview and the print path.</summary>
public sealed class LockedPdfTests
{
    private static readonly string Locked = DocumentFixtures.PathOf("locked.pdf");

    [Fact]
    public async Task ALockedPdfAsksForAPasswordAndAWrongOneAgain()
    {
        var loader = new DocumentLoader();

        var missing = await Assert.ThrowsAsync<PdfPasswordException>(() => loader.LoadAsync(Locked, CancellationToken.None));
        var wrong = await Assert.ThrowsAsync<PdfPasswordException>(() => loader.LoadAsync(Locked, CancellationToken.None, "nope"));

        Assert.False(missing.Wrong);
        Assert.True(wrong.Wrong);
    }

    [Fact]
    public async Task ThePasswordOpensItForThePreviewAndTheSheetPdf()
    {
        var loader = new DocumentLoader();
        var document = await loader.LoadAsync(Locked, CancellationToken.None, "secret");
        var side = new SheetSide([new Placement(new SourcePage(0, 0, document.Pages[0]), new LayoutRect(0, 0, 612, 792), 0, null)], false);
        var area = new PrintableArea(new LayoutSize(612, 792), new LayoutInsets(0, 0, 0, 0));

        Pixels.AssertColor(Pixels.Red, loader.Render(document, 0, null, 40, 40), 20, 20);
        Assert.Equal("secret", loader.Password(document));
        using var writer = new PdfSheetWriter([document], loader, loader);
        writer.AddSide(side, area, 150);
        using var sheets = PdfiumDocument.Open(writer.Save())!;
        var pixels = sheets.Render(0, 40, 40);

        Assert.True(pixels[(20 * 40 + 20) * 4 + 2] > 200 && pixels[(20 * 40 + 20) * 4 + 1] < 60);
    }

    [Fact]
    public async Task TheViewModelAsksUntilThePasswordIsRightOrTheUserCancels()
    {
        using var rig = new Rig();
        var model = new AppViewModel(rig.Spooler, new DocumentLoader(), rig.Sheets, rig.Diagnostics, rig.Directory);
        var asked = new List<bool>();
        string?[] answers = ["nope", "secret"];
        model.AskPassword = (_, wrong) =>
        {
            asked.Add(wrong);
            return Task.FromResult(answers[asked.Count - 1]);
        };

        await model.AddFilesAsync([Locked]);

        Assert.Equal([false, true], asked);
        Assert.Equal(["locked.pdf"], model.Documents.Select(d => d.Name));

        model.AskPassword = (_, _) => Task.FromResult<string?>(null);
        await model.AddFilesAsync([DocumentFixtures.PathOf("locked.pdf")]);

        Assert.Single(model.Documents);
        Assert.Equal("locked.pdf: " + ShortText.LockedLeftOut, model.ErrorMessage);
    }
}
