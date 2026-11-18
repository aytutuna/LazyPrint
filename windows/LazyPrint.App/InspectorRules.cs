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
    bool ScalingFitOnly,
    bool ShowScale,
    bool BookletEnabled,
    string? BookletReason,
    bool PosterEnabled,
    string? PosterReason,
    bool MarginEnabled,
    string? MarginReason,
    bool ColorEnabled,
    string? ColorReason,
    bool QualityEnabled,
    string? QualityReason,
    string? PaperNote)
{
    /// <param name="capabilities">What the printer in use can do; null while that is not known.</param>
    internal static InspectorState For(PrintSettings s, PrinterCapabilities? capabilities)
    {
        bool canTurn = capabilities?.SidesSupported.Contains("two-sided-long-edge") == true;

        // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
        bool poster = s.Poster is >= 2 and <= 4;
        bool twoSided = !poster && (s.Booklet || s.Sides != Sides.OneSided);
        string? byHand = twoSided && capabilities is not null && !canTurn ? ShortText.ByHand : null;

        bool alone = !poster && !s.Booklet && s.PagesPerSheet == 1;
        // A print size that fits makes the page a cell, so Scale does not apply.
        bool sized = alone && PrintJobs.LayoutOptions(s, capabilities).CellSize is not null;
        bool lone = alone && !sized;

        bool grayOnly = capabilities?.GrayOnly == true;
        bool noQuality = capabilities?.NoQuality == true;

        string? paperNote = null;
        if (PaperSizes.PointsOf(s.PaperId) is { } size && !PaperSizes.Supports(capabilities, size))
        {
            paperNote = ShortText.PaperNotListed;
        }

        return new InspectorState(
            ShowCollate: s.Copies > 1,
            SidesEnabled: !s.Booklet && !poster,
            SidesReason: poster ? ShortText.PosterOneSided : s.Booklet ? ShortText.BookletTwoSided : null,
            SidesNote: byHand,
            PagesPerSideEnabled: !s.Booklet && !poster,
            PagesPerSideReason: poster ? ShortText.PosterPages : s.Booklet ? ShortText.BookletPages : null,
            ShowRightToLeft: !poster && (s.Booklet || s.PagesPerSheet > 1),
            ShowBorders: !poster && !s.Booklet && s.PagesPerSheet > 1,
            ShowOrientation: !s.Booklet,
            ScalingEnabled: !poster,
            ScalingFitOnly: !lone,
            ShowScale: lone && s.Scaling is Scaling.ShrinkToFit or Scaling.ActualSize,
            BookletEnabled: !poster,
            BookletReason: poster ? ShortText.PosterPages : null,
            PosterEnabled: poster || !s.Booklet && s.PagesPerSheet == 1,
            PosterReason: poster || !s.Booklet && s.PagesPerSheet == 1 ? null : ShortText.PosterAlone,
            MarginEnabled: true,
            MarginReason: null,
            ColorEnabled: !grayOnly,
            ColorReason: grayOnly ? ShortText.GrayOnly : null,
            QualityEnabled: !noQuality,
            QualityReason: noQuality ? ShortText.NoQuality : null,
            PaperNote: paperNote);
    }
}
