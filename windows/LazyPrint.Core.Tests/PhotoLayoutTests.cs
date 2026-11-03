using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PhotoLayoutTests.swift: the same cases.

public class PhotoLayoutTests
{
    private const double Gap = 3 * 72 / 25.4;

    private static PhotoSize Size(string id) => PhotoSize.All.Single(s => s.Id == id);

    private static List<SourcePage> Photos(int count, double width = 288, double height = 432) =>
        [.. Enumerable.Range(0, count).Select(i => Page(i, width, height))];

    private static SheetPlan Plan(IReadOnlyList<SourcePage> photos, PhotoOptions options, PrintableArea area) =>
        PhotoLayout.Plan(photos, options, area);

    [Fact]
    public void All_ListsTheSizesWithTheirIds()
    {
        Assert.Equal(["4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm", "page"], PhotoSize.All.Select(s => s.Id));
        Assert.Equal("4 × 6 in", Size("4x6").Title);
        Assert.Equal("10 × 15 cm", Size("10x15cm").Title);
        Assert.Equal("Whole page", Size("page").Title);
        Assert.Equal(new LayoutSize(288, 432), Size("4x6").Size);
        Assert.Null(Size("page").Size);
        Assert.Equal(100 * 72 / 25.4, Size("10x15cm").Size!.Value.Width, 0.0001);
    }

    [Theory]
    [InlineData("4x6", false, 0, 2)]
    [InlineData("4x6", true, 0, 2)]
    [InlineData("4x6", false, 18, 2)]
    [InlineData("4x6", true, 18, 2)]
    [InlineData("5x7", false, 18, 2)]
    [InlineData("8x10", false, 18, 1)]
    [InlineData("3.5x5", false, 0, 4)]
    [InlineData("wallet", false, 0, 9)]
    [InlineData("wallet", false, 18, 8)]
    [InlineData("10x15cm", true, 0, 2)]
    [InlineData("13x18cm", true, 0, 2)]
    [InlineData("page", false, 0, 1)]
    public void Plan_PerSheet_IsAsManyAsFit(string id, bool a4, int margin, int expected)
    {
        var paper = a4 ? A4 : Letter;
        var plan = Plan(Photos(30), new PhotoOptions(Size(id)), Margins(paper, margin));
        Assert.Equal(expected, plan.Sheets[0].Front.Placements.Count);
        Assert.Equal(30, plan.Sheets.Sum(s => s.Front.Placements.Count));
        Assert.Equal((30 + expected - 1) / expected, plan.Sheets.Count);
    }

    [Fact]
    public void Plan_FourBySixOnLetter_SitsSideBySideThreeMillimetresApart()
    {
        var plan = Plan(Photos(2), new PhotoOptions(Size("4x6")), Whole(Letter));
        var placements = plan.Sheets[0].Front.Placements;
        double left = (612 - (576 + Gap)) / 2;
        AssertRect(left, (792 - 432) / 2.0, 288, 432, placements[0].Frame);
        AssertRect(left + 288 + Gap, (792 - 432) / 2.0, 288, 432, placements[1].Frame);
        Assert.Equal(3, (placements[1].Frame.X - placements[0].Frame.X - 288) / 72 * 25.4, 0.0001);
    }

    [Fact]
    public void Plan_FourBySixWithMargins_TurnsTheCellsWhenMoreFit()
    {
        var plan = Plan(Photos(2), new PhotoOptions(Size("4x6")), Margins(Letter, 18));
        var placements = plan.Sheets[0].Front.Placements;
        AssertRect((612 - 432) / 2.0, (792 - (576 + Gap)) / 2, 432, 288, placements[0].Frame);
        AssertRect((612 - 432) / 2.0, (792 - (576 + Gap)) / 2 + 288 + Gap, 432, 288, placements[1].Frame);
        // A portrait photo in a landscape cell is turned a quarter counterclockwise.
        Assert.All(placements, p => Assert.Equal(3, p.Turns));
    }

