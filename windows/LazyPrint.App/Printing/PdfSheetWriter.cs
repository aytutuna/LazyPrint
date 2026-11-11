using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>
/// Lays out sides as the pages of one PDF through PDFium, the way <see cref="SheetRenderer"/> draws them as pixels: each
/// placed PDF page is a form object with its own transform and crop, so it stays vector; a picture is an image object;
/// borders, test page items and the blank-back dot are paths and text. Layout coordinates are points, top-left; the PDF's
/// are bottom-left, which the last step of every matrix flips. A page PDFium cannot take over is drawn as the picture
/// <see cref="IPageRenderer"/> makes of it. Runs on a single-threaded apartment, like the renderer's own bitmaps.
/// </summary>
public sealed class PdfSheetWriter : IDisposable
{
    private const double BorderWidth = 0.5;
    private const double MarkRadius = 0.5;
    private const double MarkInset = 8;
    // Where Helvetica's baseline lies below the top of its line box, in em.
    private const double Ascent = 0.77;
    private const double Circle = 0.5523;

    private readonly IReadOnlyList<LoadedDocument> _documents;
    private readonly IOriginalFiles _files;
    private readonly IPageRenderer _pages;
    private readonly Dictionary<int, PdfiumDocument?> _sources = [];
    private readonly Dictionary<bool, IntPtr> _fonts = [];
    // One form per page and crop, whatever the times it is placed, so what a page uses is copied into the output once.
    private readonly Dictionary<(int Document, int Index, LayoutRect? Crop), IntPtr> _forms = [];
    private readonly HashSet<(int Document, int Index)> _flattened = [];
    private readonly IntPtr _output;
    private int _count;

    public PdfSheetWriter(IReadOnlyList<LoadedDocument> documents, IOriginalFiles files, IPageRenderer pages)
    {
        (_documents, _files, _pages) = (documents, files, pages);
        lock (Pdfium.Gate) _output = Pdfium.FPDF_CreateNewDocument();
    }

    /// <summary>Adds a page the size of the paper with the side drawn on it; <paramref name="dpi"/> is the resolution of its pictures.</summary>
    public void AddSide(SheetSide side, PrintableArea area, double dpi, IReadOnlyList<TestPageItem>? items = null,
                        bool marked = false, bool turned = false)
    {
        dpi = Math.Min(dpi, SheetRenderer.MaxDpi);
        var paper = area.Paper;
        lock (Pdfium.Gate)
        {
            var page = Pdfium.FPDFPage_New(_output, _count++, paper.Width, paper.Height);
            foreach (var placement in side.Placements)
            {
                Place(page, placement, paper, dpi);
            }
            Mark(page, side, area, items, marked, turned);
            Pdfium.FPDFPage_GenerateContent(page);

            // Placements and marks alike stop at the printable area.
            var printable = area.Printable;
            if (printable.Width < paper.Width || printable.Height < paper.Height)
            {
                var clip = Pdfium.FPDF_CreateClipPath((float)printable.X, (float)(paper.Height - printable.Y - printable.Height),
                                                      (float)(printable.X + printable.Width), (float)(paper.Height - printable.Y));
                Pdfium.FPDFPage_InsertClipPath(page, clip);
                Pdfium.FPDF_DestroyClipPath(clip);
            }
            Pdfium.FPDF_ClosePage(page);
        }
    }

    /// <summary>The PDF with every side added so far.</summary>
    public byte[] Save()
    {
        var stream = new MemoryStream();
        WriteBlockHandler write = (_, data, size) =>
        {
            var block = new byte[size];
            Marshal.Copy(data, block, 0, (int)size);
            stream.Write(block);
            return 1;
        };
        var file = new Pdfium.FileWrite { Version = 1, WriteBlock = Marshal.GetFunctionPointerForDelegate(write) };
        int saved;
        lock (Pdfium.Gate) saved = Pdfium.FPDF_SaveAsCopy(_output, ref file, 0);
        GC.KeepAlive(write);
        if (saved == 0) throw new InvalidOperationException("PDFium could not write the PDF.");
        return stream.ToArray();
    }

