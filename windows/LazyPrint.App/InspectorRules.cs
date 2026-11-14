using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// What the inspector shows for the task and the printer: a control that cannot apply is hidden, one that conflicts with
/// another choice is greyed out with its reason beside it. Plain data, so the window only has to show it.
/// </summary>
public sealed record InspectorState(
    bool ShowCollate,
    bool SidesEnabled,
    string? SidesReason,
    string? SidesNote,
    bool PagesPerSideEnabled,
    string? PagesPerSideReason,
    bool ShowRightToLeft,
    bool ShowBorders,
    bool ShowOrientation,
    bool ScalingEnabled,
    string? ScalingReason,
    bool ShowScale,
    bool BookletEnabled,
    string? BookletReason,
    bool PosterEnabled,
    string? PosterReason,
    bool MarginEnabled,
    string? MarginReason,
    bool PhotoSizeEnabled,
    string? PhotoSizeReason,
    bool PhotoFillEnabled,
    string? PhotoFillReason,
    bool CutMarksEnabled,
    string? CutMarksReason,
    bool ColorEnabled,
    string? ColorReason,
    bool QualityEnabled,
    string? QualityReason,
    string? PaperNote)
{
    /// <param name="capabilities">What the printer in use can do; null while that is not known.</param>
    internal static InspectorState For(PrintSettings s, PrinterCapabilities? capabilities)
    {
        bool photos = s.LayoutStyle.IsPhoto();
        bool photoPrints = s.LayoutStyle == LayoutStyle.PhotoPrints;
        bool canTurn = capabilities?.SidesSupported.Contains("two-sided-long-edge") == true;

        // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
        bool poster = s.Poster is >= 2 and <= 4;
        bool twoSided = !poster && (s.Booklet || s.Sides != Sides.OneSided);
        string? byHand = twoSided && !photos && capabilities is not null && !canTurn ? ShortText.ByHand : null;

        bool alone = !poster && !s.Booklet && s.PagesPerSheet == 1;

        bool grayOnly = capabilities is { PrintColorModesSupported.Count: > 0 } && !capabilities.PrintColorModesSupported.Contains("color");
        bool noQuality = capabilities is { PrintQualitySupported.Count: 0 };

        string? paperNote = null;
        if (PaperSizes.PointsOf(s.PaperId) is { } size && !PaperSizes.Supports(capabilities, size))
        {
            paperNote = ShortText.PaperNotListed;
        }

        return new InspectorState(
            ShowCollate: s.Copies > 1,
            SidesEnabled: !s.Booklet && !poster && !photos,
            SidesReason: photos ? ShortText.PhotosOneSided : poster ? ShortText.PosterOneSided : s.Booklet ? ShortText.BookletTwoSided : null,
            SidesNote: byHand,
            PagesPerSideEnabled: !s.Booklet && !poster && !photoPrints,
            PagesPerSideReason: photoPrints ? ShortText.PhotoPrintsLayout : poster ? ShortText.PosterPages : s.Booklet ? ShortText.BookletPages : null,
            ShowRightToLeft: !poster && (s.Booklet || s.PagesPerSheet > 1),
            ShowBorders: !poster && !s.Booklet && s.PagesPerSheet > 1,
            ShowOrientation: !s.Booklet,
            ScalingEnabled: !photoPrints && (alone || !poster && s.Scaling == Scaling.Fill),
            ScalingReason: photoPrints ? ShortText.PhotoPrintsLayout : alone || !poster && s.Scaling == Scaling.Fill ? null : ShortText.PagesFit,
            ShowScale: alone && s.Scaling is Scaling.ShrinkToFit or Scaling.ActualSize,
            BookletEnabled: !poster && !photos,
            BookletReason: photos ? ShortText.PhotosNoBooklet : poster ? ShortText.PosterPages : null,
            PosterEnabled: !photos && (poster || !s.Booklet && s.PagesPerSheet == 1),
            PosterReason: photos ? ShortText.PhotosNoPoster : poster || !s.Booklet && s.PagesPerSheet == 1 ? null : ShortText.PosterAlone,
            MarginEnabled: !photos,
            MarginReason: photos ? ShortText.PhotosNoMargin : null,
            PhotoSizeEnabled: photoPrints,
            PhotoSizeReason: photoPrints ? null : ShortText.NeedsPhotoPrints,
            PhotoFillEnabled: photoPrints,
            PhotoFillReason: photoPrints ? null : ShortText.NeedsPhotoPrints,
            CutMarksEnabled: photos,
            CutMarksReason: photos ? null : ShortText.NeedsPhotoLayout,
            ColorEnabled: !grayOnly,
            ColorReason: grayOnly ? ShortText.GrayOnly : null,
            QualityEnabled: !noQuality,
            QualityReason: noQuality ? ShortText.NoQuality : null,
            PaperNote: paperNote);
    }
}
