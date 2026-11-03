using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintErrorTests.swift: the same cases.
public class PrintErrorTests
{
    [Fact]
    public void Unreadable_SaysItsSentence()
    {
        Assert.Equal("This PDF is locked. Open it in a PDF app and print it from there.", new PrintError.Unreadable(DocumentText.LockedPdf).Message);
        Assert.Equal("Anything", new PrintError.Unreadable("Anything").Message);
    }

    [Fact]
    public void NoPrinter_AsksForAPrinter()
    {
        Assert.Equal("No printer is set up. Add a printer, then try again.", new PrintError.NoPrinter().Message);
    }

    [Fact]
    public void Exception_CarriesTheErrorAndItsMessage()
    {
        var error = new PrintException(new PrintError.Unreadable(DocumentText.NoPages));

        Assert.Equal(new PrintError.Unreadable("This PDF has no pages."), error.Error);
        Assert.Equal("This PDF has no pages.", error.Message);
    }
}
