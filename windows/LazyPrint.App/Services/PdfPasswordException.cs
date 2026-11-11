using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>A PDF that needs a password to open: none was given, or <paramref name="Wrong"/> one was.</summary>
public sealed class PdfPasswordException(bool wrong, Exception inner) : InvalidOperationException(DocumentText.LockedPdf, inner)
{
    public bool Wrong { get; } = wrong;
}
