using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/StatusLineTests.swift: the same cases (Lazy Scan's, for print texts).
public class StatusLineTests
{
    [Theory]
    [InlineData("Sent 3 sheets to HP LaserJet", "Sent 3 sheets")]
    [InlineData("Sent 1 sheet to Office Laser Printer Upstairs", "Sent 1 sheet")]
    [InlineData("Printing 2 of 5", "Printing 2 of 5")]
    [InlineData("Printed", "Printed")]
    [InlineData("Load the backs", "Load the backs")]
    [InlineData("Ready — HP LaserJet", "Ready — HP LaserJet")]
    [InlineData("12 sheets · 4 copies · two-sided.", "12 sheets · 4 copies · two-sided")]
    [InlineData("24 pages · 6 sheets · 3 copies · two-sided.", "24 pages · 6 sheets · 3 copies")]
    public void Short_IsShortAndFactual(string message, string expected)
    {
        Assert.Equal(expected, StatusLine.Short(message));
    }

    [Fact]
    public void Short_ReadyForATask_NamesThePrinterInstead()
    {
        Assert.Equal("Ready — HP LaserJet", StatusLine.Short(PrintText.Ready("Booklet"), "HP LaserJet"));
        Assert.Equal("Ready", StatusLine.Short(PrintText.Ready("Booklet")));
        Assert.Equal("", StatusLine.Short("   "));
    }

    [Theory]
    [InlineData("Can't reach the HP LaserJet Pro M404dn over the network.")]
    [InlineData("Out of paper. Load paper in the tray, then print again.")]
    [InlineData("A very long message without any punctuation that goes on and on about nothing in particular")]
    public void Short_NeverShowsMoreThanSixWords(string message)
    {
        string shown = StatusLine.Short(message);
        Assert.InRange(StatusLine.Words(shown), 1, StatusLine.MaxWords);
    }

    [Fact]
    public void Short_OfALongSentence_EndsWithAnEllipsis()
    {
        Assert.Equal("A very long message without any…",
                     StatusLine.Short("A very long message without any punctuation that goes on and on about nothing in particular"));
        Assert.Equal("Can't reach the HP LaserJet Pro…",
                     StatusLine.Short("Can't reach the HP LaserJet Pro M404dn over the network."));
    }

    [Fact]
    public void Short_KeepsAChangeToTheJob_AsAShortWarning()
    {
        Assert.Equal("Sent 3 sheets · 2 blank added",
                     StatusLine.Short($"{PrintText.Sent(3, "HP LaserJet")}. {PrintText.BlanksAdded(2)}"));
        Assert.Equal("Sent 3 sheets · 1 blank added",
                     StatusLine.Short($"{PrintText.Sent(3, "HP LaserJet")} {PrintText.BlanksAdded(1)}"));
        Assert.Equal("Sent 2 sheets · shrunk to 82 %",
                     StatusLine.Short($"{PrintText.Sent(2, "HP LaserJet")}. {PrintText.MadeSmaller(82)}"));
        // A task is picked: "Ready — printer" and the note.
        Assert.Equal("Ready — HP LaserJet · shrunk to 82 %",
                     StatusLine.Short($"{PrintText.Ready("Booklet")} {PrintText.MadeSmaller(82)}", "HP LaserJet"));
        // Both notes, and a message too long to keep: the warnings win.
        string both = $"{PrintText.Printing(2, 5)}. {PrintText.BlanksAdded(2)}. {PrintText.MadeSmaller(82)}";
        Assert.Equal("2 blank added · shrunk to 82 %", StatusLine.Short(both));
        string noRoom = $"Sent 12 sheets to HP LaserJet. {PrintText.BlanksAdded(2)}. {PrintText.MadeSmaller(82)}";
        Assert.Equal("2 blank added · shrunk to 82 %", StatusLine.Short(noRoom));
        foreach (var message in new[] { both, noRoom })
        {
            Assert.InRange(StatusLine.Words(StatusLine.Short(message, "HP LaserJet")), 1, StatusLine.MaxWords);
        }
    }

    [Fact]
    public void Words_CountsTokensWithALetterOrDigit()
    {
        Assert.Equal(3, StatusLine.Words("Ready — HP LaserJet"));
        Assert.Equal(5, StatusLine.Words("3 sheets sent · 1 blank"));
        Assert.Equal(0, StatusLine.Words(" — · "));
    }

    [Fact]
    public void WithWarnings_AddsTheNotesToAHead()
    {
        string message = $"{PrintText.Sent(3, "HP LaserJet")}. {PrintText.MadeSmaller(82)}";
        Assert.Equal(["Shrunk to 82 %"], StatusLine.Warnings(message));
        Assert.Equal("Printed · shrunk to 82 %", StatusLine.WithWarnings("Printed", message));
        // Without a note, just the head.
        Assert.Empty(StatusLine.Warnings(PrintText.Sent(3, "HP LaserJet")));
        Assert.Equal("Printed", StatusLine.WithWarnings("Printed", PrintText.Sent(3, "HP LaserJet")));
    }
}