    [Fact]
    public void Plan_PhotoMatchingItsCell_IsNotTurned()
    {
        var plan = Plan(Photos(2), new PhotoOptions(Size("4x6")), Whole(Letter));
        Assert.All(plan.Sheets[0].Front.Placements, p => Assert.Equal(0, p.Turns));
    }

    [Fact]
    public void Plan_LandscapePhotoInATurnedCell_IsNotTurned()
    {
        var plan = Plan(Photos(2, 432, 288), new PhotoOptions(Size("4x6")), Margins(Letter, 18));
        Assert.All(plan.Sheets[0].Front.Placements, p => Assert.Equal(0, p.Turns));
    }

    [Fact]
    public void Plan_FillWithAnotherAspect_CropsInTheMiddle()
    {
        // A 4:3 landscape photo turned into a 4 x 6 portrait cell: scale max(288 / 600, 432 / 800) = 0.54.
        var plan = Plan(Photos(1, 800, 600), new PhotoOptions(Size("4x6")), Whole(Letter));
        var placement = Assert.Single(plan.Sheets[0].Front.Placements);
        Assert.Equal(3, placement.Turns);
        double shown = 288 / 0.54;
        AssertRect(0, (600 - shown) / 2, 800, shown, placement.Crop!.Value);
        AssertRect((612 - (576 + Gap)) / 2, (792 - 432) / 2.0, 288, 432, placement.Frame);
    }

    [Fact]
    public void Plan_FillWithTheSameAspect_NeedsNoCrop()
    {
        var plan = Plan(Photos(1, 2400, 3600), new PhotoOptions(Size("4x6")), Whole(Letter));
        Assert.Null(Assert.Single(plan.Sheets[0].Front.Placements).Crop);
    }

    [Fact]
    public void Plan_NoFill_FitsTheWholePhotoWithBands()
    {
        var plan = Plan(Photos(1, 800, 600), new PhotoOptions(Size("4x6"), Fill: false), Whole(Letter));
        var placement = Assert.Single(plan.Sheets[0].Front.Placements);
        Assert.Null(placement.Crop);
        Assert.Equal(3, placement.Turns);
        // The turned photo is 600 x 800: 288 / 600 decides, 288 x 384 centred in the 288 x 432 cell.
        AssertRect((612 - (576 + Gap)) / 2, (792 - 432) / 2.0 + 24, 288, 384, placement.Frame);
    }

    [Fact]
    public void Plan_CopiesEach_RepeatsEachPhotoBeforeTheNext()
    {
        var plan = Plan(Photos(2), new PhotoOptions(Size("4x6"), CopiesEach: 2), Whole(Letter));
        Assert.Equal(2, plan.Sheets.Count);
        Assert.Equal([0, 0], plan.Sheets[0].Front.Placements.Select(p => p.Page.Index));
        Assert.Equal([1, 1], plan.Sheets[1].Front.Placements.Select(p => p.Page.Index));
    }

    [Fact]
    public void Plan_WholePage_FillsThePrintableArea()
    {
        var area = new PrintableArea(Letter, new LayoutInsets(10, 20, 30, 40));
        var plan = Plan(Photos(2, 552, 752), new PhotoOptions(Size("page")), area);
        Assert.Equal(2, plan.Sheets.Count);
        AssertRect(20, 10, 552, 752, plan.Sheets[0].Front.Placements[0].Frame);
    }

    [Fact]
    public void Plan_Photos_AreOneSidedWithoutWarnings()
    {
        var plan = Plan(Photos(3), new PhotoOptions(Size("4x6")), Whole(Letter));
        Assert.False(plan.Duplex);
        Assert.Equal(Whole(Letter), plan.Area);
        Assert.Empty(plan.Warnings);
        Assert.All(plan.Sheets, s => Assert.Null(s.Back));
        Assert.All(plan.Sheets, s => Assert.False(s.Front.Borders));
    }

