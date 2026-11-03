using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>
/// What the demo printer is like right now, shared by the window (its row, its menu) and the printer: whether it prints both
/// sides, whether it is out of paper, its ink and the folders its jobs went to. Kept for the session only.
/// </summary>
public sealed class DemoPrinterState
{
    private const int LowAt = 15;
    private static readonly (string Name, string Color)[] Inks =
        [("Cyan", "#00AEEF"), ("Magenta", "#EC008C"), ("Yellow", "#FFF200"), ("Black", "#231F20")];

    private readonly int[] _ink = [100, 100, 100, 100];

    /// <summary>The Demo printer prints both sides (a switch on its menu).</summary>
    public bool Duplex { get; set; } = true;

    /// <summary>Set from its menu to try the troubleshooter and the two-sided card.</summary>
    public bool OutOfPaper { get; set; }

    /// <summary>Where the jobs' folders go: Documents\Lazy Print\Demo prints.</summary>
    public string Root { get; init; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Lazy Print", "Demo prints");

    /// <summary>The folder of each job record, by its id.</summary>
    public Dictionary<string, string> Folders { get; } = [];

    public IReadOnlyList<Supply> Supplies() => [.. Inks.Select((ink, i) => new Supply(ink.Name, ink.Color, _ink[i], _ink[i] <= LowAt))];

    public PrinterProblem? Problem =>
        OutOfPaper ? new PrinterProblem(IppProblemText.OutOfPaper, IppProblemText.OutOfPaperAdvice, true) : null;

    /// <summary>A job takes a little ink: black only for a gray one.</summary>
    internal void UseInk(bool gray)
    {
        for (int i = gray ? Inks.Length - 1 : 0; i < _ink.Length; i++)
        {
            _ink[i] = Math.Max(0, _ink[i] - 2);
        }
    }
}

/// <summary>
/// The demo printer: always listed, last, so every task can be tried without a printer. It takes any format, has Letter,
/// A4 and 4 × 6 in photo paper with 0.17 in margins, and prints both sides unless its state says it does not. It "prints" by
/// writing each side as a PNG into a folder of its own under <see cref="DemoPrinterState.Root"/>.
/// </summary>
public sealed class DemoPrinter(IPageRenderer pages, DemoPrinterState state) : ISheetPrinter
{
    /// <summary>0.17 in in hundredths of a millimetre.</summary>
    private const int Margin = 432;
    private const double Dpi = 150;

    private static readonly (int Width, int Height)[] Papers = [(21590, 27940), (21000, 29700), (10160, 15240)];

    public static PrinterCapabilities Capabilities(bool duplex) => new()
    {
        Name = PrinterMerge.DemoName,
        MakeAndModel = "Demo Printer",
        DocumentFormatsSupported = ["application/pdf", "image/pwg-raster", "image/urf", "image/jpeg"],
        SidesSupported = duplex ? ["one-sided", "two-sided-long-edge", "two-sided-short-edge"] : ["one-sided"],
        PrintColorModesSupported = ["color", "monochrome"],
        CopiesSupported = (1, 99),
        MultipleDocumentHandlingSupported = ["separate-documents-collated-copies"],
        PrintQualitySupported = [3, 4, 5],
        MediaColDatabase = [.. Papers.Select(p => new MediaEntry([], p.Width, p.Height, false, new MediaMargins(Margin, Margin, Margin, Margin), null, null))],
    };

    public async Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (state.Problem is { } problem) throw new PrinterProblemException(problem);

        var sides = JobSides.Of(job, pass);
        string folder = FolderOf(job);
        bool gray = job.Settings.Color == ColorChoice.Gray;
        var area = job.Plan.Plan.Area;
        var names = Names(job, pass, sides.Count);
        progress.Report(new JobStatus(JobState.Printing, 0));
        await StaWork.Run(() =>
        {
            var renderer = new SheetRenderer(job.Documents, pages);
            for (int i = 0; i < sides.Count; i++)
            {
                token.ThrowIfCancellationRequested();
                var side = sides[i];
                BitmapSource bitmap = renderer.Render(side.Side, area, Dpi, side.Items, side.Marked, side.Turned);
                if (gray) bitmap = new FormatConvertedBitmap(bitmap, PixelFormats.Gray8, null, 0);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var file = File.Create(Path.Combine(folder, names[i] + ".png"));
                encoder.Save(file);
                progress.Report(new JobStatus(JobState.Printing, i + 1));
            }
            return 0;
        });
        state.UseInk(gray);
    }

    /// <summary>The job's folder, made the first time (both passes of a job go to the same one).</summary>
    private string FolderOf(SheetJob job)
    {
        if (job.Id.Length > 0 && state.Folders.TryGetValue(job.Id, out string? known)) return known;
        string clean = string.Concat(job.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim();
        string folder = Path.Combine(state.Root, $"{DateTime.Now:yyyy-MM-dd HH.mm.ss} {clean}".TrimEnd());
        for (int n = 2; Directory.Exists(folder); n++)
        {
            folder = Path.Combine(state.Root, $"{DateTime.Now:yyyy-MM-dd HH.mm.ss} {clean} {n}".TrimEnd());
        }
        Directory.CreateDirectory(folder);
        if (job.Id.Length > 0) state.Folders[job.Id] = folder;
        return folder;
    }

    /// <summary>"Sheet 2 front", "Sheet 2 back", "Sheet 2" for one side, "Fronts 2" and "Backs 2" for the passes of a manual job.</summary>
    private static List<string> Names(SheetJob job, int pass, int count)
    {
        var plan = job.Plan;
        string Name(int i) =>
            plan.ManualDuplex ? $"{(pass == 0 ? "Fronts" : "Backs")} {i + 1}"
            : plan.Plan.Duplex ? $"Sheet {i / 2 + 1} {(i % 2 == 0 ? "front" : "back")}"
            : $"Sheet {i + 1}";
        return [.. Enumerable.Range(0, count).Select(Name)];
    }
}
