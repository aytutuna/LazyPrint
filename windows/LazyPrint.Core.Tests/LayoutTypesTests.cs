using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/LayoutTypesTests.swift: the same cases.

public class LayoutTypesTests
{
    private static readonly PrintableArea Uneven = new(Letter, new LayoutInsets(Top: 10, Left: 20, Bottom: 30, Right: 40));

    [Fact]
    public void Printable_IsThePaperInsideTheMargins()
    {
        AssertRect(20, 10, 552, 752, Uneven.Printable);
        AssertRect(0, 0, 612, 792, Whole(Letter).Printable);
    }

    [Fact]
    public void Printable_MarginsLargerThanThePaper_IsEmpty()
    {
        var printable = Margins(Letter, 400).Printable;
        Assert.Equal(0, printable.Width);
        Assert.Equal(0, printable.Height);
    }

    [Fact]
    public void Symmetric_RaisesEachMarginToTheLargerOfItAndItsOpposite()
    {
        Assert.Equal(new LayoutInsets(30, 40, 30, 40), Uneven.Symmetric.Margins);
        Assert.Equal(Letter, Uneven.Symmetric.Paper);
        AssertRect(40, 30, 532, 732, Uneven.Symmetric.Printable);
    }

    [Fact]
    public void Symmetric_AlreadySymmetric_IsUnchanged()
    {
        var area = Margins(Letter, 12);
        Assert.Equal(area, area.Symmetric);
    }

    [Fact]
    public void LayoutOptions_Defaults_AreOnePageShrunkToFitOneSided()
    {
        var options = new LayoutOptions();
        Assert.Equal(1, options.PagesPerSheet);
        Assert.False(options.Booklet);
        Assert.False(options.RightToLeft);
        Assert.Equal(Scaling.ShrinkToFit, options.Scaling);
        Assert.Equal(Sides.OneSided, options.Sides);
        Assert.False(options.PageBorders);
        Assert.Equal(Scaling.ShrinkToFit, default);
        Assert.Equal(Sides.OneSided, default);
    }

    [Fact]
    public void SideCount_CountsEveryFrontAndBack()
    {
        var empty = new SheetSide([], false);
        var plan = new SheetPlan(Whole(Letter), [new Sheet(empty, empty), new Sheet(empty, null)], false, []);
        Assert.Equal(3, plan.SideCount);
    }
}
