using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintLayoutTests.swift: the same cases.

public class PrintLayoutTests
{
    // MARK: - Copies

    [Fact]
    public void Copies_Clamp_StaysWithinOneAndNinetyNine()
    {
        Assert.Equal(1, PrintCopies.Clamp(0));
        Assert.Equal(1, PrintCopies.Clamp(-5));
        Assert.Equal(7, PrintCopies.Clamp(7));
        Assert.Equal(99, PrintCopies.Clamp(500));
    }

    [Fact]
    public void Copies_OneCopy_IsOneEverywhere()
    {
        Assert.Equal(new PrintCopiesPlan(1, 1), PrintCopies.Plan(1, 99, 5));
    }

    [Fact]
    public void Copies_PrinterCanMakeThem_AsksThePrinter()
    {
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 99, 5));
    }

    [Fact]
    public void Copies_PrinterCannotMakeThatMany_RepeatsThePages()
    {
        Assert.Equal(new PrintCopiesPlan(1, 5), PrintCopies.Plan(5, 3, 2));
        Assert.Equal(new PrintCopiesPlan(1, 2), PrintCopies.Plan(2, null, 2));
    }

    [Fact]
    public void Copies_SeveralPagesWithoutCollation_RepeatsThePages()
    {
        Assert.Equal(new PrintCopiesPlan(1, 3), PrintCopies.Plan(3, 99, 4, canCollate: false));
        Assert.Equal(new PrintCopiesPlan(3, 1), PrintCopies.Plan(3, 99, 1, canCollate: false));
    }

    // MARK: - Ruler page

    [Fact]
    public void TickPosition_StartsAtTheFirstInchLineAndStepsACentimetre()
    {
        Assert.Equal(72, PrintCalibration.TickPosition(0), 1e-9);
        Assert.Equal(72 + 72 / 2.54, PrintCalibration.TickPosition(1), 1e-9);
        Assert.Equal(72 + 10 * 72 / 2.54, PrintCalibration.TickPosition(10), 1e-9);
    }

    [Fact]
    public void MakeRulerPage_Letter_HasAnInchGridAndCentimetreTicks()
    {
        var lines = PrintCalibration.MakeRulerPage(Letter).OfType<TestPageItem.Line>().ToList();
        var grey = lines.Where(l => l.Color == TestColor.Gray(128)).ToList();
        var black = lines.Where(l => l.Color == TestColor.Black).ToList();
        // 8 vertical lines (72 to 576) and 10 horizontal ones (72 to 720); the paper's own edges are not drawn.
        Assert.Equal(8, grey.Count(l => l.From.X == l.To.X));
        Assert.Equal(10, grey.Count(l => l.From.Y == l.To.Y));
        Assert.Equal(72, grey[0].From.X);
        Assert.Equal(792, grey[0].To.Y);
        // Ticks every centimetre from the first inch line: 20 across (to 610.6 pt), 26 down (to 780.6 pt).
        Assert.Equal(20, black.Count(l => l.From.X == l.To.X));
        Assert.Equal(26, black.Count(l => l.From.Y == l.To.Y));
    }

    [Fact]
    public void MakeRulerPage_Ticks_AreLongEveryFiveCentimetres()
    {
        var across = PrintCalibration.MakeRulerPage(Letter).OfType<TestPageItem.Line>()
            .Where(l => l.Color == TestColor.Black && l.From.X == l.To.X).ToList();
        Assert.Equal(0.3 * 72, across[0].To.Y - across[0].From.Y, 1e-9);
        Assert.Equal(0.15 * 72, across[1].To.Y - across[1].From.Y, 1e-9);
        Assert.Equal(0.3 * 72, across[5].To.Y - across[5].From.Y, 1e-9);
        Assert.Equal(72, across[0].From.Y);
        Assert.Equal(PrintCalibration.LineWidth, across[0].Width);
    }
}
