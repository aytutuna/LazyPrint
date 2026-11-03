using System.Globalization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintJobs.swift: from settings to sheets to a job.

/// <summary>A document the user picked: its pages at the size they are shown.</summary>
public sealed record LoadedDocument(string Name, DocumentKind Kind, IReadOnlyList<LayoutSize> Pages)
{
    public bool Equals(LoadedDocument? other) =>
        other is not null && Name == other.Name && Kind == other.Kind && Pages.SequenceEqual(other.Pages);

    public override int GetHashCode() => HashCode.Combine(Name, Pages.Count);
}

/// <summary>What a job will print.</summary>
/// <param name="ManualDuplex">Two-sided was asked for and the printer can't: two passes.</param>
/// <param name="Passes">One pass, or the fronts then the backs.</param>
/// <param name="CopiesInJob">The copies the printer makes; the rest are repeated in the stream (<see cref="PrintCopies"/>).</param>
/// <param name="Notes">For the user: "2 blank pages added", "Pages made smaller (82 %)".</param>
public sealed record JobPlan(SheetPlan Plan, bool ManualDuplex, IReadOnlyList<DuplexPass> Passes, int CopiesInJob, IReadOnlyList<string> Notes)
{
    public bool Equals(JobPlan? other) =>
        other is not null && Plan == other.Plan && ManualDuplex == other.ManualDuplex && CopiesInJob == other.CopiesInJob
        && Passes.SequenceEqual(other.Passes) && Notes.SequenceEqual(other.Notes);

    public override int GetHashCode() => HashCode.Combine(Plan, ManualDuplex, CopiesInJob);
}

public static class PrintJobs
{
    private const string CollatedCopies = "separate-documents-collated-copies";

    /// <summary>
    /// The layout the settings ask for. Photo tasks print one side, never a booklet. The task is only
    /// consulted for that: the other tasks have already set what they mean in the settings.
    /// </summary>
    public static LayoutOptions LayoutOptions(PrintSettings settings, PrintTask? task)
    {
        bool photos = task is PrintTask.Photos or PrintTask.PhotoSheet;
        return new LayoutOptions
        {
            PagesPerSheet = settings.PagesPerSheet,
            Booklet = settings.Booklet && !photos,
            RightToLeft = settings.RightToLeft,
            Scaling = settings.Scaling,
            Sides = photos ? Sides.OneSided : settings.Sides,
            PageBorders = settings.PageBorders,
        };
    }

    /// <summary>
    /// Where the printer can print on a paper: the printer's matching media-col-database entry (borderless
    /// or not, the other kind when only that exists), else 0.25 in on every side. Automatic is the paper the
    /// printer has loaded, else the usual one where the user lives.
    /// </summary>
    public static PrintableArea Area(PaperSize paper, PrinterCapabilities? printer, bool borderless)
    {
        var size = Sheet(paper, printer);
        if (printer?.Match(size, borderless)?.PrintableArea is { } area) return area;
        const double Margin = 0.25 * 72;
        return new PrintableArea(size, new LayoutInsets(Margin, Margin, Margin, Margin));
    }

    /// <summary>
    /// The sheets of a job. The pages of all documents run on as one, and <paramref name="pageRange"/> (0-based, as
    /// <see cref="PageRange.Parse"/> gives it) counts along that run; an index past its end is skipped. Photo prints
    /// are laid out by <see cref="PhotoLayout"/>, everything else by <see cref="Imposition"/>. A printer without
    /// two-sided gets the fronts and the backs as two passes, the backs turned and ordered for the learnt
    /// <see cref="PrinterPrefs.PaperPath"/>.
    /// </summary>
    public static JobPlan Plan(IReadOnlyList<LoadedDocument> documents, IReadOnlyList<int>? pageRange, PrintSettings settings,
                               PrintTask? task, PrinterCapabilities? printer, PrinterPrefs prefs)
    {
        var all = documents
            .SelectMany((document, d) => document.Pages.Select((size, i) => new SourcePage(d, i, size)))
            .ToList();
        var pages = pageRange is null ? all : pageRange.Where(i => i >= 0 && i < all.Count).Select(i => all[i]).ToList();

        bool photos = task == PrintTask.Photos;
        var paper = PaperSizes.Parse(settings.PaperId);
        var area = Area(paper, printer, photos && Borderless(settings.PhotoSizeId, Sheet(paper, printer)));
        var plan = photos
            ? PhotoLayout.Plan(pages, new PhotoOptions(PhotoSizeOf(settings.PhotoSizeId), 1, settings.PhotoFill, settings.CutMarks), area)
            : Imposition.Plan(pages, LayoutOptions(settings, task), area);

        bool manual = plan.Duplex && printer?.SidesSupported.Contains("two-sided-long-edge") != true;
        IReadOnlyList<DuplexPass> passes;
        if (manual)
        {
            var (fronts, backs) = ManualDuplex.Passes(plan, prefs.PaperPath);
            passes = [fronts, backs];
        }
        else
        {
            var sides = new List<SheetSide>();
            foreach (var sheet in plan.Sheets)
            {
                sides.Add(sheet.Front);
                if (sheet.Back is { } back) sides.Add(back);
            }
            passes = [new DuplexPass(sides, [])];
        }

        var copies = PrintCopies.Plan(settings.Copies, printer?.CopiesSupported.Upper, plan.SideCount, CanCollate(settings, printer));
        return new JobPlan(plan, manual, passes, copies.TicketCopies, Notes(plan.Warnings));
    }

