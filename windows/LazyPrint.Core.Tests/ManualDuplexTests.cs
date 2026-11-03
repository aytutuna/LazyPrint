using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/ManualDuplexTests.swift: the same cases.

public class ManualDuplexTests
{
    private static readonly PaperPath Usual = new();
    private static readonly PaperPath AsItLies = new() { TurnStackOver = false };

    private static SheetPlan FivePages() =>
        Imposition.Plan(Portrait(5), new LayoutOptions { Sides = Sides.LongEdge }, Whole(Letter));

    /// <summary>The page index on a side; -1 for a blank side.</summary>
    private static int PageOf(SheetSide side) => side.Placements.Count == 0 ? -1 : side.Placements[0].Page.Index;

    [Fact]
    public void Passes_UsualPath_SendsFrontsThenBacksInSheetOrder()
    {
        var (fronts, backs) = ManualDuplex.Passes(FivePages(), Usual);
        Assert.Equal([0, 2, 4], fronts.Sides.Select(PageOf));
        Assert.Equal([1, 3, -1], backs.Sides.Select(PageOf));
        Assert.Empty(fronts.Marked);
        Assert.Empty(backs.Marked);
    }

    [Fact]
    public void Passes_StackReloadedAsItLies_SendsBacksInReverseOrder()
    {
        var (fronts, backs) = ManualDuplex.Passes(FivePages(), AsItLies);
        Assert.Equal([0, 2, 4], fronts.Sides.Select(PageOf));
        Assert.Equal([-1, 3, 1], backs.Sides.Select(PageOf));
    }

    [Fact]
    public void Passes_ReverseOrder_MarksOnlyTheBlankBacks()
    {
        var (fronts, backs) = ManualDuplex.Passes(FivePages(), AsItLies);
        Assert.Equal([0], backs.Marked);
        Assert.Empty(fronts.Marked);
    }

    [Fact]
    public void Passes_ReverseOrderWithoutBlankBacks_MarksNothing()
    {
        var plan = Imposition.Plan(Portrait(4), new LayoutOptions { Sides = Sides.LongEdge }, Whole(Letter));
        Assert.Empty(ManualDuplex.Passes(plan, AsItLies).Backs.Marked);
    }

    [Fact]
    public void Passes_InOrder_NeverMarksEvenWhenBacksAreBlank()
    {
        var (_, backs) = ManualDuplex.Passes(FivePages(), Usual);
        Assert.Empty(backs.Marked);
        Assert.Empty(backs.Sides[2].Placements);
    }

    [Fact]
    public void Passes_OneSidedPlan_GivesEveryFrontABlankBack()
    {
        var plan = Imposition.Plan(Portrait(2), new LayoutOptions(), Whole(Letter));
        var (fronts, backs) = ManualDuplex.Passes(plan, Usual);
        Assert.Equal(2, fronts.Sides.Count);
        Assert.Equal([-1, -1], backs.Sides.Select(PageOf));
    }

    [Fact]
    public void Passes_TurnBacks_TurnsEachBackAHalfTurn()
    {
        var plan = Imposition.Plan([Page(0, 300, 400), Page(1, 200, 300)], new LayoutOptions { Sides = Sides.LongEdge },
                                   new PrintableArea(Letter, new LayoutInsets(0, 0, 0, 0)));
        var plain = ManualDuplex.Passes(plan, Usual).Backs.Sides[0].Placements[0];
        var turned = ManualDuplex.Passes(plan, new PaperPath { TurnBacks = true }).Backs.Sides[0].Placements[0];
        AssertRect(612 - plain.Frame.X - plain.Frame.Width, 792 - plain.Frame.Y - plain.Frame.Height, plain.Frame.Width, plain.Frame.Height, turned.Frame);
        Assert.Equal((plain.Turns + 2) % 4, turned.Turns);
    }

    [Fact]
    public void Passes_TurnBacksOnAShortEdgePlan_TurnsTheBackBackAgain()
    {
        var plan = Imposition.Plan([Page(0, 300, 400), Page(1, 200, 300)], new LayoutOptions { Sides = Sides.ShortEdge },
                                   new PrintableArea(Letter, new LayoutInsets(0, 0, 0, 0)));
        Assert.Equal(2, plan.Sheets[0].Back!.Placements[0].Turns);
        Assert.Equal(0, ManualDuplex.Passes(plan, new PaperPath { TurnBacks = true }).Backs.Sides[0].Placements[0].Turns);
    }

