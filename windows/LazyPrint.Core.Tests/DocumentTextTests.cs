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
        Assert.Equal("Lazy Print prints PDFs and pictures. Save it as a PDF first.", DocumentText.NotSupported);
        Assert.Equal("Lazy Print can't read this file.", DocumentText.Unreadable);
        Assert.Equal("This PDF has no pages.", DocumentText.NoPages);
    }
}
