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
}
