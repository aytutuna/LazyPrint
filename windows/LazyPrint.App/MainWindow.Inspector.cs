using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Shapes;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

// The inspector: its sections (InspectorSections), which are open (as the user left them, remembered in the
// preferences), what each shows for the task and the printer, and the summary a collapsed header gives of what is on
// in it. The controls are filled from the settings (PushSettingsToUi) and write their edits back (Setting_Changed).
public partial class MainWindow
{
    /// <summary>A section of the inspector: its Expander and the parts of its header.</summary>
    private sealed record InspectorSection(string Id, Expander Expander, TextBlock Title, TextBlock Summary, FrameworkElement Dot)
    {
        public string TitleText => Title.Text;
    }

    private readonly List<InspectorSection> _sections = [];
    /// <summary>The sections are being opened or closed by the app (a task opening its section): not remembered.</summary>
    private bool _settingSections;
    /// <summary>What the inspector showed last; edits to a control that is greyed out are not written back.</summary>
    private InspectorState? _inspector;

    private static readonly int[] PagesPerSide = [1, 2, 4, 6, 9, 16];

    private void SetUpInspectorSections()
    {
        Add(PrinterSection, InspectorSections.Printer, "");
        Add(PagesSection, InspectorSections.Pages, "");
        Add(LayoutSection, InspectorSections.Layout, "");
        Add(PaperSection, InspectorSections.Paper, "");
        Add(PhotosSection, InspectorSections.Photos, "");

        Dictionary<string, bool> saved;
        try
        {
            saved = AppPreferencesStore.Load().InspectorSections;
        }
        catch
        {
            saved = [];
        }
        _settingSections = true;
        try
        {
            foreach (var section in _sections)
            {
                section.Expander.IsExpanded = saved.TryGetValue(section.Id, out bool open) ? open : InspectorSections.OpenByDefault(section.Id);
            }
        }
        finally
        {
            _settingSections = false;
        }
    }

