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
    bool ScalingEnabled,
    string? ScalingReason,
    bool ShowScale,
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
        bool twoSided = s.Booklet || s.Sides != Sides.OneSided;
        string? byHand = twoSided && !photos && capabilities is not null && !canTurn ? ShortText.ByHand : null;

        bool alone = !s.Booklet && s.PagesPerSheet == 1;

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
            SidesEnabled: !s.Booklet,
            SidesReason: s.Booklet ? ShortText.BookletTwoSided : null,
            SidesNote: byHand,
            ShowLayout: task != PrintTask.Photos,
            PagesPerSideEnabled: !s.Booklet,
            PagesPerSideReason: s.Booklet ? ShortText.BookletPages : null,
            ShowRightToLeft: s.Booklet || s.PagesPerSheet > 1,
            ShowBorders: !s.Booklet && s.PagesPerSheet > 1,
            ScalingEnabled: alone,
            ScalingReason: alone ? null : ShortText.PagesFit,
            ShowScale: alone && s.Scaling is Scaling.ShrinkToFit or Scaling.ActualSize,
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
