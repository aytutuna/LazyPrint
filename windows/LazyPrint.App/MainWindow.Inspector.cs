using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
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
        ScalingBox.Items.Add(Item("Shrink to fit", Scaling.ShrinkToFit, "Large pages are made smaller, the others print at real size"));
        ScalingBox.Items.Add(Item("Fit to page", Scaling.Fit, "Each page is made as large as fits"));
        ScalingBox.Items.Add(Item("Actual size", Scaling.ActualSize, "100 %; the edges the printer cannot reach are cut off"));
        ScalingBox.Items.Add(Item("Fill", Scaling.Fill, "Each page fills its space, cropped in the middle"));
        foreach (var paper in PaperSizes.DisplayOrder(RegionInfo.CurrentRegion.TwoLetterISORegionName))
        {
            PaperBox.Items.Add(Item(paper.Label(), paper, paper.Detail()));
        }
        QualityBox.Items.Add(Item("Normal", QualityChoice.Normal));
        QualityBox.Items.Add(Item("Draft", QualityChoice.Draft, "Faster, uses less ink"));
        QualityBox.Items.Add(Item("Best", QualityChoice.Best, "Slower, the finest print"));
        foreach (var photo in PhotoSize.All) PhotoSizeBox.Items.Add(Item(photo.Title, photo.Id));
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
            Show(PageRangeProblemRow, PageRangeProblemText, ViewModel.PageRangeError);
            SidesGroup.Visibility = state.ShowSides ? Visibility.Visible : Visibility.Collapsed;
            var shownSides = s.Booklet ? Sides.LongEdge : s.Sides;
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
            BookletBox.IsChecked = s.Booklet;
            RightToLeftBox.Visibility = state.ShowRightToLeft ? Visibility.Visible : Visibility.Collapsed;
            RightToLeftBox.IsChecked = s.RightToLeft;
            BordersBox.Visibility = state.ShowBorders ? Visibility.Visible : Visibility.Collapsed;
            BordersBox.IsChecked = s.PageBorders;
            Select(ScalingBox, s.Scaling);

            // Paper
            Select(PaperBox, PaperSizes.Parse(s.PaperId));
            Show(PaperNoteRow, PaperNoteText, state.PaperNote);
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
        if (state.SidesEnabled && state.ShowSides)
        {
            s.Sides = SidesLong.IsChecked == true ? Sides.LongEdge : SidesShort.IsChecked == true ? Sides.ShortEdge : Sides.OneSided;
        }
        if (state.PagesPerSideEnabled && TagOf<int>(PerSideBox) is { } perSide and > 0) s.PagesPerSheet = perSide;
        s.Booklet = BookletBox.IsChecked == true;
        s.RightToLeft = RightToLeftBox.IsChecked == true;
        s.PageBorders = BordersBox.IsChecked == true;
        if (TagOf<Scaling?>(ScalingBox) is { } scaling) s.Scaling = scaling;
        if (TagOf<PaperSize?>(PaperBox) is { } paper) s.PaperId = paper.RawValue();
        if (state.QualityEnabled && TagOf<QualityChoice?>(QualityBox) is { } quality) s.Quality = quality;
        if (state.ColorEnabled) s.Color = ColorGray.IsChecked == true ? ColorChoice.Gray : ColorChoice.Color;
        if (state.PhotoSizeEnabled && TagOf<string>(PhotoSizeBox) is { } photo) s.PhotoSizeId = photo;
        s.PhotoFill = PhotoFillBox.IsChecked == true;
        s.CutMarks = CutMarksBox.IsChecked == true;
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
        PrintButton.ToolTip = reason ?? "Print (Ctrl+P)";
        AutomationProperties.SetName(PrintButton, reason is null ? label : $"{label}, not available: {reason}");
    }
}
