using System.ComponentModel;
using System.Runtime.InteropServices;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>
/// Prints a sheet PDF to a queue through GDI: a device context made with the job's DEVMODE, so copies, collation, two-sided
/// and color are the driver's, and each page drawn by PDFium onto it as vector. The spooler's job is made by StartDoc.
/// </summary>
internal static class VectorSpool
{
    private const int PhysicalWidth = 110, PhysicalHeight = 111, PhysicalOffsetX = 112, PhysicalOffsetY = 113;
    // FPDF_ANNOT and FPDF_PRINTING.
    private const int RenderFlags = 0x01 | 0x800;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DocInfo
    {
        public int Size;
        public string Name;
        public string? Output;
        public string? DataType;
        public int Type;
    }

    [DllImport("gdi32", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDCW(string driver, string device, string? output, IntPtr devMode);
    [DllImport("gdi32", SetLastError = true)] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32", CharSet = CharSet.Unicode, SetLastError = true)] private static extern int StartDocW(IntPtr dc, ref DocInfo info);
    [DllImport("gdi32", SetLastError = true)] private static extern int EndDoc(IntPtr dc);
    [DllImport("gdi32", SetLastError = true)] private static extern int AbortDoc(IntPtr dc);
    [DllImport("gdi32", SetLastError = true)] private static extern int StartPage(IntPtr dc);
    [DllImport("gdi32", SetLastError = true)] private static extern int EndPage(IntPtr dc);
    [DllImport("gdi32")] private static extern int GetDeviceCaps(IntPtr dc, int index);

    /// <summary>
    /// Where the paper lies on the device context, whose origin is the corner of the printable area: the paper's size in
    /// device pixels, shifted back by the printer's unprintable margins.
    /// </summary>
    internal static (int X, int Y, int Width, int Height) PaperRect(int physicalWidth, int physicalHeight, int offsetX, int offsetY) =>
        (-offsetX, -offsetY, physicalWidth, physicalHeight);

    /// <summary>
    /// Sends every page of <paramref name="pdf"/> to the printer as a job of its own and returns the spooler's id for it.
    /// <paramref name="sent"/> hears of the pages done. Cancelling aborts the job.
    /// </summary>
    public static int Print(string printer, byte[] devMode, byte[] pdf, string name, Action<int> sent, CancellationToken token)
    {
        using var document = PdfiumDocument.Open(pdf) ?? throw new InvalidOperationException("PDFium could not open the sheets.");
        var pin = GCHandle.Alloc(devMode, GCHandleType.Pinned);
        IntPtr dc;
        try
        {
            dc = CreateDCW("WINSPOOL", printer, null, pin.AddrOfPinnedObject());
        }
        finally
        {
            pin.Free();
        }
        if (dc == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var info = new DocInfo { Size = Marshal.SizeOf<DocInfo>(), Name = name };
            int id = StartDocW(dc, ref info);
            if (id <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var rect = PaperRect(GetDeviceCaps(dc, PhysicalWidth), GetDeviceCaps(dc, PhysicalHeight),
                                     GetDeviceCaps(dc, PhysicalOffsetX), GetDeviceCaps(dc, PhysicalOffsetY));
                for (int i = 0; i < document.PageCount; i++)
                {
                    token.ThrowIfCancellationRequested();
                    if (StartPage(dc) <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                    lock (Pdfium.Gate)
                    {
                        var page = Pdfium.FPDF_LoadPage(document.Handle, i);
                        try { Pdfium.FPDF_RenderPage(dc, page, rect.X, rect.Y, rect.Width, rect.Height, 0, RenderFlags); }
                        finally { Pdfium.FPDF_ClosePage(page); }
                    }
                    if (EndPage(dc) <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                    sent(i + 1);
                }
            }
            catch
            {
                AbortDoc(dc);
                throw;
            }
            if (EndDoc(dc) <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            return id;
        }
        finally
        {
            DeleteDC(dc);
        }
    }
}
