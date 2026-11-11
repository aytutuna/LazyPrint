using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
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
    /// <summary>The pictures the picker offers; HEIC and WebP open only where Windows has the extension for them.</summary>
    public static readonly string[] PictureExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif", ".webp"];

    /// <summary>Files that are printed as plain text.</summary>
    public static readonly string[] TextExtensions = [".txt", ".text", ".md", ".markdown", ".csv"];

    private const double PointsPerDip = 72.0 / 96;
    /// <summary>The density a picture is sized by when it states none worth believing (below 72 dpi).</summary>
    private const double AssumedDpi = 300;
    private const double LowestDpi = 72;

    private readonly ConditionalWeakTable<LoadedDocument, Source> _sources = new();
    private readonly ConditionalWeakTable<LoadedDocument, byte[]> _files = new();
    private readonly ConditionalWeakTable<LoadedDocument, string> _jpegs = new();

    private readonly ConditionalWeakTable<LoadedDocument, string> _passwords = new();
    private readonly ConditionalWeakTable<LoadedDocument, string> _texts = new();

    public async Task<LoadedDocument> LoadAsync(string path, CancellationToken token, string? password = null)
    {
        string name = Path.GetFileName(path);
        string extension = Path.GetExtension(path).ToLowerInvariant();
        bool named = extension == ".pdf" || PictureExtensions.Contains(extension) || TextExtensions.Contains(extension);

        Source source;
        LoadedDocument document;
        try
        {
            // A name that says nothing is no reason to refuse a file: its content tells a PDF from a picture.
            if (extension == ".pdf" || !named && await Task.Run(() => StartsWithPdf(path), token))
            {
                byte[] bytes = await File.ReadAllBytesAsync(path, token);
                var pdf = await PdfSource.OpenAsync(bytes, password);
                source = pdf;
                document = new LoadedDocument(name, new DocumentKind.Pdf(pdf.Protected), pdf.PageSizes);
                _files.Add(document, bytes);
                if (password is not null) _passwords.Add(document, password);
            }
            else if (TextExtensions.Contains(extension))
            {
                (source, document) = await OpenTextAsync(path, name, token);
                _texts.Add(document, ((TextSource)source).Text);
            }
            else
            {
                PictureSource picture;
                try
                {
                    picture = await Task.Run(() => PictureSource.Open(path), token);
                }
                catch (Exception e) when (LacksCodec(path, extension, e) is not null)
                {
                    throw new InvalidOperationException(LacksCodec(path, extension, e), e);
                }
                catch (Exception e) when (!named && e is not OperationCanceledException)
                {
                    // Not a picture either: a file with no name that says so may still be text.
                    if (extension.Length > 0 || !await Task.Run(() => LooksLikeText(path), token)) throw new InvalidOperationException(DocumentText.NotSupported, e);
                    var text = await OpenTextAsync(path, name, token);
                    _sources.Add(text.Document, text.Source);
                    _texts.Add(text.Document, ((TextSource)text.Source).Text);
                    return text.Document;
                }
                source = picture;
                document = new LoadedDocument(name, new DocumentKind.Photo(), picture.Sizes);
                if (extension is ".jpg" or ".jpeg" && picture.Upright) _jpegs.Add(document, path);
            }
        }
        catch (Exception e) when (e is not (InvalidOperationException or OperationCanceledException))
        {
            throw new InvalidOperationException(DocumentText.Unreadable, e);
        }
        _sources.Add(document, source);
        return document;
    }

    private static async Task<(Source Source, LoadedDocument Document)> OpenTextAsync(string path, string name, CancellationToken token)
    {
        byte[] bytes = await File.ReadAllBytesAsync(path, token);
        var size = PaperSizes.Points(PaperSizes.DefaultForRegion(RegionInfo.CurrentRegion.TwoLetterISORegionName))!.Value;
        string text = TextPages.Decode(bytes, SystemCodePage());
        var pages = TextPages.Paginate(text, size);
        if (pages.Count == 0) throw new InvalidOperationException(DocumentText.NoText);
        // The page is the usual paper where the user lives until the chosen paper is known: Relayout sets it again then.
        // Nothing of it goes to a printer as it is.
        return (new TextSource(text, pages, size), new LoadedDocument(name, new DocumentKind.Imposed(), [.. pages.Select(_ => size)]));
    }

    public LoadedDocument? Relayout(LoadedDocument document, LayoutSize paper)
    {
        if (!_texts.TryGetValue(document, out string? text) || document.Pages[0] == paper) return null;
        var pages = TextPages.Paginate(text, paper);
        var laid = new LoadedDocument(document.Name, document.Kind, [.. pages.Select(_ => paper)]);
        _sources.Add(laid, new TextSource(text, pages, paper));
        _texts.Add(laid, text);
        return laid;
    }

    private static Encoding SystemCodePage()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        return Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage);
    }

    /// <summary>No NUL byte in the first 1024: not a PDF or a picture, but it could be read as text.</summary>
    private static bool LooksLikeText(string path)
    {
        using var stream = OpenShared(path);
        var start = new byte[1024];
        int read = stream.ReadAtLeast(start, start.Length, throwOnEndOfStream: false);
        return read > 0 && start.AsSpan(0, read).IndexOf((byte)0) < 0;
    }

    /// <summary>
    /// The sentence for a HEIC, HEIF or WebP file that WIC has no decoder for (WINCODEC_ERR_COMPONENTNOTFOUND): the Store's
    /// extension is missing. Null for any other failure. Where WIC reports an unknown image format instead, the file's own
    /// bytes say whether it is one of these.
    /// </summary>
    internal static string? LacksCodec(string path, string extension, Exception e)
    {
        string? needs = extension switch
        {
            ".heic" or ".heif" => DocumentText.NeedsHeif,
            ".webp" => DocumentText.NeedsWebP,
            _ => null,
        };
        if (needs is null) return null;
        // WPF wraps the COMException in a NotSupportedException.
        for (var x = e; x is not null; x = x.InnerException)
        {
            if (x.HResult == unchecked((int)0x88982F50)) return needs;
            if (x.HResult == unchecked((int)0x88982F07) && IsFormat(path, extension)) return needs;
        }
        return null;
    }

    private static bool IsFormat(string path, string extension)
    {
        var start = new byte[16];
        int read;
        try
        {
            using var stream = OpenShared(path);
            read = stream.ReadAtLeast(start, start.Length, throwOnEndOfStream: false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        if (read < 12) return false;
        if (extension == ".webp") return start.AsSpan(0, 4).SequenceEqual("RIFF"u8) && start.AsSpan(8, 4).SequenceEqual("WEBP"u8);
        if (!start.AsSpan(4, 4).SequenceEqual("ftyp"u8)) return false;
        var brand = start.AsSpan(8, 4);
        return brand.SequenceEqual("heic"u8) || brand.SequenceEqual("heix"u8) || brand.SequenceEqual("mif1"u8)
            || brand.SequenceEqual("msf1"u8) || brand.SequenceEqual("heif"u8);
    }

    public BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
    {
        if (!_sources.TryGetValue(document, out var source)) throw new InvalidOperationException("The document was not opened by this loader.");
        return source.Render(page, crop, pixelWidth, pixelHeight);
    }

    public string? Password(LoadedDocument document) => _passwords.TryGetValue(document, out string? password) ? password : null;

    public byte[]? OriginalFile(LoadedDocument document)
    {
        if (_files.TryGetValue(document, out byte[]? bytes)) return bytes;
        if (!_jpegs.TryGetValue(document, out string? path)) return null;
        try
        {
            using var stream = OpenShared(path);
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            return copy.ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Gone or locked since it was opened: the caller draws the picture instead.
            return null;
        }
    }

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

        private PdfSource(Windows.Data.Pdf.PdfDocument document, Windows.Storage.Streams.IRandomAccessStream stream, bool encrypted,
                           IReadOnlyList<LayoutSize> pageSizes)
        {
            (_document, _stream, Protected, PageSizes) = (document, stream, encrypted, pageSizes);
        }

        public static async Task<PdfSource> OpenAsync(byte[] bytes, string? password)
        {
            var stream = System.IO.WindowsRuntimeStreamExtensions.AsRandomAccessStream(new MemoryStream(bytes));
            try
            {
                var document = password is null
                    ? await Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(stream)
                    : await Windows.Data.Pdf.PdfDocument.LoadFromStreamAsync(stream, password);
                if (document.PageCount == 0) throw new InvalidOperationException(DocumentText.NoPages);
                // IsPasswordProtected stays false for an owner password, and a printer may refuse such a file as it is.
                // The document is free-threaded, so a long file is walked off the UI thread.
                return await Task.Run(() =>
                {
                    var sizes = new List<LayoutSize>();
                    for (uint i = 0; i < document.PageCount; i++)
                    {
                        using var page = document.GetPage(i);
                        sizes.Add(new LayoutSize(page.Size.Width * PointsPerDip, page.Size.Height * PointsPerDip));
                    }
                    return new PdfSource(document, stream, bytes.AsSpan().IndexOf("/Encrypt"u8) >= 0, sizes);
                });
            }
            catch (Exception e) when (e is not InvalidOperationException)
            {
                stream.Dispose();
                // A PDF that wants a password to open says so with ERROR_WRONG_PASSWORD (0x8007052B), also for a wrong one.
                if (e.HResult == unchecked((int)0x8007052B)) throw new PdfPasswordException(password is not null, e);
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

    private sealed class TextSource(string content, IReadOnlyList<IReadOnlyList<string>> pages, LayoutSize size) : Source
    {
        public string Text { get; } = content;

        private static readonly Typeface Face = new("Courier New");

        public override BitmapSource Render(int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            var shown = crop ?? new LayoutRect(0, 0, size.Width, size.Height);
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                // Drawn in points, then scaled to the pixels asked for.
                context.PushTransform(new ScaleTransform(pixelWidth / shown.Width, pixelHeight / shown.Height));
                context.PushTransform(new TranslateTransform(-shown.X, -shown.Y));
                context.DrawRectangle(Brushes.White, null, new Rect(0, 0, size.Width, size.Height));
                for (int i = 0; i < pages[page].Count; i++)
                {
                    if (pages[page][i].Length == 0) continue;
                    var text = new FormattedText(pages[page][i], CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face,
                                                 TextPages.FontSize, Brushes.Black, 1.0);
                    context.DrawText(text, new Point(TextPages.Margin, TextPages.Margin + i * TextPages.LineHeight));
                }
                context.Pop();
                context.Pop();
            }
            var bitmap = new RenderTargetBitmap(pixelWidth, pixelHeight, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            bitmap.Freeze();
            return bitmap;
        }
    }

    private sealed class PictureSource : Source
    {
        private readonly string _path;
        private readonly Frame[] _frames;

        /// <summary>One frame of the file: its orientation tag, its pixels as stored and its size at its density, in points, upright.</summary>
        private readonly record struct Frame(int Orientation, int Width, int Height, LayoutSize Size);

        /// <summary>Each page at its density, in points, upright: a TIFF has one to a frame, any other picture its first frame only.</summary>
        public IReadOnlyList<LayoutSize> Sizes { get; }

        /// <summary>The picture needs no turning by its orientation tag, so a printer can take the file as it is.</summary>
        public bool Upright => _frames[0].Orientation <= 1;

        private PictureSource(string path, Frame[] frames)
        {
            (_path, _frames) = (path, frames);
            Sizes = [.. frames.Select(frame => frame.Size)];
        }

        public static PictureSource Open(string path)
        {
            using var stream = OpenShared(path);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.None);
            int count = decoder is TiffBitmapDecoder ? decoder.Frames.Count : 1;
            var frames = new Frame[count];
            for (int i = 0; i < count; i++)
            {
                var frame = decoder.Frames[i];
                int orientation = ReadOrientation(frame);
                // Sized by the density the file states when that is believable, else as if it were 300 dpi.
                double dpiX = frame.DpiX >= LowestDpi ? frame.DpiX : AssumedDpi, dpiY = frame.DpiY >= LowestDpi ? frame.DpiY : AssumedDpi;
                double width = frame.PixelWidth * 72 / dpiX, height = frame.PixelHeight * 72 / dpiY;
                var size = orientation >= 5 ? new LayoutSize(height, width) : new LayoutSize(width, height);
                frames[i] = new Frame(orientation, frame.PixelWidth, frame.PixelHeight, size);
            }
            return new PictureSource(path, frames);
        }

        public override BitmapSource Render(int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
        {
            var (orientation, width, height, size) = _frames[page];
            int shownWidth = orientation >= 5 ? height : width;
            BitmapSource upright;
            if (page == 0 && crop is null && pixelWidth * 2 <= shownWidth)
            {
                // At most half its size: the decoder makes the small version, not a full-size picture to shrink.
                upright = Orient(DecodeScaled(pixelWidth, orientation), orientation);
            }
            else
            {
                using var stream = OpenShared(_path);
                var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[page];
                upright = Orient(frame, orientation);
                if (crop is { } c)
                {
                    double scaleX = upright.PixelWidth / size.Width, scaleY = upright.PixelHeight / size.Height;
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
        private BitmapSource DecodeScaled(int width, int orientation)
        {
            using var stream = OpenShared(_path);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            // The decoder works on the picture as stored: for a sideways one the shown width is the stored height.
            if (orientation >= 5) image.DecodePixelHeight = Math.Max(1, width);
            else image.DecodePixelWidth = Math.Max(1, width);
            image.EndInit();
            image.Freeze();
            return image;
        }
    }

    private static bool StartsWithPdf(string path)
    {
        using var stream = OpenShared(path);
        var start = new byte[1024];
        int read = stream.ReadAtLeast(start, start.Length, throwOnEndOfStream: false);
        return start.AsSpan(0, read).IndexOf("%PDF-"u8) >= 0;
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
