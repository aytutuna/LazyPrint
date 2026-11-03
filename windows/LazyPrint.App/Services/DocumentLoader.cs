using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Printing;
using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>
/// Opens the files a job starts with: PDFs with Windows.Data.Pdf, pictures with WIC. It also draws their pages
/// (<see cref="IPageRenderer"/>), for the document the loader opened, which the sheets are made of.
/// </summary>
public sealed class DocumentLoader : IDocumentLoader, IPageRenderer, IOriginalFiles
{
    public const string LockedPdf = "This PDF is locked. Open it in a PDF app and print it from there.";
    public const string NotSupported = "Lazy Print prints PDFs and pictures. Save it as a PDF first.";
    public const string Unreadable = "Lazy Print can't read this file.";

    /// <summary>The pictures the picker offers; HEIC opens only where Windows has the extension for it.</summary>
    public static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"];

    private const double PointsPerDip = 72.0 / 96;
    /// <summary>The density a picture is sized by when it states none worth believing (below 72 dpi).</summary>
    private const double AssumedDpi = 300;
    private const double LowestDpi = 72;

    private readonly ConditionalWeakTable<LoadedDocument, Source> _sources = new();
    private readonly ConditionalWeakTable<LoadedDocument, string> _files = new();

    public async Task<LoadedDocument> LoadAsync(string path, CancellationToken token)
    {
        string name = Path.GetFileName(path);
        string extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension != ".pdf" && !PictureExtensions.Contains(extension)) throw new InvalidOperationException(NotSupported);