    [Fact]
    public void Plan_SizeLargerThanThePrintableArea_IsOnePerSheetMadeSmaller()
    {
        var plan = Plan(Photos(1, 576, 720), new PhotoOptions(Size("8x10"), Fill: false), Whole(new LayoutSize(288, 432)));
        AssertRect(0, 36, 288, 360, Assert.Single(plan.Sheets[0].Front.Placements).Frame);
    }

    [Fact]
    public void Plan_SizeLargerThanThePrintableArea_KeepsTheShapeWhenFilling()
    {
        var plan = Plan(Photos(1, 576, 720), new PhotoOptions(Size("8x10")), Whole(new LayoutSize(288, 432)));
        var placement = Assert.Single(plan.Sheets[0].Front.Placements);
        AssertRect(0, 36, 288, 360, placement.Frame);
        Assert.Null(placement.Crop);
    }

    [Fact]
    public void Plan_NoPhotos_HasNoSheets()
    {
        Assert.Empty(Plan([], new PhotoOptions(Size("4x6")), Whole(Letter)).Sheets);
    }

    [Fact]
    public void CutMarks_SeveralPrints_MarksEachCornerWithTwoGrayLines()
    {
        var options = new PhotoOptions(Size("4x6"));
        var plan = Plan(Photos(2), options, Whole(Letter));
        var marks = PhotoLayout.CutMarks(plan.Sheets[0].Front, options, plan.Area);
        Assert.Equal(16, marks.Count);
        Assert.All(marks, mark =>
        {
            var line = Assert.IsType<TestPageItem.Line>(mark);
            Assert.Equal(TestColor.Gray(128), line.Color);
            Assert.True(Math.Abs(line.To.X - line.From.X) + Math.Abs(line.To.Y - line.From.Y) <= 4.0001);
        });
    }

    [Fact]
    public void CutMarks_OnePrint_HasNone()
    {
        var options = new PhotoOptions(Size("8x10"));
        var plan = Plan(Photos(1), options, Margins(Letter, 18));
        Assert.Empty(PhotoLayout.CutMarks(plan.Sheets[0].Front, options, plan.Area));
    }

    [Fact]
    public void CutMarks_FollowThePrintCellsNotThePhoto()
    {
        var options = new PhotoOptions(Size("4x6"), Fill: false);
        var plan = Plan(Photos(2, 800, 600), options, Whole(Letter));
        var marks = PhotoLayout.CutMarks(plan.Sheets[0].Front, options, plan.Area);
        double left = (612 - (576 + Gap)) / 2;
        var corner = marks.OfType<TestPageItem.Line>().Where(m => m.From.X == left && m.From.Y == (792 - 432) / 2.0);
        Assert.Equal(2, corner.Count());
    }

    [Fact]
    public void CutMarks_PartlyFilledLastSheet_StillHasThem()
    {
        var options = new PhotoOptions(Size("4x6"));
        var plan = Plan(Photos(3), options, Whole(Letter));
        var marks = PhotoLayout.CutMarks(plan.Sheets[1].Front, options, plan.Area);
        Assert.Equal(8, marks.Count);
    }

    [Fact]
    public void FrameMarks_APhotoSheet_MarksTheCornersOfEachFrame()
    {
        var plan = Imposition.Plan(Photos(4), new LayoutOptions { PagesPerSheet = 4, Scaling = Scaling.Fill }, Whole(Letter));
        var side = plan.Sheets[0].Front;
        var lines = PhotoLayout.FrameMarks(side).OfType<TestPageItem.Line>().ToList();
        Assert.Equal(32, lines.Count);
        foreach (var placement in side.Placements)
        {
            var frame = placement.Frame;
            Assert.True(lines.Count(l => l.From.X == frame.X && l.From.Y == frame.Y) >= 2);
        }
    }

    [Fact]
    public void FrameMarks_OnePhoto_HasNone()
    {
        var plan = Imposition.Plan(Photos(1), new LayoutOptions { PagesPerSheet = 4, Scaling = Scaling.Fill }, Whole(Letter));
        Assert.Empty(PhotoLayout.FrameMarks(plan.Sheets[0].Front));
    }
}