    private void Add(Expander expander, string id, string glyph)
    {
        var icon = new TextBlock { Text = glyph, Margin = new Thickness(0, 2, 12, 0), VerticalAlignment = VerticalAlignment.Top };
        icon.SetResourceReference(StyleProperty, "GlyphText");
        var titleText = new TextBlock { Text = InspectorSections.Title(id), TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };
        titleText.SetResourceReference(StyleProperty, "BodyStrongText");
        // A 6 DIP accent dot: something in the collapsed section differs from the default.
        var dot = new Ellipse { Width = 6, Height = 6, Margin = new Thickness(8, 1, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        dot.SetResourceReference(Shape.FillProperty, "AccentFillColorDefaultBrush");
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
        titleRow.Children.Add(titleText);
        titleRow.Children.Add(dot);
        var summary = new TextBlock { Visibility = Visibility.Collapsed, MaxWidth = 196 };
        summary.SetResourceReference(StyleProperty, "SectionSummaryText");
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(titleRow);
        texts.Children.Add(summary);
        var header = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        header.Children.Add(icon);
        header.Children.Add(texts);
        expander.Header = header;
        expander.Tag = id;
        var section = new InspectorSection(id, expander, titleText, summary, dot);
        _sections.Add(section);
        expander.Expanded += (_, e) => SectionToggled(section, e);
        expander.Collapsed += (_, e) => SectionToggled(section, e);
    }

    private void SectionToggled(InspectorSection section, RoutedEventArgs e)
    {
        if (!ReferenceEquals(e.OriginalSource, section.Expander)) return;
        if (IsLoaded) SyncInspectorSections();
        if (_settingSections) return;
        bool open = section.Expander.IsExpanded;
        try
        {
            AppPreferencesStore.Update(preferences => preferences.InspectorSections[section.Id] = open);
        }
        catch
        {
            // The preferences could not be written: the section stays as it is for this session.
        }
    }

    /// <summary>Opens a section for a task that needs it (the photo tasks open Photos); not remembered.</summary>
    private void OpenSectionFor(PrintTask task)
    {
        if (InspectorSections.OpenedBy(task) is not { } id) return;
        _settingSections = true;
        try
        {
            foreach (var section in _sections.Where(s => s.Id == id)) section.Expander.IsExpanded = true;
        }
        finally
        {
            _settingSections = false;
        }
    }

    // MARK: - The choices

    private static ComboBoxItem Item(string text, object tag, string? toolTip = null) =>
        new() { Content = text, Tag = tag, ToolTip = toolTip };

    private void BuildChoices()
    {
        for (int count = 1; count <= PrintCopies.MaxCount; count++) CopiesBox.Items.Add(count);
        foreach (int n in PagesPerSide) PerSideBox.Items.Add(Item(n == 1 ? "1 (one per side)" : $"{n} per side", n));
        PosterBox.Items.Add(Item("Off", 0));
        for (int n = 2; n <= 4; n++) PosterBox.Items.Add(Item($"{n} × {n} sheets", n, "One page enlarged across the sheets, with an overlap and cut marks"));
        MarginBox.Items.Add(Item("None", MarginChoice.None, "Only what the printer cannot reach"));
        MarginBox.Items.Add(Item("Small, 6 mm", MarginChoice.Small));
        MarginBox.Items.Add(Item("Normal, 12 mm", MarginChoice.Normal));
        MarginBox.Items.Add(Item("Custom", MarginChoice.Custom));
        PageSelectionBox.Items.Add(Item("All pages", PageSelection.All));
        PageSelectionBox.Items.Add(Item("Odd pages only", PageSelection.Odd, "Pages 1, 3, 5 and so on"));
        PageSelectionBox.Items.Add(Item("Even pages only", PageSelection.Even, "Pages 2, 4, 6 and so on"));
        OrientationBox.Items.Add(Item("Automatic", SheetOrientation.Automatic, "Each page keeps the way it is turned"));
        OrientationBox.Items.Add(Item("Portrait", SheetOrientation.Portrait, "Every sheet is upright"));
        OrientationBox.Items.Add(Item("Landscape", SheetOrientation.Landscape, "Every sheet is on its side"));
        ScalingBox.Items.Add(Item("Shrink to fit", Scaling.ShrinkToFit, "Large pages are made smaller, the others print at real size"));
        ScalingBox.Items.Add(Item("Fit to page", Scaling.Fit, "Each page is made as large as fits"));
        ScalingBox.Items.Add(Item("Actual size", Scaling.ActualSize, "100 %; the edges the printer cannot reach are cut off"));
        ScalingBox.Items.Add(Item("Fill", Scaling.Fill, "Each page fills its space, cropped in the middle"));
        QualityBox.Items.Add(Item("Normal", QualityChoice.Normal));
        QualityBox.Items.Add(Item("Draft", QualityChoice.Draft, "Faster, uses less ink"));
        QualityBox.Items.Add(Item("Best", QualityChoice.Best, "Slower, the finest print"));
        foreach (var photo in PhotoSize.All) PhotoSizeBox.Items.Add(Item(photo.Title, photo.Id));
    }

    private static string Region => RegionInfo.CurrentRegion.TwoLetterISORegionName;

    /// <summary>The sizes the printer lists (the usual ones when it lists none), the chosen one selected, and the boxes of a custom size.</summary>
    private void ShowPaper(PrintSettings s)
    {
        var choices = PaperSizes.Choices(ViewModel.SelectedCapabilities, s.PaperId, Region);
        if (!PaperBox.Items.OfType<ComboBoxItem>().Select(i => i.Tag).SequenceEqual(choices.Options.Select(o => (object)o.Id)))
        {
            PaperBox.Items.Clear();
            foreach (var option in choices.Options) PaperBox.Items.Add(Item(option.Label, option.Id, option.Detail));
        }
        Select(PaperBox, choices.Selected);

        bool custom = choices.Selected == PaperSizes.CustomId;
        CustomPaperRow.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        if (!custom || PaperSizes.PointsOf(s.PaperId) is not { } size) return;
        var (width, height) = PaperSizes.Dimensions(size, Region);
        if (!CustomWidthBox.IsKeyboardFocused) CustomWidthBox.Text = width.ToString(CultureInfo.CurrentCulture);
        if (!CustomHeightBox.IsKeyboardFocused) CustomHeightBox.Text = height.ToString(CultureInfo.CurrentCulture);
        _shownWidth = width.ToString(CultureInfo.CurrentCulture);
        _shownHeight = height.ToString(CultureInfo.CurrentCulture);
        CustomUnitText.Text = PaperSizes.UsesInches(Region) ? "in" : "mm";
    }

    /// <summary>The tray and paper type rows: shown when the printer lists any, the chosen one selected.</summary>
    private void ShowMedia(PrintSettings s)
    {
        var printer = ViewModel.SelectedCapabilities;
        ShowMediaBox(TrayRow, TrayBox, MediaChoices.Sources(printer), MediaChoices.SourceLabel, s.MediaSource);
        ShowMediaBox(PaperTypeRow, PaperTypeBox, MediaChoices.Types(printer), MediaChoices.TypeLabel, s.MediaType);
    }

    private static void ShowMediaBox(FrameworkElement row, ComboBox box, IReadOnlyList<string> ids, Func<string, string> label, string chosen)
    {
        row.Visibility = ids.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        object[] tags = [MediaChoices.Auto, .. ids];
        if (!box.Items.OfType<ComboBoxItem>().Select(i => i.Tag).SequenceEqual(tags))
        {
            box.Items.Clear();
            box.Items.Add(Item("Automatic", MediaChoices.Auto));
            foreach (string id in ids) box.Items.Add(Item(label(id), id));
        }
        Select(box, ids.Contains(chosen) ? chosen : MediaChoices.Auto);
    }

    private void CustomPaper_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) CustomPaper_Committed(sender, e);
    }

