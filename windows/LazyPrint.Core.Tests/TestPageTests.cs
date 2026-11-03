using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/TestPageTests.swift: the same cases.

public class TestPageTests
{
    private static readonly TestPageInfo Info = new("Office Printer", "Acme LaserJet 4000", "ipp://192.168.1.20:631/ipp/print", "2026-11-03");
    private const double Millimetre = 72 / 25.4;

    private static IReadOnlyList<TestPageItem> Make(PrintableArea area) => TestPage.Make(area, Info);

    private static IEnumerable<TestPageItem.Line> Lines(IReadOnlyList<TestPageItem> items) => items.OfType<TestPageItem.Line>();

    private static double Length(TestPageItem.Line line) =>
        Math.Sqrt(Math.Pow(line.To.X - line.From.X, 2) + Math.Pow(line.To.Y - line.From.Y, 2));

    [Fact]
    public void Make_Texts_NameThePrinterModelAddressAndDate()
    {
        var texts = Make(Whole(Letter)).OfType<TestPageItem.Text>().Select(t => t.Value).ToList();
        Assert.Contains("Office Printer", texts);
        Assert.Contains("Acme LaserJet 4000", texts);
        Assert.Contains("ipp://192.168.1.20:631/ipp/print", texts);
        Assert.Contains("2026-11-03", texts);
    }

    [Fact]
    public void Make_ColorBars_AreCyanMagentaYellowBlackRedGreenBlueInARow()
    {
        var items = Make(Whole(Letter));
        var bars = items.OfType<TestPageItem.Rect>().Take(7).ToList();
        Assert.Equal([TestColor.Cyan, TestColor.Magenta, TestColor.Yellow, TestColor.Black, TestColor.Red, TestColor.Green, TestColor.Blue],
                     bars.Select(b => b.Fill));
        Assert.Single(bars.Select(b => b.Bounds.Y).Distinct());
        Assert.Equal(bars.Select(b => b.Bounds.X).OrderBy(x => x), bars.Select(b => b.Bounds.X));
    }

    [Fact]
    public void Make_GrayRamp_HasElevenStepsFromWhiteToBlack()
    {
        var steps = Make(Whole(Letter)).OfType<TestPageItem.Rect>().Skip(7).ToList();
        Assert.Equal(11, steps.Count);
        Assert.Equal(TestColor.White, steps[0].Fill);
        Assert.Equal(TestColor.Black, steps[10].Fill);
        // 10 % of 255 is 25.5: each step is that much darker than the one before.
        Assert.Equal(Enumerable.Range(0, 11).Select(i => (byte)Math.Round(255 - 25.5 * i)), steps.Select(s => s.Fill.R));
    }

    [Fact]
    public void Make_RealSizeChecks_AreAnInchSquareAndATenCentimetreRuler()
    {
        var lines = Lines(Make(Whole(Letter))).ToList();
        var inch = lines.Where(l => Math.Abs(Length(l) - 72) < 0.0001 && l.Width == PrintCalibration.LineWidth).ToList();
        Assert.Equal(4, inch.Count);
        var ruler = lines.Single(l => Math.Abs(Length(l) - 100 * 72 / 25.4) < 0.0001);
        Assert.Equal(ruler.From.Y, ruler.To.Y);
        var ticks = lines.Where(l => l.From.X == l.To.X && l.From.Y == ruler.From.Y).OrderBy(l => l.From.X).ToList();
        Assert.Equal(11, ticks.Count);
        Assert.Equal(10 * 72 / 2.54, ticks[10].From.X - ticks[0].From.X, 0.0001);
        Assert.Equal(0.3 * 72, Length(ticks[5]), 0.0001);
        Assert.Equal(0.15 * 72, Length(ticks[3]), 0.0001);
    }

    [Fact]
    public void Make_FineGrid_IsFinerThanOneMillimetre()
    {
        var fine = Lines(Make(Whole(Letter))).Where(l => l.Width < 0.5).ToList();
        Assert.NotEmpty(fine);
        var verticals = fine.Where(l => l.From.X == l.To.X).Select(l => l.From.X).Distinct().OrderBy(x => x).ToList();
        Assert.True(verticals[1] - verticals[0] < 2 * Millimetre);
    }

    [Fact]
    public void Make_Edge_IsDrawnTwoMillimetresInsideThePrintableArea()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(10, 20, 30, 40));
        var edge = Lines(Make(area)).Take(4).ToList();
        double inset = 2 * Millimetre;
        Assert.Equal(20 + inset, edge.Min(l => Math.Min(l.From.X, l.To.X)), 0.0001);
        Assert.Equal(612 - 40 - inset, edge.Max(l => Math.Max(l.From.X, l.To.X)), 0.0001);
        Assert.Equal(10 + inset, edge.Min(l => Math.Min(l.From.Y, l.To.Y)), 0.0001);
        Assert.Equal(792 - 30 - inset, edge.Max(l => Math.Max(l.From.Y, l.To.Y)), 0.0001);
    }

    [Theory]
    [InlineData(false, 0)]
    [InlineData(false, 18)]
    [InlineData(true, 0)]
    [InlineData(true, 36)]
    public void Make_Everything_StaysInsideThePrintableArea(bool a4, double margin)
    {
        AssertEverythingInside(Margins(a4 ? A4 : Letter, margin));
    }

    [Fact]
    public void Make_Everything_StaysInsideSmallPaper()
    {
        AssertEverythingInside(Whole(new LayoutSize(298, 420)));
        AssertEverythingInside(Whole(new LayoutSize(288, 432)));
    }

    [Fact]
    public void Make_Ruler_IsShortenedToWholeCentimetresOnNarrowPaper()
    {
        var items = Make(Whole(new LayoutSize(298, 420)));
        Assert.Contains(items.OfType<TestPageItem.Text>(), t => t.Value == "8 cm");
        Assert.Single(Lines(items), l => Math.Abs(Length(l) - 8 * 72 / 2.54) < 0.0001);
    }

    private static void AssertEverythingInside(PrintableArea area)
    {
        var printable = area.Printable;
        foreach (var item in Make(area))
        {
            switch (item)
            {
                case TestPageItem.Rect rect:
                    AssertInside(printable, rect.Bounds.X, rect.Bounds.Y);
                    AssertInside(printable, rect.Bounds.X + rect.Bounds.Width, rect.Bounds.Y + rect.Bounds.Height);
                    break;
                case TestPageItem.Line line:
                    AssertInside(printable, line.From.X, line.From.Y);
                    AssertInside(printable, line.To.X, line.To.Y);
                    break;
                case TestPageItem.Text text:
                    AssertInside(printable, text.At.X, text.At.Y);
                    break;
            }
        }
    }

    private static void AssertInside(LayoutRect printable, double x, double y)
    {
        Assert.InRange(x, printable.X - 0.0001, printable.X + printable.Width + 0.0001);
        Assert.InRange(y, printable.Y - 0.0001, printable.Y + printable.Height + 0.0001);
    }
}