    public void Dispose()
    {
        foreach (var source in _sources.Values) source?.Dispose();
        _sources.Clear();
        lock (Pdfium.Gate)
        {
            foreach (var form in _forms.Values) if (form != IntPtr.Zero) Pdfium.FPDF_CloseXObject(form);
            foreach (var font in _fonts.Values) Pdfium.FPDFFont_Close(font);
            Pdfium.FPDF_CloseDocument(_output);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int WriteBlockHandler(IntPtr self, IntPtr data, uint size);

    private PdfiumDocument? Source(int index)
    {
        if (_sources.TryGetValue(index, out var known)) return known;
        PdfiumDocument? source = null;
        var document = _documents[index];
        if (document.Kind is DocumentKind.Pdf && _files.OriginalFile(document) is { } bytes)
        {
            source = PdfiumDocument.Open(bytes, _files.Password(document));
        }
        _sources[index] = source;
        return source;
    }

    // MARK: Placements

    private void Place(IntPtr page, Placement placement, LayoutSize paper, double dpi)
    {
        if (placement.Page.Document < 0 || placement.Page.Document >= _documents.Count) return;
        var frame = placement.Frame;
        bool sideways = placement.Turns % 2 == 1;
        // The page as it lies before turning: the frame's shape, turned back.
        double width = sideways ? frame.Height : frame.Width, height = sideways ? frame.Width : frame.Height;
        if (width <= 0 || height <= 0) return;

        // From the box of width by height with its top-left at the origin onto the paper, in PDF space.
        var onto = new Matrix();
        onto.Translate(-width / 2, -height / 2);
        onto.Rotate(placement.Turns * 90);
        onto.Translate(frame.X + frame.Width / 2, frame.Y + frame.Height / 2);
        onto.Append(new Matrix(1, 0, 0, -1, 0, paper.Height));

        var source = Source(placement.Page.Document);
        if (source is not null && PlacePdf(page, source, placement, width, height, onto)) return;
        PlacePicture(page, placement, width, height, dpi, onto);
    }

    /// <summary>The page as a form object; false when PDFium cannot make one.</summary>
    private bool PlacePdf(IntPtr page, PdfiumDocument source, Placement placement, double width, double height, Matrix onto)
    {
        int index = placement.Page.Index;
        if (index < 0 || index >= source.PageCount) return false;

        var (box, turn) = BoxOf(source, index);
        double w = box.Width, h = box.Height;
        // The page's points onto the page as shown (y down, turned by /Rotate), to find a crop in the page's own points.
        var shownMatrix = turn switch
        {
            1 => new Matrix(0, 1, 1, 0, 0, 0),
            2 => new Matrix(-1, 0, 0, 1, w, 0),
            3 => new Matrix(0, -1, -1, 0, h, w),
            _ => new Matrix(1, 0, 0, -1, 0, h),
        };
        var toShown = new Matrix(1, 0, 0, 1, -box.Left, -box.Bottom);
        toShown.Append(shownMatrix);
        double shownWidth = turn % 2 == 1 ? h : w, shownHeight = turn % 2 == 1 ? w : h;
        var shown = placement.Crop is { } c ? new Rect(c.X, c.Y, c.Width, c.Height) : new Rect(0, 0, shownWidth, shownHeight);
        if (shown.Width <= 0 || shown.Height <= 0) return false;

        // PDFium makes a page's form with its /Rotate and the corner of its crop box taken out of the content: y up, the
        // page as shown, from its bottom-left. Its bounding box is the crop box, so a crop is a new crop box on the page
        // before it is taken over, and the form then is the cropped part alone.
        var matrix = new Matrix(1, 0, 0, -1, 0, shown.Height);
        matrix.Scale(width / shown.Width, height / shown.Height);
        matrix.Append(onto);

        var key = (placement.Page.Document, index, placement.Crop);
        if (!_forms.TryGetValue(key, out var xobject))
        {
            var sourcePage = Pdfium.FPDF_LoadPage(source.Handle, index);
            // Only a page's content and resources are taken over, so its annotations and filled form fields are drawn into it first.
            if (_flattened.Add((key.Document, index))) Pdfium.FPDFPage_Flatten(sourcePage, Pdfium.FlatPrint);
            if (placement.Crop is not null)
            {
                var back = toShown;
                back.Invert();
                var a = back.Transform(shown.TopLeft);
                var b = back.Transform(shown.BottomRight);
                Pdfium.FPDFPage_SetCropBox(sourcePage, (float)Math.Max(box.Left, Math.Min(a.X, b.X)), (float)Math.Max(box.Bottom, Math.Min(a.Y, b.Y)),
                                           (float)Math.Min(box.Right, Math.Max(a.X, b.X)), (float)Math.Min(box.Top, Math.Max(a.Y, b.Y)));
            }
            xobject = Pdfium.FPDF_NewXObjectFromPage(_output, source.Handle, index);
            if (placement.Crop is not null)
            {
                Pdfium.FPDFPage_SetCropBox(sourcePage, (float)box.Left, (float)box.Bottom, (float)box.Right, (float)box.Top);
            }
            Pdfium.FPDF_ClosePage(sourcePage);
            _forms[key] = xobject;
        }
        if (xobject == IntPtr.Zero) return false;

        var form = Pdfium.FPDF_NewFormObjectFromXObject(xobject);
        if (form == IntPtr.Zero) return false;
        Transform(form, matrix);
        Pdfium.FPDFPage_InsertObject(page, form);
        return true;
    }

    /// <summary>The crop box of the page within its media box, and its /Rotate in quarter turns.</summary>
    private static (Box Box, int Turn) BoxOf(PdfiumDocument source, int index)
    {
        var page = Pdfium.FPDF_LoadPage(source.Handle, index);
        try
        {
            var box = new Box(0, 0, 612, 792);
            if (Pdfium.FPDFPage_GetMediaBox(page, out float l, out float b, out float r, out float t) != 0) box = new Box(l, b, r, t);
            if (Pdfium.FPDFPage_GetCropBox(page, out l, out b, out r, out t) != 0)
            {
                box = new Box(Math.Max(box.Left, l), Math.Max(box.Bottom, b), Math.Min(box.Right, r), Math.Min(box.Top, t));
            }
            return (box, Pdfium.FPDFPage_GetRotation(page) & 3);
        }
        finally
        {
            Pdfium.FPDF_ClosePage(page);
        }
    }

    /// <summary>A page box in PDF space, where bottom is the smaller y.</summary>
    private readonly record struct Box(double Left, double Bottom, double Right, double Top)
    {
        public double Width => Right - Left;
        public double Height => Top - Bottom;
    }

    private void PlacePicture(IntPtr page, Placement placement, double width, double height, double dpi, Matrix onto)
    {
        var picture = _pages.Render(_documents[placement.Page.Document], placement.Page.Index, placement.Crop,
                                    Pixels(width, dpi), Pixels(height, dpi));
        bool alpha = picture.Format == PixelFormats.Bgra32 || picture.Format == PixelFormats.Pbgra32 || picture.Format.BitsPerPixel > 32;
        BitmapSource converted = new FormatConvertedBitmap(picture, alpha ? PixelFormats.Bgra32 : PixelFormats.Bgr32, null, 0);
        var bitmap = Pdfium.FPDFBitmap_Create(converted.PixelWidth, converted.PixelHeight, alpha ? 1 : 0);
        try
        {
            int stride = Pdfium.FPDFBitmap_GetStride(bitmap);
            converted.CopyPixels(Int32Rect.Empty, Pdfium.FPDFBitmap_GetBuffer(bitmap), stride * converted.PixelHeight, stride);
            var image = Pdfium.FPDFPageObj_NewImageObj(_output);
            Pdfium.FPDFImageObj_SetBitmap(IntPtr.Zero, 0, image, bitmap);
            // An image is the unit square with its top row at y = 1.
            var matrix = new Matrix(width, 0, 0, -height, 0, height);
            matrix.Append(onto);
            Transform(image, matrix);
            Pdfium.FPDFPage_InsertObject(page, image);
        }
        finally
        {
            Pdfium.FPDFBitmap_Destroy(bitmap);
        }
    }

    private static int Pixels(double points, double dpi) => Math.Max(1, (int)Math.Round(points * dpi / 72));

    private static void Transform(IntPtr pageObject, Matrix m) =>
        Pdfium.FPDFPageObj_Transform(pageObject, m.M11, m.M12, m.M21, m.M22, m.OffsetX, m.OffsetY);

    // MARK: Borders, items and the dot

    private void Mark(IntPtr page, SheetSide side, PrintableArea area, IReadOnlyList<TestPageItem>? items, bool marked, bool turned)
    {
        var paper = area.Paper;
        var printable = area.Printable;
        // A turned side (the back of the two-sided check) is drawn half a turn about the middle of the paper.
        Point Pdf(double x, double y) => turned ? new Point(paper.Width - x, y) : new Point(x, paper.Height - y);

        if (side.Borders)
        {
            foreach (var placement in side.Placements)
            {
                var f = placement.Frame;
                // Like the pixels, the borders are not turned with the rest of a turned side.
                Point Up(double x, double y) => new(x, paper.Height - y);
                Path(page, [Up(f.X, f.Y), Up(f.X + f.Width, f.Y), Up(f.X + f.Width, f.Y + f.Height), Up(f.X, f.Y + f.Height)],
                     close: true, fill: null, stroke: TestColor.Gray(128), BorderWidth);
            }
        }
        foreach (var item in items ?? [])
        {
            switch (item)
            {
                case TestPageItem.Rect rect:
                    var b = rect.Bounds;
                    Path(page, [Pdf(b.X, b.Y), Pdf(b.X + b.Width, b.Y), Pdf(b.X + b.Width, b.Y + b.Height), Pdf(b.X, b.Y + b.Height)],
                         close: true, rect.Fill, stroke: null, 0);
                    break;
                case TestPageItem.Line line:
                    Path(page, [Pdf(line.From.X, line.From.Y), Pdf(line.To.X, line.To.Y)], close: false, fill: null, line.Color, line.Width);
                    break;
                case TestPageItem.Text text:
                    Text(page, text, paper, turned);
                    break;
                case TestPageItem.Arrow arrow:
                    Path(page, [.. ArrowShape(arrow.Bounds, arrow.Up).Select(p => Pdf(p.X, p.Y))], close: true, TestColor.Black, stroke: null, 0);
                    break;
            }
        }
        if (marked) Dot(page, new Point(printable.X + MarkInset, paper.Height - printable.Y - MarkInset));
    }

    private static void Path(IntPtr page, Point[] points, bool close, TestColor? fill, TestColor? stroke, double width)
    {
        var path = Pdfium.FPDFPageObj_CreateNewPath((float)points[0].X, (float)points[0].Y);
        foreach (var p in points.Skip(1)) Pdfium.FPDFPath_LineTo(path, (float)p.X, (float)p.Y);
        if (close) Pdfium.FPDFPath_Close(path);
        Pdfium.FPDFPath_SetDrawMode(path, fill is null ? 0 : Pdfium.FillAlternate, stroke is null ? 0 : 1);
        if (fill is { } f) Pdfium.FPDFPageObj_SetFillColor(path, f.R, f.G, f.B, 255);
        if (stroke is { } s)
        {
            Pdfium.FPDFPageObj_SetStrokeColor(path, s.R, s.G, s.B, 255);
            Pdfium.FPDFPageObj_SetStrokeWidth(path, (float)width);
        }
        Pdfium.FPDFPage_InsertObject(page, path);
    }

    private void Text(IntPtr page, TestPageItem.Text text, LayoutSize paper, bool turned)
    {
        if (!_fonts.TryGetValue(text.Bold, out var font))
        {
            font = Pdfium.FPDFText_LoadStandardFont(_output, text.Bold ? "Helvetica-Bold" : "Helvetica");
            _fonts[text.Bold] = font;
        }
        var run = Pdfium.FPDFPageObj_CreateTextObj(_output, font, (float)text.Size);
        Pdfium.FPDFText_SetText(run, text.Value);
        Pdfium.FPDFPageObj_SetFillColor(run, 0, 0, 0, 255);
        // `At` is the top of the line box and a text object sits on its baseline.
        double baseline = text.At.Y + text.Size * Ascent;
        Pdfium.FPDFPageObj_Transform(run, turned ? -1 : 1, 0, 0, turned ? -1 : 1, turned ? paper.Width - text.At.X : text.At.X,
                                     turned ? baseline : paper.Height - baseline);
        Pdfium.FPDFPage_InsertObject(page, run);
    }

    private static void Dot(IntPtr page, Point c)
    {
        double r = MarkRadius, k = r * Circle;
        var path = Pdfium.FPDFPageObj_CreateNewPath((float)(c.X + r), (float)c.Y);
        Pdfium.FPDFPath_BezierTo(path, (float)(c.X + r), (float)(c.Y + k), (float)(c.X + k), (float)(c.Y + r), (float)c.X, (float)(c.Y + r));
        Pdfium.FPDFPath_BezierTo(path, (float)(c.X - k), (float)(c.Y + r), (float)(c.X - r), (float)(c.Y + k), (float)(c.X - r), (float)c.Y);
        Pdfium.FPDFPath_BezierTo(path, (float)(c.X - r), (float)(c.Y - k), (float)(c.X - k), (float)(c.Y - r), (float)c.X, (float)(c.Y - r));
        Pdfium.FPDFPath_BezierTo(path, (float)(c.X + k), (float)(c.Y - r), (float)(c.X + r), (float)(c.Y - k), (float)(c.X + r), (float)c.Y);
        Pdfium.FPDFPath_Close(path);
        Pdfium.FPDFPath_SetDrawMode(path, Pdfium.FillAlternate, 0);
        Pdfium.FPDFPageObj_SetFillColor(path, 250, 250, 250, 255);
        Pdfium.FPDFPage_InsertObject(page, path);
    }

    /// <summary>A head over a stem, filling the bounds; pointing down when it is not <paramref name="up"/>.</summary>
    private static Point[] ArrowShape(LayoutRect b, bool up)
    {
        double head = b.Height * 0.45, stem = b.Width * 0.4, centre = b.X + b.Width / 2;
        Point[] points =
        [
            new(centre, b.Y), new(b.X + b.Width, b.Y + head), new(centre + stem / 2, b.Y + head),
            new(centre + stem / 2, b.Y + b.Height), new(centre - stem / 2, b.Y + b.Height),
            new(centre - stem / 2, b.Y + head), new(b.X, b.Y + head),
        ];
        return up ? points : [.. points.Select(p => new Point(p.X, 2 * b.Y + b.Height - p.Y))];
    }
}
