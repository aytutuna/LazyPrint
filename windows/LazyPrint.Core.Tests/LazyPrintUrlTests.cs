using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/LazyPrintUrlTests.swift (the same addresses). The two differ
// only in which paths they take: here local drive paths, there absolute ones.

public class LazyPrintUrlTests
{
    [Fact]
    public void OneFile_IsTakenPercentDecoded()
    {
        Assert.Equal([@"C:\Users\me\AppData\Local\Temp\scan 1.pdf"],
                     LazyPrintUrl.Parse("lazyprint:open?file=C%3A%5CUsers%5Cme%5CAppData%5CLocal%5CTemp%5Cscan%201.pdf"));
    }

    [Fact]
    public void RepeatedFiles_AreTakenInOrder()
    {
        Assert.Equal([@"C:\a.pdf", @"D:\b c.pdf", @"C:\a.pdf"],
                     LazyPrintUrl.Parse("lazyprint:open?file=C%3A%5Ca.pdf&file=D%3A%5Cb%20c.pdf&file=C%3A%5Ca.pdf"));
    }

    [Theory]
    [InlineData("lazyprint:open?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:?file=C%3A%5Ca.pdf#top")]
    [InlineData("lazyprint://open?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:///open?file=C%3A%5Ca.pdf")]
    [InlineData("LazyPrint:Open?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:open?other=1&file=C%3A%5Ca.pdf&extra")]
    public void TheSchemeAndPath_AreOpenOrNone(string url)
    {
        Assert.Equal([@"C:\a.pdf"], LazyPrintUrl.Parse(url));
    }

    [Fact]
    public void AForwardSlashDrivePath_IsLocalToo()
    {
        Assert.Equal(["C:/Temp/a.pdf"], LazyPrintUrl.Parse("lazyprint:open?file=C%3A%2FTemp%2Fa.pdf"));
    }

    [Fact]
    public void NonAsciiPaths_AreDecodedFromUtf8()
    {
        Assert.Equal([@"C:\Belgeler\Çalışma ağacı.pdf"],
                     LazyPrintUrl.Parse("lazyprint:open?file=C%3A%5CBelgeler%5C%C3%87al%C4%B1%C5%9Fma%20a%C4%9Fac%C4%B1.pdf"));
    }

    [Theory]
    [InlineData("lazyscan:open?file=C%3A%5Ca.pdf")]
    [InlineData("https://example.com/open?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint2:open?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:close?file=C%3A%5Ca.pdf")]
    [InlineData("lazyprint:open/more?file=C%3A%5Ca.pdf")]
    [InlineData("xlazyprint:open?file=C%3A%5Ca.pdf")]
    [InlineData("")]
    [InlineData("lazyprint")]
    [InlineData("C:\\a.pdf")]
    public void AnotherAddress_GivesNothing(string url)
    {
        Assert.Empty(LazyPrintUrl.Parse(url));
    }

    [Fact]
    public void NoFile_GivesNothing()
    {
        Assert.Empty(LazyPrintUrl.Parse(null));
        Assert.Empty(LazyPrintUrl.Parse("lazyprint:open"));
        Assert.Empty(LazyPrintUrl.Parse("lazyprint:open?"));
        Assert.Empty(LazyPrintUrl.Parse("lazyprint:open?file="));
        Assert.Empty(LazyPrintUrl.Parse("lazyprint:open?files=C%3A%5Ca.pdf&File=C%3A%5Ca.pdf"));
    }

    [Theory]
    [InlineData("%5C%5Cserver%5Cshare%5Ca.pdf")]               // \\server\share\a.pdf
    [InlineData("%5C%5C%3F%5CC%3A%5Ca.pdf")]                   // \\?\C:\a.pdf
    [InlineData("%5C%5C%3F%5CUNC%5Cserver%5Cshare%5Ca.pdf")]   // \\?\UNC\server\share\a.pdf
    [InlineData("%5C%5C.%5CC%3A%5Ca.pdf")]                     // \\.\C:\a.pdf
    [InlineData("%2F%2Fserver%2Fshare%2Fa.pdf")]               // //server/share/a.pdf
    [InlineData("%5Ca.pdf")]                                   // \a.pdf, on the current drive
    [InlineData("C%3Aa.pdf")]                                  // C:a.pdf, relative to the drive's folder
    [InlineData("a.pdf")]
    [InlineData("..%5Ca.pdf")]
    [InlineData("%2Ftmp%2Fa.pdf")]
    [InlineData("file%3A%2F%2F%2FC%3A%2Fa.pdf")]
    [InlineData("1%3A%5Ca.pdf")]
    [InlineData("C%3A%5Ca%00.pdf")]
    public void APathThatIsNotALocalDrivePath_IsDropped(string path)
    {
        Assert.Empty(LazyPrintUrl.Parse("lazyprint:open?file=" + path));
    }

    [Fact]
    public void TheOtherFiles_StillCome()
    {
        Assert.Equal([@"C:\a.pdf", @"D:\b.pdf"],
                     LazyPrintUrl.Parse("lazyprint:open?file=C%3A%5Ca.pdf&file=%5C%5Cserver%5Cshare%5Cx.pdf&file=D%3A%5Cb.pdf"));
    }
}