        Source source;
        LoadedDocument document;
        try
        {
            if (extension == ".pdf")
            {
                byte[] bytes = await Task.Run(() => File.ReadAllBytes(path), token);
                var pdf = await PdfSource.OpenAsync(bytes);
                source = pdf;
                document = new LoadedDocument(name, new DocumentKind.Pdf(pdf.Protected), pdf.PageSizes);
                _files.Add(document, path);
            }
            else
            {
                var picture = await Task.Run(() => PictureSource.Open(path), token);
                source = picture;
                document = new LoadedDocument(name, new DocumentKind.Photo(), [picture.Size]);
                if (extension is ".jpg" or ".jpeg" && picture.Upright) _files.Add(document, path);
            }
        }
        catch (Exception e) when (e is not (InvalidOperationException or OperationCanceledException))
        {
            throw new InvalidOperationException(Unreadable, e);
        }
        _sources.Add(document, source);
        return document;
    }

    public BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
    {
        if (!_sources.TryGetValue(document, out var source)) throw new InvalidOperationException("The document was not opened by this loader.");
        return source.Render(page, crop, pixelWidth, pixelHeight);
    }

    public string? OriginalFile(LoadedDocument document) => _files.TryGetValue(document, out string? path) ? path : null;

    private abstract class Source
    {
        public abstract BitmapSource Render(int page, LayoutRect? crop, int pixelWidth, int pixelHeight);
    }

    private sealed class PdfSource : Source
    {
        private readonly Windows.Data.Pdf.PdfDocument _document;
        // The document keeps reading from the stream, so the stream stays with it (and the file is not held open).
        private readonly Windows.Storage.Streams.IRandomAccessStream _stream;

        private readonly object _gate = new();

        public bool Protected { get; }
        public IReadOnlyList<LayoutSize> PageSizes { get; }

        private PdfSource(Windows.Data.Pdf.PdfDocument document, Windows.Storage.Streams.IRandomAccessStream stream)
        {
            _document = document;
            _stream = stream;
            Protected = document.IsPasswordProtected;
            var sizes = new List<LayoutSize>();
            for (uint i = 0; i < document.PageCount; i++)
            {
                using var page = document.GetPage(i);
                sizes.Add(new LayoutSize(page.Size.Width * PointsPerDip, page.Size.Height * PointsPerDip));
            }
            PageSizes = sizes;
        }

        public static async Task<PdfSource> OpenAsync(byte[] bytes)
        {
            var stream = System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(new MemoryStream(bytes));
            try
            {
                var document = await Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(stream);
                if (document.PageCount == 0) throw new InvalidOperationException("This PDF has no pages.");
                return new PdfSource(document, stream);
            }
            catch (Exception e) when (e is not InvalidOperationException)
            {
                stream.Dispose();
                // A PDF that wants a password to open says so with ERROR_WRONG_PASSWORD (0x8007052B).
                if (e.HResult == unchecked((int)0x8007052B)) throw new InvalidOperationException(LockedPdf, e);
                throw;
            }
        }

        public override BitmapSource Render(int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            lock (_gate)
            {
                using var pdfPage = _document.GetPage((uint)page);
                double scale = DisplayScale(pdfPage);
                var options = new Windows.Data.Pdf.PdfPageRenderOptions
                {
                    DestinationWidth = (uint)Math.Max(1, Math.Round(pixelWidth / scale)),
                    DestinationHeight = (uint)Math.Max(1, Math.Round(pixelHeight / scale)),
                    BackgroundColor = Windows.UI.Color.FromArgb(255, 255, 255, 255),
                };
                if (crop is { } c)
                {
                    options.SourceRect = new Windows.Foundation.Rect(c.X / PointsPerDip, c.Y / PointsPerDip, c.Width / PointsPerDip, c.Height / PointsPerDip);
                }
                return Decode(pdfPage, options);
            }
        }

        /// <summary>What the renderer multiplies the size asked for by (the display's scale), found once with a small page.</summary>
        private static double DisplayScale(Windows.Data.Pdf.PdfPage page)
        {
            if (_displayScale is { } known) return known;
            var probe = Decode(page, new Windows.Data.Pdf.PdfPageRenderOptions { DestinationWidth = 100 });
            _displayScale = probe.PixelWidth / 100.0;
            return _displayScale.Value;
        }

        private static double? _displayScale;

        private static BitmapSource Decode(Windows.Data.Pdf.PdfPage page, Windows.Data.Pdf.PdfPageRenderOptions options)
        {
            using var rendered = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            page.RenderToStreamAsync(rendered, options).AsTask().GetAwaiter().GetResult();
            rendered.Seek(0);
            var copy = new MemoryStream();
            System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(rendered).CopyTo(copy);
            copy.Position = 0;
            var frame = BitmapDecoder.Create(copy, BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad).Frames[0];
            frame.Freeze();
            return frame;
        }
    }

    private sealed class PictureSource : Source
    {
        private readonly string _path;
        private readonly int _orientation;
        private readonly int _width, _height;

        /// <summary>At its density, in points, upright.</summary>
        public LayoutSize Size { get; }

        /// <summary>The picture needs no turning by its orientation tag, so a printer can take the file as it is.</summary>
        public bool Upright => _orientation <= 1;

        private PictureSource(string path, int orientation, int width, int height, LayoutSize size)
        {
            (_path, _orientation, _width, _height, Size) = (path, orientation, width, height, size);
        }

        public static PictureSource Open(string path)
        {
            using var stream = OpenShared(path);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.None).Frames[0];
            int orientation = ReadOrientation(frame);
            bool sideways = orientation >= 5;
            // Sized by the density the file states when that is believable, else as if it were 300 dpi.
            double dpiX = frame.DpiX >= LowestDpi ? frame.DpiX : AssumedDpi, dpiY = frame.DpiY >= LowestDpi ? frame.DpiY : AssumedDpi;
            double width = frame.PixelWidth * 72 / dpiX, height = frame.PixelHeight * 72 / dpiY;
            var size = sideways ? new LayoutSize(height, width) : new LayoutSize(width, height);
            return new PictureSource(path, orientation, frame.PixelWidth, frame.PixelHeight, size);
        }

        public override BitmapSource Render(int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            int shownWidth = _orientation >= 5 ? _height : _width;
            BitmapSource upright;
            if (crop is null && pixelWidth * 2 <= shownWidth)
            {
                // At most half its size: the decoder makes the small version, not a full-size picture to shrink.
                upright = Orient(DecodeScaled(pixelWidth), _orientation);
            }
            else
            {
                using var stream = OpenShared(_path);
                var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
                upright = Orient(frame, _orientation);
                if (crop is { } c)
                {
                    double scaleX = upright.PixelWidth / Size.Width, scaleY = upright.PixelHeight / Size.Height;
                    var area = new Int32Rect(
                        Math.Clamp((int)Math.Round(c.X * scaleX), 0, upright.PixelWidth - 1),
                        Math.Clamp((int)Math.Round(c.Y * scaleY), 0, upright.PixelHeight - 1), 1, 1);
                    area.Width = Math.Clamp((int)Math.Round(c.Width * scaleX), 1, upright.PixelWidth - area.X);
                    area.Height = Math.Clamp((int)Math.Round(c.Height * scaleY), 1, upright.PixelHeight - area.Y);
                    var cropped = new CroppedBitmap(upright, area);
                    cropped.Freeze();
                    upright = cropped;
                }
                if (pixelWidth < upright.PixelWidth)
                {
                    var scaled = new TransformedBitmap(upright, new ScaleTransform((double)pixelWidth / upright.PixelWidth, (double)pixelHeight / upright.PixelHeight));
                    scaled.Freeze();
                    upright = scaled;
                }
            }
            if (!upright.IsFrozen && upright.CanFreeze) upright.Freeze();
            return upright;
        }

        /// <summary>The picture decoded at <paramref name="width"/> pixels across, as shown (upright).</summary>
        private BitmapSource DecodeScaled(int width)
        {
            using var stream = OpenShared(_path);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            // The decoder works on the picture as stored: for a sideways one the shown width is the stored height.
            if (_orientation >= 5) image.DecodePixelHeight = Math.Max(1, width);
            else image.DecodePixelWidth = Math.Max(1, width);
            image.EndInit();
            image.Freeze();
            return image;
        }
    }

    private static FileStream OpenShared(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);

    /// <summary>EXIF orientation (1 to 8) of a JPEG or TIFF frame; 1 when it has none.</summary>
    private static int ReadOrientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is not BitmapMetadata metadata) return 1;
            foreach (string query in new[] { "/app1/ifd/{ushort=274}", "/ifd/{ushort=274}" })
            {
                if (metadata.ContainsQuery(query) && metadata.GetQuery(query) is ushort value && value is >= 1 and <= 8) return value;
            }
        }
        catch
        {
            // Formats without an EXIF block (PNG, some TIFF writers) throw on queries.
        }
        return 1;
    }

    /// <summary>The source turned upright (EXIF semantics: flip first, then turn clockwise).</summary>
    private static BitmapSource Orient(BitmapSource source, int orientation)
    {
        (bool flip, int rotate) = orientation switch
        {
            2 => (true, 0),
            3 => (false, 180),
            4 => (true, 180),
            5 => (true, 270),
            6 => (false, 90),
            7 => (true, 90),
            8 => (false, 270),
            _ => (false, 0),
        };
        if (!flip && rotate == 0) return source;
        var group = new TransformGroup();
        if (flip) group.Children.Add(new ScaleTransform(-1, 1));
        if (rotate != 0) group.Children.Add(new RotateTransform(rotate));
        var transformed = new TransformedBitmap(source, group);
        transformed.Freeze();
        return transformed;
    }
}
