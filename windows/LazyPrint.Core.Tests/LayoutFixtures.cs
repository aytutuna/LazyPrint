using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

internal static class LayoutFixtures
{
    public static readonly LayoutSize Letter = new(612, 792);
    public static readonly LayoutSize A4 = PaperSizes.Points(PaperSize.A4)!.Value;

    public static PrintableArea Whole(LayoutSize paper) => new(paper, new LayoutInsets(0, 0, 0, 0));

    public static PrintableArea Margins(LayoutSize paper, double margin) => new(paper, new LayoutInsets(margin, margin, margin, margin));

    public static SourcePage Page(int index, double width, double height, int document = 0) =>
        new(document, index, new LayoutSize(width, height));

    public static List<SourcePage> Portrait(int count) =>
        [.. Enumerable.Range(0, count).Select(i => Page(i, 612, 792))];

    public static void AssertRect(double x, double y, double width, double height, LayoutRect actual, double tolerance = 0.0001)
    {
        Assert.Equal(x, actual.X, tolerance);
        Assert.Equal(y, actual.Y, tolerance);
        Assert.Equal(width, actual.Width, tolerance);
        Assert.Equal(height, actual.Height, tolerance);
    }
}
