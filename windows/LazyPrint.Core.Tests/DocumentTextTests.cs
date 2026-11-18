using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/DocumentTextTests.swift: the same cases.
public class DocumentTextTests
{
    [Fact]
    public void Sentences_AreTheseWords()
    {
        Assert.Equal("This PDF is locked. Open it in a PDF app and print it from there.", DocumentText.LockedPdf);
        Assert.Equal("Lazy Print prints PDFs, pictures and plain text. Save it as a PDF first.", DocumentText.NotSupported);
        Assert.Equal("Lazy Print can't read this file.", DocumentText.Unreadable);
        Assert.Equal("This PDF has no pages.", DocumentText.NoPages);
        Assert.Equal("This file has no text.", DocumentText.NoText);
        Assert.Equal("This PDF is locked", DocumentText.PasswordTitle);
        Assert.Equal("Enter the password for A.pdf to open it.", DocumentText.PasswordMessage("A.pdf", false));
        Assert.Equal("That password did not work. Enter the password for A.pdf.", DocumentText.PasswordMessage("A.pdf", true));
        Assert.Equal("A.pdf is locked, so it was left out.", DocumentText.LockedLeftOut("A.pdf"));
        Assert.Equal("To open WebP pictures, install the WebP Image Extensions from the Microsoft Store.", DocumentText.NeedsWebP);
    }
}
