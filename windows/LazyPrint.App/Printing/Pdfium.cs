using System.Runtime.InteropServices;

namespace LazyPrint.App.Printing;

/// <summary>
/// The few entry points of pdfium.dll (the bblanchon.PDFium.Win32 package, one build per architecture) that the app calls.
/// PDFium is not thread-safe: every call, from opening a document to closing it, holds <see cref="Gate"/>.
/// </summary>
internal static class Pdfium
{
    public static readonly object Gate = new();

    private const string Dll = "pdfium";

    static Pdfium()
    {
        FPDF_InitLibrary();
    }

    /// <summary>FPDF_FILEWRITE: a version (1) and the function PDFium hands each block of the saved file to.</summary>
    [StructLayout(LayoutKind.Sequential)]
    public struct FileWrite
    {
        public int Version;
        public IntPtr WriteBlock;
    }

    /// <summary>FPDF_FILLMODE_ALTERNATE.</summary>
    public const int FillAlternate = 1;
    /// <summary>FPDFBitmap_BGRx and FPDFBitmap_BGRA, the formats FPDFBitmap_Create makes without and with alpha.</summary>
    public const int BitmapBgrx = 2, BitmapBgra = 4;

    [DllImport(Dll)] public static extern void FPDF_InitLibrary();
    [DllImport(Dll)] public static extern IntPtr FPDF_LoadMemDocument(IntPtr data, int size, [MarshalAs(UnmanagedType.LPUTF8Str)] string? password);
    [DllImport(Dll)] public static extern void FPDF_CloseDocument(IntPtr document);
    [DllImport(Dll)] public static extern int FPDF_GetPageCount(IntPtr document);
    [DllImport(Dll)] public static extern IntPtr FPDF_LoadPage(IntPtr document, int index);
    [DllImport(Dll)] public static extern void FPDF_ClosePage(IntPtr page);
    [DllImport(Dll)] public static extern float FPDF_GetPageWidthF(IntPtr page);
    [DllImport(Dll)] public static extern float FPDF_GetPageHeightF(IntPtr page);
    [DllImport(Dll)] public static extern int FPDFPage_GetRotation(IntPtr page);
    [DllImport(Dll)] public static extern int FPDFPage_GetMediaBox(IntPtr page, out float left, out float bottom, out float right, out float top);
    [DllImport(Dll)] public static extern int FPDFPage_GetCropBox(IntPtr page, out float left, out float bottom, out float right, out float top);
    [DllImport(Dll)] public static extern void FPDFPage_SetCropBox(IntPtr page, float left, float bottom, float right, float top);

    [DllImport(Dll)] public static extern IntPtr FPDFBitmap_Create(int width, int height, int alpha);
    [DllImport(Dll)] public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);
    [DllImport(Dll)] public static extern int FPDFBitmap_GetStride(IntPtr bitmap);
    [DllImport(Dll)] public static extern int FPDFBitmap_FillRect(IntPtr bitmap, int left, int top, int width, int height, uint color);
    [DllImport(Dll)] public static extern void FPDFBitmap_Destroy(IntPtr bitmap);
    [DllImport(Dll)] public static extern void FPDF_RenderPageBitmap(IntPtr bitmap, IntPtr page, int startX, int startY, int sizeX, int sizeY, int rotate, int flags);
    [DllImport(Dll)] public static extern void FPDF_RenderPage(IntPtr dc, IntPtr page, int startX, int startY, int sizeX, int sizeY, int rotate, int flags);

    [DllImport(Dll)] public static extern IntPtr FPDF_CreateNewDocument();
    [DllImport(Dll)] public static extern IntPtr FPDFPage_New(IntPtr document, int index, double width, double height);
    [DllImport(Dll)] public static extern int FPDFPage_InsertObject(IntPtr page, IntPtr pageObject);
    [DllImport(Dll)] public static extern int FPDFPage_GenerateContent(IntPtr page);
    [DllImport(Dll)] public static extern IntPtr FPDF_CreateClipPath(float left, float bottom, float right, float top);
    [DllImport(Dll)] public static extern void FPDF_DestroyClipPath(IntPtr clipPath);
    [DllImport(Dll)] public static extern void FPDFPage_InsertClipPath(IntPtr page, IntPtr clipPath);
    [DllImport(Dll)] public static extern int FPDF_SaveAsCopy(IntPtr document, ref FileWrite file, uint flags);

    [DllImport(Dll)] public static extern IntPtr FPDF_NewXObjectFromPage(IntPtr destination, IntPtr source, int index);
    [DllImport(Dll)] public static extern void FPDF_CloseXObject(IntPtr xobject);
    [DllImport(Dll)] public static extern IntPtr FPDF_NewFormObjectFromXObject(IntPtr xobject);
    [DllImport(Dll)] public static extern void FPDFPageObj_Transform(IntPtr pageObject, double a, double b, double c, double d, double e, double f);

    [DllImport(Dll)] public static extern IntPtr FPDFPageObj_NewImageObj(IntPtr document);
    [DllImport(Dll)] public static extern int FPDFImageObj_SetBitmap(IntPtr pages, int count, IntPtr imageObject, IntPtr bitmap);

    [DllImport(Dll)] public static extern IntPtr FPDFPageObj_CreateNewRect(float x, float y, float w, float h);
    [DllImport(Dll)] public static extern IntPtr FPDFPageObj_CreateNewPath(float x, float y);
    [DllImport(Dll)] public static extern int FPDFPath_LineTo(IntPtr path, float x, float y);
    [DllImport(Dll)] public static extern int FPDFPath_BezierTo(IntPtr path, float x1, float y1, float x2, float y2, float x3, float y3);
    [DllImport(Dll)] public static extern int FPDFPath_Close(IntPtr path);
    [DllImport(Dll)] public static extern int FPDFPath_SetDrawMode(IntPtr path, int fillMode, int stroke);
    [DllImport(Dll)] public static extern int FPDFPageObj_SetFillColor(IntPtr pageObject, uint r, uint g, uint b, uint a);
    [DllImport(Dll)] public static extern int FPDFPageObj_SetStrokeColor(IntPtr pageObject, uint r, uint g, uint b, uint a);
    [DllImport(Dll)] public static extern int FPDFPageObj_SetStrokeWidth(IntPtr pageObject, float width);

    [DllImport(Dll)] public static extern IntPtr FPDFText_LoadStandardFont(IntPtr document, [MarshalAs(UnmanagedType.LPStr)] string font);
    [DllImport(Dll)] public static extern void FPDFFont_Close(IntPtr font);
    [DllImport(Dll)] public static extern IntPtr FPDFPageObj_CreateTextObj(IntPtr document, IntPtr font, float size);
    [DllImport(Dll)] public static extern int FPDFText_SetText(IntPtr textObject, [MarshalAs(UnmanagedType.LPWStr)] string text);
}

