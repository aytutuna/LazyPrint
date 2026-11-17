using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintTextTests.swift: the same cases.
public class PrintTextTests
{
    [Fact]
    public void Sentences_AreTheseWords()
    {
        Assert.Equal("Printed", PrintText.Printed);
        Assert.Equal("Load the backs", PrintText.LoadBacks);
        Assert.Equal("Lazy Print ran out of time in the background. Print again to finish.", PrintText.BackgroundExpired);
        Assert.Equal("Lazy Print ran out of time in the background. Print the backs again to finish.", PrintText.BackgroundExpiredBacks);
        Assert.Equal("Lazy Print ran out of time in the background. Print the check sheet again from the card.", PrintText.BackgroundExpiredCheck);
    }

    [Fact]
    public void PrinterMarginSides_ShortensWhenSidesAreEqual()
    {
        double Pt(double mm) => mm * 72 / 25.4;
        Assert.Equal("4.3 mm on every side", PrintText.PrinterMarginSides(new LayoutInsets(Pt(4.3), Pt(4.3), Pt(4.3), Pt(4.3))));
        Assert.Equal("Top 3 mm, bottom 12 mm, sides 3 mm", PrintText.PrinterMarginSides(new LayoutInsets(Pt(3), Pt(3), Pt(12), Pt(3))));
        Assert.Equal("Top 3, bottom 12, left 3, right 5.5 mm", PrintText.PrinterMarginSides(new LayoutInsets(Pt(3), Pt(3), Pt(12), Pt(5.5))));
    }

    [Fact]
    public void MarginLabel_NamesTheChoiceAndItsSize()
    {
        Assert.Equal("None", PrintText.MarginLabel(MarginChoice.None));
        Assert.Equal("Printer's margin", PrintText.MarginLabel(MarginChoice.Printer));
        Assert.Equal("Normal, 12 mm", PrintText.MarginLabel(MarginChoice.Normal));
        Assert.Equal("Custom", PrintText.MarginLabel(MarginChoice.Custom));
        Assert.Equal("This printer can't print the outer 4.3 mm", PrintText.PrinterEdgeNote(4.3));
        Assert.Equal("This printer can't print the outer 6 mm", PrintText.PrinterEdgeNote(6));
        Assert.Equal("Prints at 96 %", PrintText.PrintsAt(96));
    }

    [Fact]
    public void Waiting_NamesThePrinter()
    {
        Assert.Equal("Waiting for HP LaserJet", PrintText.WaitingFor("HP LaserJet"));
        Assert.Equal(["Queue paused", "Needs sign-in", "Job held"], [PrintText.QueuePaused, PrintText.NeedsSignIn, PrintText.JobHeld]);
    }

    [Fact]
    public void Sent_CountsTheSheets()
    {
        Assert.Equal("Sent 1 sheet to HP LaserJet", PrintText.Sent(1, "HP LaserJet"));
        Assert.Equal("Sent 3 sheets to HP LaserJet", PrintText.Sent(3, "HP LaserJet"));
    }

    [Fact]
    public void SheetCount_ShowsCopiesAboveOne()
    {
        Assert.Equal("2 sheets", PrintText.SheetCount(2));
        Assert.Equal("2 sheets", PrintText.SheetCount(2, 1));
        Assert.Equal("1 sheet × 3", PrintText.SheetCount(1, 3));
        Assert.Equal("2 sheets × 3", PrintText.SheetCount(2, 3));
        Assert.Equal("Sent 2 sheets × 3 to HP LaserJet", PrintText.Sent(2, "HP LaserJet", 3));
    }

    [Fact]
    public void QueuedJobLine_SaysWhoWhereAndHowManyPages()
    {
        Assert.Equal("anna · Printing · 3 pages", PrintText.QueuedJobLine(new QueuedJob(1, "a.pdf", "anna", QueuedJobState.Printing, 3, true)));
        Assert.Equal("anna · On hold · 1 page", PrintText.QueuedJobLine(new QueuedJob(1, "a.pdf", "anna", QueuedJobState.Held, 1, true)));
        Assert.Equal("Waiting", PrintText.QueuedJobLine(new QueuedJob(1, "a.pdf", "", QueuedJobState.Waiting, 0, false)));
    }

    [Fact]
    public void JobName_IsTheFirstFileAndHowManyMore()
    {
        Assert.Equal("Report.pdf", PrintText.JobName(["Report.pdf"]));
        Assert.Equal("Report.pdf and 2 more", PrintText.JobName(["Report.pdf", "a.png", "b.png"]));
    }

    [Fact]
    public void PageRangeHint_SaysTheRangeCountsAcrossDocuments()
    {
        Assert.Equal("All, or 1-3, 5", PrintText.PageRangeHint(3, 1));
        Assert.Equal("1-12 (all documents)", PrintText.PageRangeHint(12, 2));
    }

    [Fact]
    public void PresetWords_AreTheMenuAndTheQuestionBeforeADelete()
    {
        Assert.Equal("Preset", PrintText.PresetMenu);
        Assert.Equal("Save as preset…", PrintText.SavePresetItem);
        Assert.Equal("Delete “Draft”?", PrintText.DeletePresetTitle("Draft"));
    }
}
