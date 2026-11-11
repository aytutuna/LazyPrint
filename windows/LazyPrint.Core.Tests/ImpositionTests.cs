using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/ImpositionTests.swift: the same cases.

public class ImpositionTests
{
    private static SheetPlan Plan(IReadOnlyList<SourcePage> pages, LayoutOptions options, PrintableArea? area = null) =>
        Imposition.Plan(pages, options, area ?? Whole(Letter));

    private static SheetSide Front(SheetPlan plan, int sheet = 0) => plan.Sheets[sheet].Front;

    private static SheetSide Back(SheetPlan plan, int sheet = 0) => plan.Sheets[sheet].Back!;

    /// <summary>The page indices of a booklet side, left page then right page as the reader sees the spread; -1 is blank.</summary>
    private static (int Left, int Right) Spread(SheetSide side, bool turned)
    {
        int left = -1, right = -1;
        foreach (var placement in side.Placements)
        {
            // The spread's left half is the lower half of the sheet, or the upper half once the side is turned.
            bool lower = placement.Frame.Y + placement.Frame.Height / 2 > Letter.Height / 2;
            if (lower != turned) left = placement.Page.Index;
            else right = placement.Page.Index;
        }
        return (left, right);
    }

    /// <summary>Row and column of a placement in the reading view of a grid on Letter paper.</summary>
    private static (int Row, int Column) CellOf(Placement placement, bool landscape, int rows, int columns)
    {
        double centreX = placement.Frame.X + placement.Frame.Width / 2, centreY = placement.Frame.Y + placement.Frame.Height / 2;
        double u = landscape ? Letter.Height - centreY : centreX, v = landscape ? centreX : centreY;
        double viewWidth = landscape ? Letter.Height : Letter.Width, viewHeight = landscape ? Letter.Width : Letter.Height;
        return ((int)(v / (viewHeight / rows)), (int)(u / (viewWidth / columns)));
    }

    // MARK: - One page per side

