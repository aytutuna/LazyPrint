using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/TextPagesTests.swift: the same cases.
public class TextPagesTests
{
    // 80 columns and 54 lines.
    private static readonly LayoutSize Letter = new(612, 792);

    [Fact]
    public void ShortLinesAreOnePage()
    {
        var pages = TextPages.Paginate("one\r\ntwo\nthree\r\n", Letter);

        Assert.Equal(["one", "two", "three"], Assert.Single(pages));
    }

    [Fact]
    public void NothingButWhiteSpaceIsNoPages()
    {
        Assert.Empty(TextPages.Paginate(" \r\n\t\f", Letter));
    }

    [Fact]
    public void ALongLineBreaksAtTheLastSpaceThatFits()
    {
        string line = string.Join(' ', Enumerable.Repeat("word", 30));

        var lines = Assert.Single(TextPages.Paginate(line, Letter));

        Assert.Equal(2, lines.Count);
        Assert.Equal(string.Join(' ', Enumerable.Repeat("word", 16)), lines[0]);
        Assert.Equal(string.Join(' ', Enumerable.Repeat("word", 14)), lines[1]);
    }

    [Fact]
    public void AWordLongerThanTheLineBreaksAtTheMargin()
    {
        var lines = Assert.Single(TextPages.Paginate(new string('x', 200), Letter));

        Assert.Equal([new string('x', 80), new string('x', 80), new string('x', 40)], lines);
    }

    [Fact]
    public void LinesFillAPageAndTheNextStarts()
    {
        var pages = TextPages.Paginate(string.Join('\n', Enumerable.Range(1, 55)), Letter);

        Assert.Equal(2, pages.Count);
        Assert.Equal(54, pages[0].Count);
        Assert.Equal(["55"], pages[1]);
    }

    [Fact]
    public void AFormFeedStartsAPage()
    {
        var pages = TextPages.Paginate("a\fb\f", Letter);

        Assert.Equal([["a"], ["b"]], pages);
    }

    [Fact]
    public void TabsAreStopsOfFourAndOtherControlCharactersAreDropped()
    {
        var lines = Assert.Single(TextPages.Paginate("a\tb\u0001c\n\tx", Letter));

        Assert.Equal(["a   bc", "    x"], lines);
    }

    [Fact]
    public void ACharacterOutsideThePlaneCountsOnce()
    {
        var lines = Assert.Single(TextPages.Paginate(new string('x', 79) + "\U0001F600" + "y", Letter));

        Assert.Equal(2, lines.Count);
        Assert.Equal("y", lines[1]);
    }

    [Fact]
    public void ASmallerPageHasFewerColumnsAndLines()
    {
        var pages = TextPages.Paginate(new string('x', 30), new LayoutSize(288, 144));

        // 288 - 108 = 180 wide is 28 columns; 144 - 108 = 36 high is 2 lines.
        Assert.Equal([new string('x', 28), "xx"], Assert.Single(pages));
    }

    [Fact]
    public void DecodeReadsUtf8WithOrWithoutAMark()
    {
        Assert.Equal("ğş", TextPages.Decode(Encoding.UTF8.GetBytes("ğş"), Encoding.Latin1));
        Assert.Equal("ğş", TextPages.Decode([0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("ğş")], Encoding.Latin1));
    }

    [Fact]
    public void DecodeReadsUtf16WithAMark()
    {
        Assert.Equal("hi", TextPages.Decode([0xFF, 0xFE, .. Encoding.Unicode.GetBytes("hi")], Encoding.Latin1));
        Assert.Equal("hi", TextPages.Decode([0xFE, 0xFF, .. Encoding.BigEndianUnicode.GetBytes("hi")], Encoding.Latin1));
    }

    [Fact]
    public void DecodeFallsBackWhenTheBytesAreNotUtf8()
    {
        Assert.Equal("café", TextPages.Decode([0x63, 0x61, 0x66, 0xE9], Encoding.Latin1));
    }
}
