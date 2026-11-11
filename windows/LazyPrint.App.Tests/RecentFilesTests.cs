using LazyPrint.App.Services;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>The recent list, and what opening files and the Lazy PDF hand-off do with it.</summary>
public sealed class RecentFilesTests
{
    [Fact]
    public void TheNewestFileIsFirstAndAnOpenedOneMovesUp()
    {
        using var rig = new Rig();
        var recent = new RecentFiles(rig.Directory);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");
        recent.Add(@"C:\DOCS\A.pdf");

        Assert.Equal([@"C:\DOCS\A.pdf", @"C:\docs\b.pdf"], recent.Load().Select(f => f.Path));
    }

    [Fact]
    public void TheListKeepsTenFiles()
    {
        using var rig = new Rig();
        var recent = new RecentFiles(rig.Directory);
        for (int i = 0; i < 12; i++) recent.Add($@"C:\docs\{i}.pdf");

        var files = recent.Load();
        Assert.Equal(10, files.Count);
        Assert.Equal(@"C:\docs\11.pdf", files[0].Path);
        Assert.Equal(@"C:\docs\2.pdf", files[^1].Path);
    }

    [Fact]
    public void ARemovedFileGoesAndClearEmptiesTheList()
    {
        using var rig = new Rig();
        var recent = new RecentFiles(rig.Directory);
        recent.Add(@"C:\docs\a.pdf");
        recent.Add(@"C:\docs\b.pdf");
        recent.Remove(@"C:\DOCS\a.pdf");
        Assert.Equal([@"C:\docs\b.pdf"], recent.Load().Select(f => f.Path));

        recent.Clear();
        Assert.Empty(recent.Load());
    }

    [Fact]
    public async Task OpenedFilesAreRecentAndOnesThatAreGoneAreDropped()
    {
        using var rig = new Rig();
        Directory.CreateDirectory(rig.Directory);
        string kept = Path.Combine(rig.Directory, "kept.pdf"), gone = Path.Combine(rig.Directory, "gone.pdf");
        File.WriteAllText(kept, "");
        File.WriteAllText(gone, "");
        await rig.Model.AddFilesAsync([gone, kept]);
        File.Delete(gone);

        Assert.Equal([kept], rig.Model.RecentPaths());
        Assert.Equal([kept], new RecentFiles(rig.Directory).Load().Select(f => f.Path));
    }

    [Fact]
    public async Task AFileThatCannotBeOpenedIsNotRecent()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync([Path.Combine(rig.Directory, "a.bad.pdf")]);

        Assert.Empty(new RecentFiles(rig.Directory).Load());
    }

    [Fact]
    public async Task ClearRecentEmptiesTheMenu()
    {
        using var rig = new Rig();
        Directory.CreateDirectory(rig.Directory);
        string file = Path.Combine(rig.Directory, "a.pdf");
        File.WriteAllText(file, "");
        await rig.Model.AddFilesAsync([file]);
        Assert.NotEmpty(rig.Model.RecentPaths());

        rig.Model.ClearRecent();
        Assert.Empty(rig.Model.RecentPaths());
    }

    [Fact]
    public async Task LazyPdfIsOfferedForAPdfOnlyWhenItIsInstalled()
    {
        using var rig = new Rig();
        await rig.Model.AddFilesAsync([Path.Combine(rig.Directory, "a.pdf")]);
        var document = rig.Model.Documents[0];
        Assert.False(rig.Model.CanEditInLazyPdf(document));

        rig.Diagnostics.LazyPdf = true;
        await rig.Model.RefreshLazyPdfAsync();
        Assert.True(rig.Model.CanEditInLazyPdf(document));

        rig.Model.EditInLazyPdf(document);
        Assert.Equal(Path.Combine(rig.Directory, "a.pdf"), rig.Diagnostics.OpenedInLazyPdf);
    }
}
