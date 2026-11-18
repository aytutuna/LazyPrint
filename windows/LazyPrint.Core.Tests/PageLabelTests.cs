using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PageLabelTests.swift: the same cases.

public class PageLabelTests
{
    private static Placement[] On(params (int Document, int Index)[] pages)
    {
        var frame = new LayoutRect(0, 0, 1, 1);
        var size = new LayoutSize(1, 1);
        return pages.Select(p => new Placement(new SourcePage(p.Document, p.Index, size), frame, 0, null)).ToArray();
    }

    [Fact]
    public void Text_NamesOnePageARunAndAGap()
    {
        Assert.Equal("Page 3", PageLabel.Text(On((0, 2)), [5]));
        Assert.Equal("Pages 3–4", PageLabel.Text(On((0, 3), (0, 2)), [5]));
        Assert.Equal("Pages 1, 8", PageLabel.Text(On((0, 7), (0, 0)), [8]));
    }

    [Fact]
    public void Text_RunsOnOverTheDocuments()
    {
        Assert.Equal("Page 5", PageLabel.Text(On((1, 0)), [4, 2]));
    }

    [Fact]
    public void Text_ASideWithoutPagesIsBlank_AndCopiesCountOnce()
    {
        Assert.Equal("Blank", PageLabel.Text(On(), [4]));
        Assert.Equal("Page 2", PageLabel.Text(On((0, 1), (0, 1)), [4]));
    }
}
