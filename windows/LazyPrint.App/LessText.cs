namespace LazyPrint.App;

/// <summary>
/// The short visible texts only the Windows layout has: the empty print screen's lines and the reasons
/// of controls the Mac lays out differently. The short texts both apps show (disabled reasons, the
/// status line, the inspector's summaries) are in Core (<see cref="LazyPrint.Core.StatusLine"/>,
/// <see cref="LazyPrint.Core.InspectorSections"/> and the types they belong to).
/// </summary>
internal static class ShortText
{
    /// <summary>The empty print screen's title.</summary>
    public const string NoDocuments = "Nothing to print yet";
    /// <summary>The empty print screen's line.</summary>
    public const string AddFiles = "Pages you add appear here.";
    /// <summary>Over the window while files the print screen takes are dragged over it.</summary>
    public const string DropFiles = "Drop to add to the print";
    /// <summary>The empty print screen's second line.</summary>
    public const string DropHint = "Or drop PDFs and pictures anywhere in the window.";
    /// <summary>A booklet's pages are always two-sided.</summary>
    public const string BookletTwoSided = "Booklets are two-sided";
    /// <summary>A booklet sets how many pages go on a side.</summary>
    public const string BookletPages = "Set by Booklet";
    /// <summary>A poster is one page across several one-sided sheets.</summary>
    public const string PosterOneSided = "Posters are one-sided";
    /// <summary>A poster sets how many pages go on a side.</summary>
    public const string PosterPages = "Set by Poster";
    /// <summary>The poster choice while a booklet or several pages per side are on.</summary>
    public const string PosterAlone = "Needs one page per side";
    /// <summary>The margin choice while the pages are not sized to fit.</summary>
    public const string MarginsUnused = "Not used at actual size or fill";
    /// <summary>The bar's title while files wait for a job to end.</summary>
    public const string FilesQueuedTitle = "Files waiting";
    public const string FilesQueued = "They are added when the job ends.";
    /// <summary>Scaling while pages share a side or fold into a booklet: they are fitted to their space.</summary>
    public const string PagesFit = "Pages fit their space";
    /// <summary>The photo size while the Photo sheet task lays out the sheet.</summary>
    public const string SheetLayout = "Set by Photo sheet";
    /// <summary>Color while the printer prints gray only.</summary>
    public const string GrayOnly = "This printer prints gray only";
    /// <summary>Quality while the printer does not list any.</summary>
    public const string NoQuality = "Not on this printer";
    /// <summary>Under two-sided on a printer that cannot turn the sheet itself.</summary>
    public const string ByHand = "By hand, in two passes";
    /// <summary>Under the paper picker while the printer does not list the chosen paper.</summary>
    public const string PaperNotListed = "Not listed by this printer";
}
