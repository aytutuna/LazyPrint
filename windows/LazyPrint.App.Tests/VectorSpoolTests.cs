using LazyPrint.App.Printing;
using Xunit;

namespace LazyPrint.App.Tests;

public class VectorSpoolTests
{
    [Fact]
    public void ThePaperStartsAtTheUnprintableMargin()
    {
        Assert.Equal((-50, -75, 2550, 3300), VectorSpool.PaperRect(2550, 3300, 50, 75));
    }

    [Fact]
    public void AMissingPdfiumIsUnavailable()
    {
        Assert.True(SheetPdf.Unavailable(new TypeInitializationException("Pdfium", new DllNotFoundException())));
        Assert.True(SheetPdf.Unavailable(new BadImageFormatException()));
        Assert.False(SheetPdf.Unavailable(new InvalidOperationException()));
    }
}