/// <summary>A PDF opened with PDFium from its bytes, which stay pinned for as long as it is open.</summary>
internal sealed class PdfiumDocument : IDisposable
{
    private GCHandle _pin;

    public IntPtr Handle { get; private set; }
    public int PageCount { get; }

    private PdfiumDocument(IntPtr handle, GCHandle pin)
    {
        (Handle, _pin) = (handle, pin);
        lock (Pdfium.Gate) PageCount = Pdfium.FPDF_GetPageCount(handle);
    }

    /// <summary>The document, or null when PDFium cannot open it (damaged, or it wants another password).</summary>
    public static PdfiumDocument? Open(byte[] bytes, string? password = null)
    {
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        IntPtr handle;
        lock (Pdfium.Gate) handle = Pdfium.FPDF_LoadMemDocument(pin.AddrOfPinnedObject(), bytes.Length, password);
        if (handle == IntPtr.Zero)
        {
            pin.Free();
            return null;
        }
        return new PdfiumDocument(handle, pin);
    }

    /// <summary>The page's size as shown, in points.</summary>
    public (double Width, double Height) PageSize(int index)
    {
        lock (Pdfium.Gate)
        {
            var page = Pdfium.FPDF_LoadPage(Handle, index);
            try
            {
                return (Pdfium.FPDF_GetPageWidthF(page), Pdfium.FPDF_GetPageHeightF(page));
            }
            finally
            {
                Pdfium.FPDF_ClosePage(page);
            }
        }
    }

    /// <summary>The page as 32-bit B, G, R, 255 pixels, <paramref name="width"/> by <paramref name="height"/>, on white.</summary>
    public byte[] Render(int index, int width, int height)
    {
        lock (Pdfium.Gate)
        {
            var page = Pdfium.FPDF_LoadPage(Handle, index);
            var bitmap = Pdfium.FPDFBitmap_Create(width, height, 0);
            try
            {
                Pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFFFFFF);
                Pdfium.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
                int stride = Pdfium.FPDFBitmap_GetStride(bitmap);
                var pixels = new byte[width * 4 * height];
                var buffer = Pdfium.FPDFBitmap_GetBuffer(bitmap);
                for (int y = 0; y < height; y++)
                {
                    Marshal.Copy(buffer + y * stride, pixels, y * width * 4, width * 4);
                }
                return pixels;
            }
            finally
            {
                Pdfium.FPDFBitmap_Destroy(bitmap);
                Pdfium.FPDF_ClosePage(page);
            }
        }
    }

    public void Dispose()
    {
        if (Handle == IntPtr.Zero) return;
        lock (Pdfium.Gate) Pdfium.FPDF_CloseDocument(Handle);
        Handle = IntPtr.Zero;
        _pin.Free();
    }
}
