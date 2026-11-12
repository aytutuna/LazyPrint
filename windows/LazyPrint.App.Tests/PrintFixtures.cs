using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Tests;

/// <summary>Plain pages, a different color for each page of a document, and a note of what was asked for.</summary>
internal sealed class SolidPages : IPageRenderer
{
    public List<(int Page, int Width, int Height)> Asked { get; } = [];

    public BitmapSource Render(LoadedDocument document, int page, LayoutRect? crop, int pixelWidth, int pixelHeight)
    {
        lock (Asked) Asked.Add((page, pixelWidth, pixelHeight));
        byte shade = (byte)(40 + page * 50 % 200);
        var bitmap = BitmapSource.Create(4, 4, 96, 96, PixelFormats.Bgra32, null,
                                         Enumerable.Range(0, 16).SelectMany(_ => new byte[] { shade, 90, 200, 255 }).ToArray(), 16);
        bitmap.Freeze();
        return bitmap;
    }
}

/// <summary>Takes a report where it is made (<see cref="Progress{T}"/> would hand it to another thread).</summary>
internal sealed class Reports<T> : IProgress<T>
{
    public List<T> All { get; } = [];

    public void Report(T value)
    {
        lock (All) All.Add(value);
    }
}

internal static class PrintFixtures
{
    public static PrinterInfo Printer(PrinterRoute route = PrinterRoute.System, string name = "Test Printer") =>
        new(route == PrinterRoute.Demo ? PrinterMerge.DemoId : route == PrinterRoute.Ipp ? "ipp:test" : "system:" + name, name, null, null,
            route, null, false, PrinterState.Idle, [], []);

    public static PrintSettings Letter(Action<PrintSettings>? edit = null)
    {
        var settings = new PrintSettings { PaperId = "letter" };
        edit?.Invoke(settings);
        return settings;
    }

    /// <summary>A job of one document of letter pages, planned as the view model plans it.</summary>
    public static SheetJob Job(PrintSettings settings, int pages, PrinterInfo? printer = null, PrinterCapabilities? caps = null,
                               DocumentKind? kind = null, string id = "job", PrinterPrefs? prefs = null, IReadOnlyList<LayoutSize>? sizes = null)
    {
        var document = new LoadedDocument("Letter.pdf", kind ?? new DocumentKind.Pdf(false),
                                          sizes ?? [.. Enumerable.Repeat(new LayoutSize(612, 792), pages)]);
        var plan = PrintJobs.Plan([document], null, settings, caps, prefs ?? new PrinterPrefs());
        return new SheetJob(document.Name, printer ?? Printer(), caps, settings, plan, [document], id);
    }
}