    /// <summary>A size typed in is taken as far as the printer takes it, and shown as it was taken.</summary>
    private void CustomPaper_Committed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        // Tabbing through the boxes must not turn the rounded text on show into the size.
        if (CustomWidthBox.Text == _shownWidth && CustomHeightBox.Text == _shownHeight) return;
        if (!double.TryParse(CustomWidthBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double width)
            || !double.TryParse(CustomHeightBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double height)
            || width <= 0 || height <= 0)
        {
            PushSettingsToUi();
            return;
        }
        ViewModel.Settings.PaperId = PaperSizes.CustomSizeId(width, height, Region, ViewModel.SelectedCapabilities);
        ViewModel.SettingsEdited();
        PushSettingsToUi();
    }

    private static void Select(ComboBox box, object tag)
    {
        var item = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => Equals(i.Tag, tag));
        if (!ReferenceEquals(box.SelectedItem, item)) box.SelectedItem = item;
    }

    private static T? TagOf<T>(ComboBox box) => box.SelectedItem is ComboBoxItem { Tag: T tag } ? tag : default;

    // MARK: - Settings to the controls, and back

    /// <summary>Shows the settings in the controls, hides what cannot apply and greys out what conflicts.</summary>
    private void PushSettingsToUi()
    {
        if (!IsLoaded && PrinterBox is null) return;
        var s = ViewModel.Settings;
        var state = InspectorState.For(s, ViewModel.SelectedTask, ViewModel.SelectedCapabilities);
        _inspector = state;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            // Printer
            var problems = ViewModel.SelectedPrinter?.Problems;
            PrinterProblemRow.Visibility = problems is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
            PrinterProblemText.Text = problems is { Count: > 0 } ? $"{problems[0].Title}. {problems[0].Advice}" : "";

            // Pages
            if (!Equals(CopiesBox.SelectedItem, PrintCopies.Clamp(s.Copies))) CopiesBox.SelectedItem = PrintCopies.Clamp(s.Copies);
            CollateBox.Visibility = state.ShowCollate ? Visibility.Visible : Visibility.Collapsed;
            CollateBox.IsChecked = s.Collate;
            string range = ViewModel.PageRangeText;
            if (PageRangeBox.Text != range) PageRangeBox.Text = range;
            PageRangePlaceholder.Text = PrintText.PageRangeHint(ViewModel.PageCount, ViewModel.Documents.Count);
            Show(PageRangeProblemRow, PageRangeProblemText, ViewModel.PageRangeError);
            Select(PageSelectionBox, s.PageSelection);
            ReverseBox.IsChecked = s.ReverseOrder;
            SidesGroup.Visibility = state.ShowSides ? Visibility.Visible : Visibility.Collapsed;
            var shownSides = s.Poster is >= 2 and <= 4 ? Sides.OneSided : s.Booklet ? Sides.LongEdge : s.Sides;
            SidesOne.IsChecked = shownSides == Sides.OneSided;
            SidesLong.IsChecked = shownSides == Sides.LongEdge;
            SidesShort.IsChecked = shownSides == Sides.ShortEdge;
            SidesTrack.IsEnabled = state.SidesEnabled;
            SidesTrack.ToolTip = state.SidesReason;
            Show(SidesReasonRow, SidesReasonText, state.SidesReason ?? state.SidesNote);

            // Layout
            Select(PerSideBox, s.Booklet ? 2 : PagesPerSide.Contains(s.PagesPerSheet) ? s.PagesPerSheet : 1);
            PerSideBox.IsEnabled = state.PagesPerSideEnabled;
            PerSideBox.ToolTip = state.PagesPerSideReason;
            Show(PerSideReasonRow, PerSideReasonText, state.PagesPerSideReason);
            OrientationGroup.Visibility = state.ShowOrientation ? Visibility.Visible : Visibility.Collapsed;
            Select(OrientationBox, s.Orientation);
            BookletBox.IsChecked = s.Booklet;
            BookletBox.IsEnabled = state.BookletEnabled;
            BookletBox.ToolTip = state.BookletEnabled ? "Two pages on each side, in the order that folds into a booklet" : ShortText.PosterPages;
            Select(PosterBox, s.Poster is >= 2 and <= 4 ? s.Poster : 0);
            PosterBox.IsEnabled = state.PosterEnabled;
            PosterBox.ToolTip = state.PosterReason;
            Show(PosterReasonRow, PosterReasonText, state.PosterReason);
            RightToLeftBox.Visibility = state.ShowRightToLeft ? Visibility.Visible : Visibility.Collapsed;
            RightToLeftBox.IsChecked = s.RightToLeft;
            BordersBox.Visibility = state.ShowBorders ? Visibility.Visible : Visibility.Collapsed;
            BordersBox.IsChecked = s.PageBorders;
            Select(ScalingBox, s.Scaling);
            ScalingBox.IsEnabled = state.ScalingEnabled;
            ScalingBox.ToolTip = state.ScalingReason;
            Show(ScalingReasonRow, ScalingReasonText, state.ScalingReason);
            ScaleRow.Visibility = state.ShowScale ? Visibility.Visible : Visibility.Collapsed;
            ScaleSlider.Value = Math.Clamp(s.Scale, 25, 400);
            ScaleText.Text = $"{s.Scale} %";
            Select(MarginBox, s.Margin);
            MarginBox.IsEnabled = state.MarginEnabled;
            MarginBox.ToolTip = state.MarginReason;
            Show(MarginReasonRow, MarginReasonText, state.MarginReason);
            MarginMmRow.Visibility = s.Margin == MarginChoice.Custom ? Visibility.Visible : Visibility.Collapsed;
            MarginMmSlider.IsEnabled = state.MarginEnabled;
            MarginMmSlider.Value = Math.Clamp(s.MarginMm, 0, MarginChoices.MaxMillimetres);
            MarginMmText.Text = $"{s.MarginMm} mm";

            // Paper
            ShowPaper(s);
            Show(PaperNoteRow, PaperNoteText, state.PaperNote);
            ShowMedia(s);
            Select(QualityBox, state.QualityEnabled ? s.Quality : QualityChoice.Normal);
            QualityBox.IsEnabled = state.QualityEnabled;
            QualityBox.ToolTip = state.QualityReason;
            Show(QualityReasonRow, QualityReasonText, state.QualityReason);
            var shownColor = state.ColorEnabled ? s.Color : ColorChoice.Gray;
            ColorColor.IsChecked = shownColor == ColorChoice.Color;
            ColorGray.IsChecked = shownColor == ColorChoice.Gray;
            ColorTrack.IsEnabled = state.ColorEnabled;
            ColorTrack.ToolTip = state.ColorReason;
            Show(ColorReasonRow, ColorReasonText, state.ColorReason);

            // Photos
            Select(PhotoSizeBox, s.PhotoSizeId);
            PhotoSizeBox.IsEnabled = state.PhotoSizeEnabled;
            PhotoSizeBox.ToolTip = state.PhotoSizeReason;
            Show(PhotoSizeReasonRow, PhotoSizeReasonText, state.PhotoSizeReason);
            PhotoFillBox.IsChecked = s.PhotoFill;
            CutMarksBox.IsChecked = s.CutMarks;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }

        LayoutSection.Visibility = state.ShowLayout ? Visibility.Visible : Visibility.Collapsed;
        PhotosSection.Visibility = state.ShowPhotos ? Visibility.Visible : Visibility.Collapsed;
        SyncInspectorSections();
        SyncPrintButton();
    }

    /// <summary>A reason row under its control: shown with the text, or hidden when there is none.</summary>
    private static void Show(FrameworkElement row, TextBlock text, string? reason)
    {
        text.Text = reason ?? "";
        row.Visibility = reason is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>The settings from the controls, after the user changed one.</summary>
    private void Setting_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded || _inspector is not { } state) return;
        var s = ViewModel.Settings;
        if (CopiesBox.SelectedItem is int copies) s.Copies = copies;
        s.Collate = CollateBox.IsChecked == true;
        if (TagOf<PageSelection?>(PageSelectionBox) is { } selection) s.PageSelection = selection;
        s.ReverseOrder = ReverseBox.IsChecked == true;
        if (state.ShowOrientation && TagOf<SheetOrientation?>(OrientationBox) is { } orientation) s.Orientation = orientation;
        if (state.SidesEnabled && state.ShowSides)
        {
            s.Sides = SidesLong.IsChecked == true ? Sides.LongEdge : SidesShort.IsChecked == true ? Sides.ShortEdge : Sides.OneSided;
        }
        if (state.PagesPerSideEnabled && TagOf<int>(PerSideBox) is { } perSide and > 0) s.PagesPerSheet = perSide;
        if (state.BookletEnabled) s.Booklet = BookletBox.IsChecked == true;
        if (state.PosterEnabled && TagOf<int?>(PosterBox) is { } poster) s.Poster = poster;
        s.RightToLeft = RightToLeftBox.IsChecked == true;
        s.PageBorders = BordersBox.IsChecked == true;
        if (state.ScalingEnabled && TagOf<Scaling?>(ScalingBox) is { } scaling) s.Scaling = scaling;
        if (state.MarginEnabled && TagOf<MarginChoice?>(MarginBox) is { } margin) s.Margin = margin;
        if (TagOf<string>(PaperBox) is { } paper)
        {
            s.PaperId = paper == PaperSizes.CustomId ? PaperSizes.StartCustom(ViewModel.SelectedCapabilities, s.PaperId, Region) : paper;
        }
        if (TrayRow.Visibility == Visibility.Visible && TagOf<string>(TrayBox) is { } tray) s.MediaSource = tray;
        if (PaperTypeRow.Visibility == Visibility.Visible && TagOf<string>(PaperTypeBox) is { } paperType) s.MediaType = paperType;
        if (state.QualityEnabled && TagOf<QualityChoice?>(QualityBox) is { } quality) s.Quality = quality;
        if (state.ColorEnabled) s.Color = ColorGray.IsChecked == true ? ColorChoice.Gray : ColorChoice.Color;
        if (state.PhotoSizeEnabled && TagOf<string>(PhotoSizeBox) is { } photo) s.PhotoSizeId = photo;
        s.PhotoFill = PhotoFillBox.IsChecked == true;
        s.CutMarks = CutMarksBox.IsChecked == true;
        ViewModel.SettingsEdited();
    }

    private void ScaleSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.Settings.Scale = (int)e.NewValue;
        ScaleText.Text = $"{(int)e.NewValue} %";
        ViewModel.SettingsEdited();
    }

    private void MarginMmSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.Settings.MarginMm = (int)e.NewValue;
        MarginMmText.Text = $"{(int)e.NewValue} mm";
        ViewModel.SettingsEdited();
    }

    private void PageRangeBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        ViewModel.SetPageRange(PageRangeBox.Text);
    }

    // MARK: - Summaries and the Print button

    /// <summary>Each collapsed header's summary, accent dot and accessible name.</summary>
    private void SyncInspectorSections()
    {
        if (_sections.Count == 0) return;
        var s = ViewModel.Settings;
        foreach (var section in _sections)
        {
            string summary = InspectorSections.Summary(section.Id, s);
            bool changed = summary.Length > 0 && section.Id != InspectorSections.Photos;
            bool collapsed = !section.Expander.IsExpanded;
            section.Summary.Text = summary;
            section.Summary.Visibility = collapsed && summary.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            section.Dot.Visibility = collapsed && changed ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetName(section.Expander, InspectorSections.HeaderName(section.Id, s));
        }
    }

    /// <summary>Print says what it does; greyed out, its tooltip says why.</summary>
    private void SyncPrintButton()
    {
        string label = ViewModel.PrintLabel;
        string? reason = ViewModel.PrintDisabledReason;
        PrintButton.Content = "_" + label;
        PrintButton.IsEnabled = reason is null;
        string? trouble = ViewModel.PrinterTrouble;
        PrintButton.ToolTip = reason ?? (trouble is null ? "Print (Ctrl+P)" : $"{trouble}. Print (Ctrl+P)");
        AutomationProperties.SetName(PrintButton, reason is null ? (trouble is null ? label : $"{label}, {trouble}") : $"{label}, not available: {reason}");

        string? saveReason = ViewModel.SavePdfDisabledReason;
        SavePdfButton.IsEnabled = saveReason is null;
        SavePdfButton.ToolTip = saveReason ?? "Save the sheets as a PDF (Ctrl+Shift+S)";
    }
}
