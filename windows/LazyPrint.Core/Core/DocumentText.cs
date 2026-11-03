namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/DocumentText.swift: why a file can't be printed.

public static class DocumentText
{
    public const string LockedPdf = "This PDF is locked. Open it in a PDF app and print it from there.";

    public const string NotSupported = "Lazy Print prints PDFs and pictures. Save it as a PDF first.";

    public const string Unreadable = "Lazy Print can't read this file.";

    public const string NoPages = "This PDF has no pages.";
}