    [Fact]
    public void Plan_NoPages_HasNoSheets()
    {
        var plan = Plan([], new LayoutOptions());
        Assert.Empty(plan.Sheets);
        Assert.Equal(0, plan.SideCount);
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_SmallPageShrinkToFit_PrintsAtRealSizeCentred()
    {
        var plan = Plan([Page(0, 300, 400)], new LayoutOptions());
        var placement = Assert.Single(Front(plan).Placements);
        AssertRect(156, 196, 300, 400, placement.Frame);
        Assert.Equal(0, placement.Turns);
        Assert.Null(placement.Crop);
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_LargePageShrinkToFit_IsMadeSmallerAndWarns()
    {
        var plan = Plan([Page(0, A4.Width, A4.Height)], new LayoutOptions());
        // A4 is about 50 pt taller than Letter and 17 pt narrower: the height decides.
        double scale = 792 / A4.Height, width = A4.Width * scale;
        AssertRect((612 - width) / 2, 0, width, 792, Assert.Single(Front(plan).Placements).Frame);
        Assert.Equal([new PlanWarning.Shrunk(94)], plan.Warnings);
    }

    [Fact]
    public void Plan_SmallPageFit_IsMadeAsLargeAsFits()
    {
        var plan = Plan([Page(0, 306, 396)], new LayoutOptions { Scaling = Scaling.Fit });
        AssertRect(0, 0, 612, 792, Assert.Single(Front(plan).Placements).Frame);
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_PageLargerThanAreaActualSize_IsCutAndWarns()
    {
        var plan = Plan([Page(0, 700, 900)], new LayoutOptions { Scaling = Scaling.ActualSize });
        AssertRect(-44, -54, 700, 900, Assert.Single(Front(plan).Placements).Frame);
        // 108 pt too tall, half of it off each side.
        Assert.Equal([new PlanWarning.Clipped(54)], plan.Warnings);
    }

    [Fact]
    public void Plan_Scale_SizesAPageAloneOnItsSideAndShrinkToFitStillKeepsItInside()
    {
        var half = Plan([Page(0, 306, 396)], new LayoutOptions { Scaling = Scaling.ActualSize, Scale = 50 });
        AssertRect(153, 198, 153, 198, Assert.Single(Front(half).Placements).Frame);

        var big = Plan([Page(0, 306, 396)], new LayoutOptions { Scale = 400 });
        AssertRect(0, 0, 612, 792, Assert.Single(Front(big).Placements).Frame);
    }

    [Fact]
    public void Plan_ActualSizeCutByLessThanAMillimetre_DoesNotWarn()
    {
        var plan = Plan([Page(0, 613, 792)], new LayoutOptions { Scaling = Scaling.ActualSize });
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_Fill_CropsInTheMiddleToTheArea()
    {
        var plan = Plan([Page(0, 400, 400)], new LayoutOptions { Scaling = Scaling.Fill });
        var placement = Assert.Single(Front(plan).Placements);
        AssertRect(0, 0, 612, 792, placement.Frame);
        // Scale 792 / 400 = 1.98, so 612 / 1.98 of the width shows.
        AssertRect((400 - 612 / 1.98) / 2, 0, 612 / 1.98, 400, placement.Crop!.Value);
    }

    [Fact]
    public void Plan_LandscapePage_IsTurnedAQuarterCounterclockwiseOntoPortraitPaper()
    {
        var plan = Plan([Page(0, 792, 612)], new LayoutOptions());
        var placement = Assert.Single(Front(plan).Placements);
        AssertRect(0, 0, 612, 792, placement.Frame);
        Assert.Equal(3, placement.Turns);
    }

    [Fact]
    public void Plan_LandscapePageWithMargins_IsCentredInTheTurnedPrintableArea()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(Top: 20, Left: 10, Bottom: 40, Right: 30));
        var plan = Plan([Page(0, 366, 286)], new LayoutOptions(), area);
        // The reading view is 732 wide (792 - 20 - 40) and 572 high (612 - 10 - 30), its top the paper's left edge.
        AssertRect(153, 203, 286, 366, Assert.Single(Front(plan).Placements).Frame);
    }

    [Fact]
    public void Plan_SquarePage_StaysUpright()
    {
        var placement = Assert.Single(Front(Plan([Page(0, 300, 300)], new LayoutOptions())).Placements);
        Assert.Equal(0, placement.Turns);
    }

    [Fact]
    public void Plan_SeveralDocuments_RunOnAsOne()
    {
        var pages = new List<SourcePage> { Page(0, 612, 792, 0), Page(1, 612, 792, 0), Page(0, 612, 792, 1) };
        var plan = Plan(pages, new LayoutOptions { PagesPerSheet = 4 });
        var placements = Assert.Single(plan.Sheets).Front.Placements;
        Assert.Equal([(0, 0), (0, 1), (1, 0)], placements.Select(p => (p.Page.Document, p.Page.Index)));
    }

    [Fact]
    public void Plan_OneSided_HasNoBackAndTheGivenArea()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(20, 10, 40, 30));
        var plan = Plan(Portrait(2), new LayoutOptions(), area);
        Assert.False(plan.Duplex);
        Assert.Equal(area, plan.Area);
        Assert.All(plan.Sheets, sheet => Assert.Null(sheet.Back));
        Assert.Equal(2, plan.SideCount);
    }

    // MARK: - Two-sided

