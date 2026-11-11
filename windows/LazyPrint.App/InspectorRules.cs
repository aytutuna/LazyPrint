using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// What the inspector shows for the task and the printer: a control that cannot apply is hidden, one that conflicts with
/// another choice is greyed out with its reason beside it. Plain data, so the window only has to show it.
/// </summary>
public sealed record InspectorState(
    bool ShowCollate,
    bool ShowSides,
    bool SidesEnabled,
    string? SidesReason,
    string? SidesNote,
    bool ShowLayout,
    bool PagesPerSideEnabled,
    string? PagesPerSideReason,
    bool ShowRightToLeft,
    bool ShowBorders,
    bool ShowOrientation,
    bool ScalingEnabled,
    string? ScalingReason,
    bool ShowScale,
    bool BookletEnabled,
    bool PosterEnabled,
    string? PosterReason,
    bool MarginEnabled,
    string? MarginReason,
    bool ShowPhotos,
    bool PhotoSizeEnabled,
    string? PhotoSizeReason,
    bool ColorEnabled,
    string? ColorReason,
    bool QualityEnabled,
    string? QualityReason,
    string? PaperNote)
{
    /// <param name="capabilities">What the printer in use can do; null while that is not known.</param>
    internal static InspectorState For(PrintSettings s, PrintTask? task, PrinterCapabilities? capabilities)
    {
        bool photos = task is PrintTask.Photos or PrintTask.PhotoSheet;
        bool canTurn = capabilities?.SidesSupported.Contains("two-sided-long-edge") == true;

        // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
        bool poster = s.Poster is >= 2 and <= 4;
        bool twoSided = !poster && (s.Booklet || s.Sides != Sides.OneSided);
        string? byHand = twoSided && !photos && capabilities is not null && !canTurn ? ShortText.ByHand : null;

        bool alone = !poster && !s.Booklet && s.PagesPerSheet == 1;
        bool margins = Imposition.KeepsMargin(PrintJobs.LayoutOptions(s, task));

        bool grayOnly = capabilities is { PrintColorModesSupported.Count: > 0 } && !capabilities.PrintColorModesSupported.Contains("color");
        bool noQuality = capabilities is { PrintQualitySupported.Count: 0 };

        string? paperNote = null;
        var paper = PaperSizes.Parse(s.PaperId);
        if (paper != PaperSize.Auto && capabilities is { MediaColDatabase.Count: > 0 }
            && PaperSizes.Points(paper) is { } size && capabilities.Match(size) is null)
        {
            paperNote = ShortText.PaperNotListed;
        }

        return new InspectorState(
            ShowCollate: s.Copies > 1,
            ShowSides: !photos,
            SidesEnabled: !s.Booklet && !poster,
            SidesReason: poster ? ShortText.PosterOneSided : s.Booklet ? ShortText.BookletTwoSided : null,
            SidesNote: byHand,
            ShowLayout: task != PrintTask.Photos,
            PagesPerSideEnabled: !s.Booklet && !poster,
            PagesPerSideReason: poster ? ShortText.PosterPages : s.Booklet ? ShortText.BookletPages : null,
            ShowRightToLeft: !poster && (s.Booklet || s.PagesPerSheet > 1),
            ShowBorders: !poster && !s.Booklet && s.PagesPerSheet > 1,
            ShowOrientation: !s.Booklet,
            ScalingEnabled: alone || !poster && s.Scaling == Scaling.Fill,
            ScalingReason: alone || !poster && s.Scaling == Scaling.Fill ? null : ShortText.PagesFit,
            ShowScale: alone && s.Scaling is Scaling.ShrinkToFit or Scaling.ActualSize,
            BookletEnabled: !poster,
            PosterEnabled: poster || !s.Booklet && s.PagesPerSheet == 1,
            PosterReason: poster || !s.Booklet && s.PagesPerSheet == 1 ? null : ShortText.PosterAlone,
            MarginEnabled: margins,
            MarginReason: margins ? null : ShortText.MarginsUnused,
            ShowPhotos: photos,
            PhotoSizeEnabled: task == PrintTask.Photos,
            PhotoSizeReason: task == PrintTask.PhotoSheet ? ShortText.SheetLayout : null,
            ColorEnabled: !grayOnly,
            ColorReason: grayOnly ? ShortText.GrayOnly : null,
            QualityEnabled: !noQuality,
            QualityReason: noQuality ? ShortText.NoQuality : null,
            PaperNote: paperNote);
    }
}
