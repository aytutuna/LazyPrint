namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/DocumentText.swift: why a file can't be printed.

public static class DocumentText
{
    public const string LockedPdf = "This PDF is locked. Open it in a PDF app and print it from there.";

    public const string NotSupported = "Lazy Print prints PDFs, pictures and plain text. Save it as a PDF first.";

    public const string Unreadable = "Lazy Print can't read this file.";

    public const string NeedsHeif = "To open HEIC pictures, install the HEIF Image Extensions from the Microsoft Store.";

    public const string NeedsWebP = "To open WebP pictures, install the WebP Image Extensions from the Microsoft Store.";

    public const string NoText = "This file has no text.";

    public const string NoPages = "This PDF has no pages.";
}