    /// <summary>
    /// The ticket for a printer's Print-Job. The paper is the printer's database entry for the sheet size (borderless
    /// when the layout assumed no margins), so the margins are the ones laid out; sheets are asked for as they were
    /// planned (no scaling, two-sided on the long edge whatever the flip, since the planner turns the backs), and a manual
    /// pass is one-sided. Quality, scaling and the copies' collation are asked for only when the printer lists them.
    /// A paper the printer has no entry for is sent as a media-col with the margins laid out when it lists media-col-supported.
    /// A document <paramref name="asIs"/> is the printer's to scale ("auto" for shrink to fit, "fit"), and goes two-sided on
    /// the short edge when asked and listed.
    /// </summary>
    public static IppJobTicket Ticket(JobPlan job, PrintSettings settings, string format, PrinterCapabilities? printer, string name,
                                      bool asIs = false)
    {
        var area = job.Plan.Area;

        string mode = settings.Color == ColorChoice.Gray ? "monochrome" : "color";
        if (printer is { PrintColorModesSupported: { Count: > 0 } modes } && !modes.Contains(mode) && modes.Contains("monochrome"))
            mode = "monochrome";

        int quality = settings.Quality switch { QualityChoice.Draft => 3, QualityChoice.Best => 5, _ => 4 };
        bool hasCopies = job.CopiesInJob > 1;
        string sides = !job.Plan.Duplex || job.ManualDuplex ? "one-sided"
            : asIs && settings.Sides == Sides.ShortEdge && printer?.SidesSupported.Contains("two-sided-short-edge") == true
                ? "two-sided-short-edge"
                : "two-sided-long-edge";
        return new IppJobTicket(
            name,
            format,
            job.CopiesInJob,
            sides,
            mode,
            Media(area, printer),
            printer?.PrintQualitySupported.Contains(quality) == true ? quality : null,
            PrintScaling(settings.Scaling, printer, asIs),
            hasCopies && settings.Collate && printer?.MultipleDocumentHandlingSupported.Contains(CollatedCopies) == true);
    }

    private static string? PrintScaling(Scaling scaling, PrinterCapabilities? printer, bool asIs)
    {
        var listed = printer?.PrintScalingSupported ?? [];
        string[] wanted = !asIs ? ["none"]
            : scaling == Scaling.Fit ? ["fit", "auto"]
            : scaling == Scaling.ShrinkToFit ? ["auto", "fit"]
            : ["none"];
        return wanted.FirstOrDefault(w => listed.Contains(w));
    }

    /// <summary>The printer's database entry for the sheet, else a media-col of the sheet's size and margins, else its name.</summary>
    private static IppMediaChoice Media(PrintableArea area, PrinterCapabilities? printer)
    {
        string name = MediaName(area.Paper);
        if (printer?.Match(area.Paper, area.Margins == default) is { } entry) return new IppMediaChoice(entry.Attributes, name);

        var supported = printer?.MediaColSupported ?? [];
        int Hundredths(double points) => (int)Math.Round(points * 2540 / 72);
        var members = new List<IppAttribute>
        {
            new("media-size", new IppValue.Collection(
            [
                new IppAttribute("x-dimension", new IppValue.Integer(Hundredths(area.Paper.Width))),
                new IppAttribute("y-dimension", new IppValue.Integer(Hundredths(area.Paper.Height))),
            ])),
        };
        var margins = new (string Name, double Points)[]
        {
            ("media-top-margin", area.Margins.Top), ("media-left-margin", area.Margins.Left),
            ("media-bottom-margin", area.Margins.Bottom), ("media-right-margin", area.Margins.Right),
        };
        foreach (var (margin, points) in margins.Where(m => supported.Contains(m.Name)))
            members.Add(new IppAttribute(margin, new IppValue.Integer(Hundredths(points))));
        return new IppMediaChoice(members.Count > 1 ? members : null, name);
    }

