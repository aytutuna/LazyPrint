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
