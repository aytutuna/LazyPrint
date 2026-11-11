using LazyPrint.App.Printing;
using Xunit;

namespace LazyPrint.App.Tests;

public class VectorSpoolTests
{
    [Fact]
    public void ThePaperStartsAtTheUnprintableMarginAtItsOwnSize()
    {
        Assert.Equal((-50, -75, 2550, 3300), VectorSpool.PaperRect(612, 792, 300, 300, 50, 75));
        // A4 stays A4 on a printer whose driver picked Letter, and the two axes can differ in resolution.
        Assert.Equal((0, 0, 2480, 3508), VectorSpool.PaperRect(595.28, 841.89, 300, 300, 0, 0));
        Assert.Equal((0, 0, 1240, 3508), VectorSpool.PaperRect(595.28, 841.89, 150, 300, 0, 0));
    }

    [Fact]
    public void AMissingPdfiumIsUnavailable()
    {
        Assert.True(SheetPdf.Unavailable(new TypeInitializationException("Pdfium", new DllNotFoundException())));
        Assert.True(SheetPdf.Unavailable(new BadImageFormatException()));
        Assert.False(SheetPdf.Unavailable(new InvalidOperationException()));
    }
}