    /// <summary>A photo is borderless when it is the whole page, or as large as the paper it goes on.</summary>
    private static bool Borderless(string photoSizeId, LayoutSize sheet) =>
        PhotoSizeOf(photoSizeId).Size is not { } photo
        || (Math.Abs(photo.Width - sheet.Width) <= PaperSizes.FitTolerance && Math.Abs(photo.Height - sheet.Height) <= PaperSizes.FitTolerance);

    /// <summary>The paper a job goes on, portrait, in points.</summary>
    private static LayoutSize Sheet(PaperSize paper, PrinterCapabilities? printer) =>
        (paper == PaperSize.Auto ? Loaded(printer) ?? PaperSizes.Points(UsualPaper()) : PaperSizes.Points(paper))
        ?? throw new InvalidOperationException("A paper size has points.");

    private static bool CanCollate(PrintSettings settings, PrinterCapabilities? printer) =>
        !settings.Collate || printer?.MultipleDocumentHandlingSupported.Contains(CollatedCopies) == true;

    private static PhotoSize PhotoSizeOf(string id) => PhotoSize.All.FirstOrDefault(s => s.Id == id) ?? PhotoSize.All[0];

    /// <summary>The first ready paper of the printer that has a fixed size (media-col-ready, else media-ready), portrait, in points.</summary>
    private static LayoutSize? Loaded(PrinterCapabilities? printer)
    {
        if (printer is null) return null;
        if (printer.MediaColReady.FirstOrDefault(e => !e.IsVariable && e.Width > 0 && e.Height > 0) is { } entry)
        {
            double width = MediaEntry.Points(entry.Width), height = MediaEntry.Points(entry.Height);
            return new LayoutSize(Math.Min(width, height), Math.Max(width, height));
        }
        return printer.MediaReady.Select(PwgSize).OfType<LayoutSize>().FirstOrDefault() is { Width: > 0 } size ? size : null;
    }

    /// <summary>The size in a PWG self-describing name ("iso_a4_210x297mm", "na_letter_8.5x11in"), portrait, in points; null for any other.</summary>
    private static LayoutSize? PwgSize(string name)
    {
        string[] parts = name.Split('_');
        if (parts.Length < 3 || parts[1] is "min" or "max") return null;
        string last = parts[^1];
        double unit = last.EndsWith("mm", StringComparison.Ordinal) ? 72 / 25.4 : last.EndsWith("in", StringComparison.Ordinal) ? 72 : 0;
        string[] sides = last.Length > 2 ? last[..^2].Split('x') : [];
        if (unit == 0 || sides.Length != 2
            || !double.TryParse(sides[0], NumberStyles.Float, CultureInfo.InvariantCulture, out double a)
            || !double.TryParse(sides[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double b)
            || a <= 0 || b <= 0) return null;
        return new LayoutSize(Math.Min(a, b) * unit, Math.Max(a, b) * unit);
    }

    private static PaperSize UsualPaper() => PaperSizes.DefaultForRegion(RegionInfo.CurrentRegion.TwoLetterISORegionName);

    private static List<string> Notes(IReadOnlyList<PlanWarning> warnings) => [.. warnings.Select(w => w switch
    {
        PlanWarning.PaddedWithBlanks padded => PrintText.BlanksAdded(padded.Count),
        PlanWarning.Shrunk shrunk => PrintText.MadeSmaller(shrunk.Percent),
        PlanWarning.Clipped clipped => PrintText.EdgesCut(Math.Max(1, (int)Math.Round(clipped.Points * 25.4 / 72))),
        _ => "",
    }).Where(text => text.Length > 0)];

    /// <summary>A PWG self-describing media name: the named sizes as printers list them, else a custom one in millimetres.</summary>
    private static string MediaName(LayoutSize paper) => PaperSizes.Match(paper) switch
    {
        PaperSize.Letter => "na_letter_8.5x11in",
        PaperSize.Legal => "na_legal_8.5x14in",
        PaperSize.Executive => "na_executive_7.25x10.5in",
        PaperSize.A4 => "iso_a4_210x297mm",
        PaperSize.A5 => "iso_a5_148x210mm",
        PaperSize.A6 => "iso_a6_105x148mm",
        PaperSize.B5Jis => "jis_b5_182x257mm",
        PaperSize.IdCard => "iso_id-1_53.98x85.6mm",
        _ => string.Create(CultureInfo.InvariantCulture,
            $"custom_sheet_{(int)Math.Round(paper.Width * 25.4 / 72)}x{(int)Math.Round(paper.Height * 25.4 / 72)}mm"),
    };
}

public enum JobState
{
    Preparing,
    Sending,
    Waiting,
    Printing,
    Done,
    Failed,
    Canceled,
    NeedsUser,
}

/// <summary>A job of this session, as the Jobs tab lists it.</summary>
public sealed record JobRecord(string Id, string Name, string PrinterName, int Sheets, int Copies, JobState State, string? Detail, DateTimeOffset Started);