    [Fact]
    public void CheckSheet_HasABigNumberAndAnArrowToTheTopEdgeOnEachSide()
    {
        var area = Margins(Letter, 18);
        var (front, back) = ManualDuplex.CheckSheet(area);
        foreach (var (side, number) in new[] { (front, "1"), (back, "2") })
        {
            var text = Assert.Single(side.OfType<TestPageItem.Text>());
            Assert.Equal(number, text.Value);
            Assert.True(text.Bold);
            Assert.True(text.Size >= 100);
            var arrow = Assert.Single(side.OfType<TestPageItem.Arrow>());
            Assert.True(arrow.Up);
            Assert.True(arrow.Bounds.Y >= 18);
            Assert.True(arrow.Bounds.Y + arrow.Bounds.Height < 792 / 2);
        }
    }

    [Fact]
    public void Learn_SameEdge_KeepsThePathAndMarksItChecked()
    {
        Assert.Equal(new PaperPath { Checked = true }, ManualDuplex.Learn(DuplexCheckAnswer.SameEdge, Usual));
        var other = new PaperPath { TurnStackOver = false, TurnBacks = true };
        Assert.Equal(other with { Checked = true }, ManualDuplex.Learn(DuplexCheckAnswer.SameEdge, other));
    }

    [Fact]
    public void Learn_OppositeEdges_TogglesTurnBacks()
    {
        var learnt = ManualDuplex.Learn(DuplexCheckAnswer.OppositeEdges, Usual);
        Assert.True(learnt.TurnBacks);
        Assert.True(learnt.TurnStackOver);
        Assert.True(learnt.Checked);
        Assert.False(ManualDuplex.Learn(DuplexCheckAnswer.OppositeEdges, learnt).TurnBacks);
    }

    [Fact]
    public void Learn_BothOnOneSide_TogglesTurnStackOverAndChecksAgain()
    {
        var learnt = ManualDuplex.Learn(DuplexCheckAnswer.BothOnOneSide, new PaperPath { Checked = true });
        Assert.False(learnt.TurnStackOver);
        Assert.False(learnt.TurnBacks);
        Assert.False(learnt.Checked);
        Assert.True(ManualDuplex.Learn(DuplexCheckAnswer.BothOnOneSide, learnt).TurnStackOver);
    }

    [Fact]
    public void PaperPath_Default_IsTheUsualPathNotYetChecked()
    {
        Assert.True(Usual.TurnStackOver);
        Assert.False(Usual.TurnBacks);
        Assert.False(Usual.Checked);
    }

    [Fact]
    public void Text_StepCard_UsesTheAgreedWords()
    {
        Assert.Equal("Printing the fronts", ManualDuplexText.FrontsTitle);
        Assert.Equal("Print the backs", ManualDuplexText.BacksTitle);
        Assert.Equal("Check with one sheet", ManualDuplexText.CheckTitle);
        Assert.Equal("Take the 7 printed sheets out. Turn the stack over and put it back in the tray, top edge first.",
                     ManualDuplexText.Reload(7, Usual));
        Assert.Equal("Take the 1 printed sheet out. Turn the stack over and put it back in the tray, top edge first.",
                     ManualDuplexText.Reload(1, Usual));
        Assert.Equal("Put the stack back in the tray as it is, top edge first.", ManualDuplexText.Reload(7, AsItLies));
        Assert.Equal("Do the arrows on both sides point to the same edge?", ManualDuplexText.CheckQuestion);
        Assert.Equal("Yes, the same edge", ManualDuplexText.Answer(DuplexCheckAnswer.SameEdge));
        Assert.Equal("No, opposite edges", ManualDuplexText.Answer(DuplexCheckAnswer.OppositeEdges));
        Assert.Equal("Both are on one side", ManualDuplexText.Answer(DuplexCheckAnswer.BothOnOneSide));
    }
}
