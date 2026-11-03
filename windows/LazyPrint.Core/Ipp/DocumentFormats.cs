namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/DocumentFormats.swift: which document format a job goes in.

/// <summary>What is being printed, as far as the format is concerned.</summary>
public abstract record DocumentKind
{
    private DocumentKind() { }

    /// <summary>A PDF printed as it is.</summary>
    public sealed record Pdf(bool Encrypted) : DocumentKind;
    /// <summary>One photo printed whole on paper of its own size.</summary>
    public sealed record Photo : DocumentKind;
    /// <summary>Sheets drawn by Lazy Print.</summary>
    public sealed record Imposed : DocumentKind;
}

public static class DocumentFormats
{
    public const string Pdf = "application/pdf";
    public const string PwgRaster = "image/pwg-raster";
    public const string Urf = "image/urf";
    public const string Jpeg = "image/jpeg";

    /// <summary>
    /// The format a job goes in. A PDF goes as itself only when it is printed as it is (one page per side, every page once
    /// in order, fit or shrink to fit, no booklet, no manual duplex), and not encrypted. One photo goes as JPEG only when it
    /// is printed whole on paper of its own size. Everything else is sheets drawn by Lazy Print: PDF where the platform can
    /// write one (<paramref name="canWritePdf"/>), else PWG raster, then URF. Null when the printer takes none of them.
    /// </summary>
    public static string? Choose(IReadOnlyList<string> supported, DocumentKind kind, bool canWritePdf)
    {
        bool Takes(string format) => supported.Contains(format, StringComparer.OrdinalIgnoreCase);

        if (kind is DocumentKind.Pdf { Encrypted: false } && Takes(Pdf)) return Pdf;
        if (kind is DocumentKind.Photo && Takes(Jpeg)) return Jpeg;
        if (canWritePdf && Takes(Pdf)) return Pdf;
        if (Takes(PwgRaster)) return PwgRaster;
        if (Takes(Urf)) return Urf;
        return null;
    }

    /// <summary>
    /// A job refused with document-format-not-supported, document-format-error or document-unprintable-error is sent once
    /// more as raster.
    /// </summary>
    public static bool RetriesAsRaster(ushort status) =>
        status is (ushort)IppStatus.ClientErrorDocumentFormatNotSupported
            or (ushort)IppStatus.ClientErrorDocumentFormatError
            or (ushort)IppStatus.ClientErrorDocumentUnprintableError;
}