    [Fact]
    public void Plan_TwoSided_UsesTheSymmetricAreaOnBothSides()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(20, 10, 40, 30));
        var plan = Plan(Portrait(2), new LayoutOptions { Sides = Sides.LongEdge }, area);
        Assert.Equal(area.Symmetric, plan.Area);
        Assert.Equal(new LayoutInsets(40, 30, 40, 30), plan.Area.Margins);
        // Both pages shrink to the same box, so the back lines up with the front.
        double scale = Math.Min((612 - 60) / 612.0, (792 - 80) / 792.0);
        AssertRect((612 - 612 * scale) / 2, 40, 612 * scale, 792 * scale, Assert.Single(Front(plan).Placements).Frame);
        Assert.Equal(Front(plan).Placements[0].Frame, Back(plan).Placements[0].Frame);
    }

    [Theory]
    [InlineData(false, Sides.LongEdge, "T", "T", false)]
    [InlineData(false, Sides.ShortEdge, "T", "B", true)]
    [InlineData(true, Sides.LongEdge, "L", "R", false)]
    [InlineData(true, Sides.ShortEdge, "L", "L", true)]
    public void Plan_BackTurn_FollowsTheFlipEdge(bool landscape, Sides sides, string frontTop, string backTop, bool backTurned)
    {
        var page = landscape ? Page(0, 792, 612) : Page(0, 612, 792);
        var plan = Plan([page, page with { Index = 1 }], new LayoutOptions { Sides = sides });
        var front = Front(plan).Placements[0];
        var back = Back(plan).Placements[0];
        // A page's top lies at T, R, B, L for 0..3 turns; the back image is mirrored left to right once the sheet turns over.
        Assert.Equal(frontTop, "TRBL"[front.Turns].ToString());
        Assert.Equal(backTop, "TLBR"[back.Turns].ToString());
        Assert.Equal(backTurned, (back.Turns - front.Turns + 4) % 4 == 2);
    }

    [Fact]
    public void Plan_BookletBack_IsTurnedAndItsTopLiesAtTheFrontsTop()
    {
        var plan = Plan(Portrait(4), new LayoutOptions { Booklet = true });
        var front = Front(plan).Placements[0];
        var back = Back(plan).Placements[0];
        Assert.Equal("L", "TRBL"[front.Turns].ToString());
        Assert.Equal("L", "TLBR"[back.Turns].ToString());
    }

    [Fact]
    public void Plan_ShortEdgeBack_LandsInTheSameBoxAsTheFront()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(20, 10, 40, 30));
        var plan = Plan([Page(0, 300, 400), Page(1, 300, 400)], new LayoutOptions { Sides = Sides.ShortEdge }, area);
        // The symmetric area is centred on the paper, so a half turn about the paper's centre keeps the box.
        AssertRect(156, 196, 300, 400, Front(plan).Placements[0].Frame);
        AssertRect(156, 196, 300, 400, Back(plan).Placements[0].Frame);
        Assert.Equal(2, Back(plan).Placements[0].Turns);
    }

    [Fact]
    public void Plan_TwoSidedOddPageCount_GivesTheLastSheetABlankBack()
    {
        var plan = Plan(Portrait(3), new LayoutOptions { Sides = Sides.LongEdge });
        Assert.True(plan.Duplex);
        Assert.Equal(2, plan.Sheets.Count);
        Assert.Empty(Back(plan, 1).Placements);
        Assert.Equal(4, plan.SideCount);
    }

    [Theory]
    [InlineData(Sides.LongEdge)]
    [InlineData(Sides.ShortEdge)]
    public void Plan_TwoSided_HasAnEvenSideCountForAnyPageCount(Sides sides)
    {
        for (int count = 1; count <= 9; count++)
        {
            var plan = Plan(Portrait(count), new LayoutOptions { Sides = sides, PagesPerSheet = 2 });
            Assert.Equal(0, plan.SideCount % 2);
        }
    }

    // MARK: - Several pages per side

    [Theory]
    [InlineData(2, 1, 2, true)]
    [InlineData(4, 2, 2, false)]
    [InlineData(6, 2, 3, true)]
    [InlineData(9, 3, 3, false)]
    [InlineData(16, 4, 4, false)]
    public void Plan_NUpPortraitPages_FillsTheGridInReadingOrder(int perSheet, int rows, int columns, bool landscape)
    {
        var plan = Plan(Portrait(perSheet), new LayoutOptions { PagesPerSheet = perSheet });
        var placements = Assert.Single(plan.Sheets).Front.Placements;
        Assert.Equal(perSheet, placements.Count);
        for (int i = 0; i < perSheet; i++)
        {
            Assert.Equal((i / columns, i % columns), CellOf(placements[i], landscape, rows, columns));
            Assert.Equal(landscape ? 3 : 0, placements[i].Turns);
        }
    }

    [Theory]
    [InlineData(2, 1, 2, true)]
    [InlineData(4, 2, 2, false)]
    [InlineData(6, 2, 3, true)]
    public void Plan_NUpRightToLeft_ReadsEachRowFromTheRight(int perSheet, int rows, int columns, bool landscape)
    {
        var plan = Plan(Portrait(perSheet), new LayoutOptions { PagesPerSheet = perSheet, RightToLeft = true });
        var placements = Assert.Single(plan.Sheets).Front.Placements;
        for (int i = 0; i < perSheet; i++)
        {
            Assert.Equal((i / columns, columns - 1 - i % columns), CellOf(placements[i], landscape, rows, columns));
        }
    }

    [Fact]
    public void Plan_TwoUp_PlacesPagesInTheHalvesOfALandscapeView()
    {
        var plan = Plan(Portrait(2), new LayoutOptions { PagesPerSheet = 2 });
        var placements = Front(plan).Placements;
        // A 396 x 612 cell holds a 612 x 792 page at 396 / 612.
        double height = 792 * 396 / 612.0;
        AssertRect((612 - height) / 2, 396, height, 396, placements[0].Frame);
        AssertRect((612 - height) / 2, 0, height, 396, placements[1].Frame);
    }

    [Theory]
    [InlineData(4, 612, 792, 0)]
    [InlineData(9, 612, 792, 0)]
    [InlineData(16, 612, 792, 0)]
    [InlineData(4, 792, 612, 3)]
    public void Plan_NUpTie_ChoosesTheViewWherePagesNeedNoTurn(int perSheet, double width, double height, int turns)
    {
        // Both views make the first page the same size; the one where it needs no quarter turn in its cell wins.
        var pages = Enumerable.Range(0, perSheet).Select(i => Page(i, width, height)).ToList();
        var placements = Front(Plan(pages, new LayoutOptions { PagesPerSheet = perSheet })).Placements;
        Assert.All(placements, p => Assert.Equal(turns, p.Turns));
    }

    [Fact]
    public void Plan_SameInput_GivesEqualPlans()
    {
        var pages = Enumerable.Range(0, 6).Select(i => Page(i, 612, 792)).ToList();
        var options = new LayoutOptions { PagesPerSheet = 2 };
        Assert.Equal(Plan(pages, options), Plan(pages, options));
        Assert.Equal(Front(Plan(pages, options)), Front(Plan(pages, options)));
    }

    [Fact]
    public void Plan_NUpTieOfALandscapePage_ChoosesTheLandscapeView()
    {
        var pages = Enumerable.Range(0, 4).Select(i => Page(i, 792, 612)).ToList();
        var placements = Front(Plan(pages, new LayoutOptions { PagesPerSheet = 4 })).Placements;
        // The portrait view would put the first page at (0, 0, 306, 396).
        AssertRect(0, 396, 306, 396, placements[0].Frame);
    }

    [Fact]
    public void Plan_NUpGrid_IsChosenFromTheFirstPageOnly()
    {
        var pages = new List<SourcePage> { Page(0, 612, 792), Page(1, 792, 612), Page(2, 612, 792), Page(3, 612, 792) };
        var placements = Front(Plan(pages, new LayoutOptions { PagesPerSheet = 4 })).Placements;
        Assert.Equal(0, placements[0].Turns);
        // The landscape page is turned in its cell because that makes it strictly larger.
        Assert.Equal(3, placements[1].Turns);
        Assert.Equal(0, placements[2].Turns);
    }

    [Fact]
    public void Plan_TwoUpLandscapePages_StackUprightInAPortraitView()
    {
        var pages = new List<SourcePage> { Page(0, 792, 612), Page(1, 792, 612) };
        var placements = Front(Plan(pages, new LayoutOptions { PagesPerSheet = 2 })).Placements;
        // Two rows of 612 x 396 cells take the pages unturned, as large as turning them in the landscape view would.
        Assert.All(placements, p => Assert.Equal(0, p.Turns));
        double width = 792 * 396 / 612.0;
        AssertRect((612 - width) / 2, 0, width, 396, placements[0].Frame);
        AssertRect((612 - width) / 2, 396, width, 396, placements[1].Frame);
    }

    [Fact]
    public void Plan_NUpFill_CropsEachPageToItsCell()
    {
        var pages = new List<SourcePage> { Page(0, 400, 400), Page(1, 400, 400) };
        var placement = Front(Plan(pages, new LayoutOptions { PagesPerSheet = 2, Scaling = Scaling.Fill })).Placements[0];
        AssertRect(0, 0, 612, 396, placement.Frame);
        // The 612 x 396 cell scales the square by 1.53, so 396 / 1.53 of its height shows.
        double shown = 396 / (612 / 400.0);
        AssertRect(0, (400 - shown) / 2, 400, shown, placement.Crop!.Value);
    }

    [Theory]
    [InlineData(Scaling.ShrinkToFit)]
    [InlineData(Scaling.ActualSize)]
    [InlineData(Scaling.Fit)]
    public void Plan_NUp_TreatsActualSizeAndShrinkToFitAsFit(Scaling scaling)
    {
        var tiny = Enumerable.Range(0, 4).Select(i => Page(i, 100, 130)).ToList();
        var plan = Plan(tiny, new LayoutOptions { PagesPerSheet = 4, Scaling = scaling });
        // The 306 x 396 cell enlarges the page: 396 / 130 is the smaller of the two scales.
        double scale = Math.Min(306 / 100.0, 396 / 130.0);
        Assert.Equal(100 * scale, Front(plan).Placements[0].Frame.Width, 0.0001);
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_NUpPartialLastSheet_HasOnlyTheRemainingPages()
    {
        var plan = Plan(Portrait(5), new LayoutOptions { PagesPerSheet = 4 });
        Assert.Equal(2, plan.Sheets.Count);
        Assert.Equal(4, Front(plan, 0).Placements.Count);
        Assert.Equal(4, Assert.Single(Front(plan, 1).Placements).Page.Index);
    }

    [Fact]
    public void Plan_NUpTwoSided_FillsFrontThenBack()
    {
        var plan = Plan(Portrait(9), new LayoutOptions { PagesPerSheet = 4, Sides = Sides.LongEdge });
        Assert.Equal(2, plan.Sheets.Count);
        Assert.Equal([0, 1, 2, 3], Front(plan, 0).Placements.Select(p => p.Page.Index));
        Assert.Equal([4, 5, 6, 7], Back(plan, 0).Placements.Select(p => p.Page.Index));
        Assert.Equal([8], Front(plan, 1).Placements.Select(p => p.Page.Index));
        Assert.Empty(Back(plan, 1).Placements);
    }

    [Fact]
    public void Plan_PageBorders_AreOnlyForSidesWithSeveralPages()
    {
        var single = Plan(Portrait(1), new LayoutOptions { PageBorders = true });
        var four = Plan(Portrait(1), new LayoutOptions { PageBorders = true, PagesPerSheet = 4 });
        var none = Plan(Portrait(4), new LayoutOptions { PagesPerSheet = 4 });
        Assert.False(Front(single).Borders);
        Assert.True(Front(four).Borders);
        Assert.False(Front(none).Borders);
    }

    [Fact]
    public void Plan_UnknownPagesPerSheet_IsOnePerSide()
    {
        var plan = Plan(Portrait(3), new LayoutOptions { PagesPerSheet = 3 });
        Assert.Equal(3, plan.Sheets.Count);
    }

    // MARK: - Booklet

    [Fact]
    public void Plan_BookletOfOnePage_IsPaddedToOneSheetWithOnlyTheFirstPageOnTheFront()
    {
        var plan = Plan(Portrait(1), new LayoutOptions { Booklet = true });
        var sheet = Assert.Single(plan.Sheets);
        Assert.Equal((-1, 0), Spread(sheet.Front, false));
        Assert.Empty(sheet.Back!.Placements);
        Assert.Equal([new PlanWarning.PaddedWithBlanks(3)], plan.Warnings);
    }

    [Fact]
    public void Plan_BookletOfFourPages_IsOneSheet()
    {
        var plan = Plan(Portrait(4), new LayoutOptions { Booklet = true });
        var sheet = Assert.Single(plan.Sheets);
        Assert.Equal((3, 0), Spread(sheet.Front, false));
        Assert.Equal((1, 2), Spread(sheet.Back!, true));
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_BookletOfFivePages_IsPaddedToEightAfterTheLastPage()
    {
        var plan = Plan(Portrait(5), new LayoutOptions { Booklet = true });
        Assert.Equal(2, plan.Sheets.Count);
        // Pages 5 to 7 are blank: sheet 0 front (7, 0) shows only page 0, back (1, 6) only page 1.
        Assert.Equal((-1, 0), Spread(Front(plan, 0), false));
        Assert.Equal((1, -1), Spread(Back(plan, 0), true));
        Assert.Equal((-1, 2), Spread(Front(plan, 1), false));
        Assert.Equal((3, 4), Spread(Back(plan, 1), true));
        Assert.Equal([new PlanWarning.PaddedWithBlanks(3)], plan.Warnings);
    }

    [Fact]
    public void Plan_BookletOfEightPages_NestsTwoSheets()
    {
        var plan = Plan(Portrait(8), new LayoutOptions { Booklet = true });
        Assert.Equal(2, plan.Sheets.Count);
        Assert.Equal((7, 0), Spread(Front(plan, 0), false));
        Assert.Equal((1, 6), Spread(Back(plan, 0), true));
        Assert.Equal((5, 2), Spread(Front(plan, 1), false));
        Assert.Equal((3, 4), Spread(Back(plan, 1), true));
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Plan_BookletOfTwelvePages_NestsThreeSheets()
    {
        var plan = Plan(Portrait(12), new LayoutOptions { Booklet = true });
        Assert.Equal(3, plan.Sheets.Count);
        Assert.Equal([(11, 0), (9, 2), (7, 4)], plan.Sheets.Select(s => Spread(s.Front, false)));
        Assert.Equal([(1, 10), (3, 8), (5, 6)], plan.Sheets.Select(s => Spread(s.Back!, true)));
    }

    [Fact]
    public void Plan_BookletRightToLeft_SwapsTheHalves()
    {
        var plan = Plan(Portrait(4), new LayoutOptions { Booklet = true, RightToLeft = true });
        Assert.Equal((0, 3), Spread(Front(plan), false));
        Assert.Equal((2, 1), Spread(Back(plan), true));
    }

    [Fact]
    public void Plan_Booklet_IgnoresSidesAndPagesPerSheetAndIsAlwaysTwoSided()
    {
        var plan = Plan(Portrait(4), new LayoutOptions { Booklet = true, Sides = Sides.OneSided, PagesPerSheet = 9 });
        Assert.True(plan.Duplex);
        Assert.Equal(2, plan.SideCount);
        Assert.Equal(2, Front(plan).Placements.Count);
        Assert.Equal(Whole(Letter).Symmetric, plan.Area);
    }

    [Fact]
    public void Plan_Booklet_FitsEachPageToHalfTheLandscapeSpread()
    {
        var front = Front(Plan(Portrait(4), new LayoutOptions { Booklet = true }));
        // Page 3 is the left half: a 396 x 612 half holds the page at 396 / 612.
        double height = 792 * 396 / 612.0;
        AssertRect((612 - height) / 2, 396, height, 396, front.Placements.Single(p => p.Page.Index == 3).Frame);
        AssertRect((612 - height) / 2, 0, height, 396, front.Placements.Single(p => p.Page.Index == 0).Frame);
        Assert.All(front.Placements, p => Assert.Equal(3, p.Turns));
    }

    [Fact]
    public void Plan_BookletWithMargins_SplitsAtTheCentreLineAndMeetsThePrintableArea()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(10, 20, 10, 20));
        var front = Front(Plan(Portrait(4), new LayoutOptions { Booklet = true }, area));
        // In the 792 x 612 view the printable box starts 10 in from the left; each half is 386 wide, the fold at 396.
        var left = front.Placements.Single(p => p.Page.Index == 3).Frame;
        var right = front.Placements.Single(p => p.Page.Index == 0).Frame;
        Assert.Equal(396, left.Y, 0.0001);
        Assert.Equal(386, left.Height, 0.0001);
        Assert.Equal(10, right.Y, 0.0001);
        Assert.Equal(386, right.Height, 0.0001);
    }

    [Fact]
    public void Plan_BookletPageBorders_AreKeptForTheSpread()
    {
        var plan = Plan(Portrait(4), new LayoutOptions { Booklet = true, PageBorders = true });
        Assert.True(Front(plan).Borders);
        Assert.True(Back(plan).Borders);
    }
}
