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
    public void Sent_CountsTheSheets()
    {
        Assert.Equal("Sent 1 sheet to HP LaserJet", PrintText.Sent(1, "HP LaserJet"));
        Assert.Equal("Sent 3 sheets to HP LaserJet", PrintText.Sent(3, "HP LaserJet"));
    }
}
