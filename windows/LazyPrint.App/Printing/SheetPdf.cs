using System.Diagnostics;
using System.Runtime.CompilerServices;
using LazyPrint.App.Services;

namespace LazyPrint.App.Printing;

internal static class SheetPdf
{
    /// <summary>The sides as one PDF, a page each at the paper's size. Pictures go in at 300 dpi.</summary>
    public static byte[] Make(SheetJob job, IReadOnlyList<DrawnSide> sides, IOriginalFiles files, IPageRenderer pages)
    {
        using var writer = new PdfSheetWriter(job.Documents, files, pages);
        foreach (var side in sides)
        {
            writer.AddSide(side.Side, job.Plan.Plan.Area, 300, side.Items, side.Marked, side.Turned);
        }
        return writer.Save();
    }

    /// <summary>Whether pdfium.dll loads; says so in the log when it does not.</summary>
    public static bool Available
    {
        get
        {
            try
            {
                RuntimeHelpers.RunClassConstructor(typeof(Pdfium).TypeHandle);
                return true;
            }
            catch (Exception e) when (Unavailable(e))
            {
                LogFallback(e);
                return false;
            }
        }
    }

    /// <summary>Whether <paramref name="e"/> says pdfium.dll could not be loaded (missing, or built for another architecture).</summary>
    public static bool Unavailable(Exception e) =>
        e is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException
        || e is TypeInitializationException { InnerException: { } inner } && Unavailable(inner);

    public static void LogFallback(Exception e) =>
        Trace.TraceWarning($"PDFium could not be loaded, so the sheets are printed as pictures: {e.Message}");
}
