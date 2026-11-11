using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

// The print screen's middle: the sheet the settings make of the documents, drawn by SheetRenderer at screen resolution,
// the sheet and side being looked at, the plan's notes, and the strip of documents under it. The plan is made again on
// every change; the sheet is drawn again once the changes pause and only when what it shows differs.
public partial class MainWindow
{
    /// <summary>How long the preview waits for further changes before it is drawn again.</summary>
    private static readonly TimeSpan PreviewDelay = TimeSpan.FromMilliseconds(150);

    private const double StagePadding = 24;
    private const int LowestPreviewDpi = 36;
    // Three pixels to a point, as on the iPhone; a bigger zoom stretches the bitmap.
    private const int HighestPreviewDpi = 216;

    private readonly DocumentLoader _loader = new();
    private readonly DispatcherTimer _previewTimer = new() { Interval = PreviewDelay };
    private readonly System.Collections.ObjectModel.ObservableCollection<DocumentCard> _cards = [];

    /// <summary>The sheet looked at (from 0) and whether it is its back.</summary>
    private int _previewSheet;
    private bool _previewBack;
    /// <summary>What the picture on the stage was drawn from; a refresh that finds the same draws nothing.</summary>
    private PreviewKey? _previewKey;
    /// <summary>Counts the drawings started; one that finishes after a newer began is dropped.</summary>
    private int _previewVersion;

    private sealed record PreviewKey(JobPlan Plan, IReadOnlyList<LoadedDocument> Documents, int Sheet, bool Back, int Dpi, bool Marks, bool Gray)
    {
        public bool SameAs(PreviewKey? other) =>
            other is not null && Plan.Equals(other.Plan) && Sheet == other.Sheet && Back == other.Back && Dpi == other.Dpi
            && Marks == other.Marks && Gray == other.Gray && Documents.Count == other.Documents.Count
            && Documents.Zip(other.Documents).All(pair => ReferenceEquals(pair.First, pair.Second));
    }

    private void SetUpPreview()
    {
        DocumentList.ItemsSource = _cards;
        _previewTimer.Tick += (_, _) =>
        {
            _previewTimer.Stop();
            _ = UpdatePreviewAsync();
        };
    }

    /// <summary>Redraws the preview once the changes pause.</summary>
    private void SchedulePreview()
    {
        _previewTimer.Stop();
        _previewTimer.Start();
    }

    private void StageHost_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        ApplyZoom();
        SchedulePreview();
    }

    // MARK: - The sheet

    private async Task UpdatePreviewAsync()
    {
        var plan = ViewModel.Plan();
        if (plan is null || plan.Plan.Sheets.Count == 0)
        {
            _previewKey = null;
            _previewPaper = null;
            _previewVersion++;
            PreviewImage.Source = null;
            PreviewImage.Visibility = Visibility.Collapsed;
            PreviewBar.Visibility = Visibility.Collapsed;
            ShowNotes(plan);
            return;
        }

        var sheets = plan.Plan.Sheets;
        _previewSheet = Math.Clamp(_previewSheet, 0, sheets.Count - 1);
        var sheet = sheets[_previewSheet];
        if (sheet.Back is null) _previewBack = false;

        var area = plan.Plan.Area;
        _previewPaper = area.Paper;
        ApplyZoom();
        int dpi = PreviewDpi(area.Paper);
        var documents = ViewModel.Documents.ToList();
        bool marks = ViewModel.DrawsCutMarks;
        bool gray = ViewModel.Settings.Color == ColorChoice.Gray
            || ViewModel.SelectedCapabilities is { } caps && caps.PrintColorModesSupported.Contains("monochrome") && !caps.PrintColorModesSupported.Contains("color");
        SyncPreviewBar(plan);
        ShowNotes(plan);

        var key = new PreviewKey(plan, documents, _previewSheet, _previewBack, dpi, marks, gray);
        if (key.SameAs(_previewKey)) return;
        // Set before drawing: a drawing that fails is not tried again until something changes.
        _previewKey = key;

        var side = _previewBack ? sheet.Back! : sheet.Front;
        var renderer = new SheetRenderer(documents, _loader);
        var items = ViewModel.CutMarks(side, area);
        int version = ++_previewVersion;
        try
        {
            var picture = await StaWork.Run(() => renderer.Render(side, area, dpi, items));
            if (version != _previewVersion) return;
            PreviewImage.Source = gray ? Grayed(picture) : picture;
            PreviewImage.Visibility = Visibility.Visible;
            AutomationProperties.SetName(PreviewImage, $"{SheetLabel.Text}, {(_previewBack ? "back" : "front")}");
        }
        catch (Exception e)
        {
            if (version != _previewVersion) return;
            ViewModel.ShowNotice("Couldn't draw the preview", e.Message);
        }
    }

    private static BitmapSource Grayed(BitmapSource picture)
    {
        var gray = new FormatConvertedBitmap(picture, PixelFormats.Gray8, null, 0);
        gray.Freeze();
        return gray;
    }

    /// <summary>The resolution the sheet has at the zoom on this screen, in steps so a small resize draws nothing.</summary>
    private int PreviewDpi(LayoutSize paper)
    {
        double width = StageHost.ActualWidth - 2 * StagePadding, height = StageHost.ActualHeight - 2 * StagePadding;
        if (width <= 0 || height <= 0) return 96;
        // Device pixels to a point of the sheet.
        double scale = ZoomOf(paper) * DipsPerPoint * VisualTreeHelper.GetDpi(this).DpiScaleX;
        int dpi = (int)(Math.Ceiling(scale * 72 / 12) * 12);
        return Math.Clamp(dpi, LowestPreviewDpi, HighestPreviewDpi);
    }

    private void SyncPreviewBar(JobPlan plan)
    {
        var sheets = plan.Plan.Sheets;
        PreviewBar.Visibility = Visibility.Visible;
        SheetLabel.Text = $"Sheet {_previewSheet + 1} of {sheets.Count}";
        PreviousSheetButton.IsEnabled = _previewSheet > 0;
        NextSheetButton.IsEnabled = _previewSheet < sheets.Count - 1;
        FaceTrack.Visibility = sheets[_previewSheet].Back is null ? Visibility.Collapsed : Visibility.Visible;
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            FaceFront.IsChecked = !_previewBack;
            FaceBack.IsChecked = _previewBack;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    private void ShowNotes(JobPlan? plan)
    {
        var notes = plan?.Notes ?? [];
        if (PlanNotes.ItemsSource is IReadOnlyList<string> shown && shown.SequenceEqual(notes)) return;
        PlanNotes.ItemsSource = notes;
        PlanNotes.Visibility = notes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void PreviousSheet_Click(object sender, RoutedEventArgs e) => LookAt(_previewSheet - 1);

    private void NextSheet_Click(object sender, RoutedEventArgs e) => LookAt(_previewSheet + 1);

    private void LookAt(int sheet)
    {
        _previewSheet = Math.Max(0, sheet);
        _ = UpdatePreviewAsync();
    }

    private void Face_Changed(object sender, RoutedEventArgs e)
    {
        if (_updatingUi || !IsLoaded) return;
        _previewBack = FaceBack.IsChecked == true;
        _ = UpdatePreviewAsync();
    }

    // MARK: - Zoom

    /// <summary>The sheet's points are 1/72 inch, WPF's units 1/96.</summary>
    private const double DipsPerPoint = 96.0 / 72;
    private const double ZoomStep = 1.25;
    private const double MaxZoom = 8;

    /// <summary>The zoom as a fraction of the sheet's real size; null fits the sheet to the stage.</summary>
    private double? _zoom;
    /// <summary>The paper of the sheet on the stage; null while there is none.</summary>
    private LayoutSize? _previewPaper;
    private Point? _panFrom;
    private double _panHorizontal;
    private double _panVertical;

    private double FitZoom(LayoutSize paper)
    {
        double width = StageHost.ActualWidth - 2 * StagePadding, height = StageHost.ActualHeight - 2 * StagePadding;
        if (width <= 0 || height <= 0) return 1;
        return Math.Min(width / (paper.Width * DipsPerPoint), height / (paper.Height * DipsPerPoint));
    }

    private double ZoomOf(LayoutSize paper) => _zoom ?? FitZoom(paper);

    /// <summary>Sizes the sheet for the zoom and says so on the bar. The bitmap behind it is drawn again at the new size once the changes pause.</summary>
    private void ApplyZoom()
    {
        if (_previewPaper is not { } paper) return;
        // A stage that grew past the zoom goes back to fitting, so the sheet is never smaller than the fit.
        if (_zoom <= FitZoom(paper) * 1.001) _zoom = null;
        double zoom = ZoomOf(paper);
        PreviewImage.Width = Math.Floor(paper.Width * DipsPerPoint * zoom);
        PreviewImage.Height = Math.Floor(paper.Height * DipsPerPoint * zoom);
        ZoomFitButton.Content = $"{Math.Round(zoom * 100)}%";
        ZoomOutButton.IsEnabled = _zoom is not null;
        ZoomInButton.IsEnabled = zoom < MaxZoom;
    }

    /// <summary>Zooms by a factor around a point of the stage (the middle by default); out past the fit goes back to fitting.</summary>
    private void ZoomBy(double factor, Point? around = null)
    {
        if (_previewPaper is not { } paper) return;
        double fit = FitZoom(paper);
        double next = Math.Min(Math.Max(ZoomOf(paper) * factor, fit), Math.Max(MaxZoom, fit));
        SetZoom(next <= fit * 1.001 ? null : next, around);
    }

    private void SetZoom(double? zoom, Point? around = null)
    {
        var at = around ?? new Point(PreviewScroller.ViewportWidth / 2, PreviewScroller.ViewportHeight / 2);
        // Where the point sits on the sheet, as a fraction of it, whether or not the sheet was scrolling.
        var on = PreviewScroller.TranslatePoint(at, PreviewImage);
        double x = PreviewImage.ActualWidth > 0 ? Math.Clamp(on.X / PreviewImage.ActualWidth, 0, 1) : 0.5;
        double y = PreviewImage.ActualHeight > 0 ? Math.Clamp(on.Y / PreviewImage.ActualHeight, 0, 1) : 0.5;
        _zoom = zoom;
        ApplyZoom();
        PreviewScroller.UpdateLayout();
        PreviewScroller.ScrollToHorizontalOffset(PreviewImage.Margin.Left + x * PreviewImage.ActualWidth - at.X);
        PreviewScroller.ScrollToVerticalOffset(PreviewImage.Margin.Top + y * PreviewImage.ActualHeight - at.Y);
        SchedulePreview();
    }

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => ZoomBy(ZoomStep);

    private void ZoomOut_Click(object sender, RoutedEventArgs e) => ZoomBy(1 / ZoomStep);

    private void ZoomFit_Click(object sender, RoutedEventArgs e) => SetZoom(null);

    /// <summary>Ctrl with plus, minus or 0; the window's key handler asks first.</summary>
    private bool TryZoomKey(KeyEventArgs e)
    {
        var modifiers = Keyboard.Modifiers;
        if (_previewPaper is null || !PrintTab.IsSelected || Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase
            || (modifiers & ModifierKeys.Control) == 0 || (modifiers & (ModifierKeys.Alt | ModifierKeys.Windows)) != 0) return false;
        switch (e.Key)
        {
            case Key.OemPlus or Key.Add:
                ZoomBy(ZoomStep);
                return true;
            case Key.OemMinus or Key.Subtract:
                ZoomBy(1 / ZoomStep);
                return true;
            case Key.D0 or Key.NumPad0:
                SetZoom(null);
                return true;
            default:
                return false;
        }
    }

    // A trackpad's pinch arrives as Ctrl and the wheel.
    private void PreviewScroller_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0 || _previewPaper is null) return;
        ZoomBy(Math.Pow(1.1, e.Delta / 120.0), e.GetPosition(PreviewScroller));
        e.Handled = true;
    }

    private void PreviewScroller_MouseDown(object sender, MouseButtonEventArgs e)
    {
        var at = e.GetPosition(PreviewScroller);
        // The scroll bars sit outside the viewport and drag themselves.
        if (at.X >= PreviewScroller.ViewportWidth || at.Y >= PreviewScroller.ViewportHeight
            || PreviewScroller.ScrollableWidth <= 0 && PreviewScroller.ScrollableHeight <= 0) return;
        _panFrom = at;
        _panHorizontal = PreviewScroller.HorizontalOffset;
        _panVertical = PreviewScroller.VerticalOffset;
        PreviewScroller.CaptureMouse();
        PreviewScroller.Cursor = Cursors.Hand;
    }

    private void PreviewScroller_MouseMove(object sender, MouseEventArgs e)
    {
        if (_panFrom is not { } from) return;
        var at = e.GetPosition(PreviewScroller);
        PreviewScroller.ScrollToHorizontalOffset(_panHorizontal - (at.X - from.X));
        PreviewScroller.ScrollToVerticalOffset(_panVertical - (at.Y - from.Y));
    }

    private void PreviewScroller_MouseUp(object sender, MouseButtonEventArgs e) => PreviewScroller.ReleaseMouseCapture();

    private void PreviewScroller_LostCapture(object sender, MouseEventArgs e)
    {
        _panFrom = null;
        PreviewScroller.Cursor = null;
    }

    // MARK: - The documents

    /// <summary>The strip follows the view model's documents: cards come, go and move; a new card's thumbnail is drawn behind.</summary>
    private void SyncDocuments()
    {
        var documents = ViewModel.Documents;
        for (int i = 0; i < documents.Count; i++)
        {
            int at = FindCard(documents[i], i);
            if (at < 0)
            {
                var card = new DocumentCard(documents[i]);
                _cards.Insert(i, card);
                _ = LoadThumbnailAsync(card);
            }
            else if (at != i)
            {
                _cards.Move(at, i);
            }
        }
        while (_cards.Count > documents.Count) _cards.RemoveAt(_cards.Count - 1);
        for (int i = 0; i < _cards.Count; i++) _cards[i].SetPosition(i, _cards.Count, ViewModel.DocumentsLockedReason);

        bool any = documents.Count > 0;
        DocumentStrip.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmptyStage.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        int pages = ViewModel.PageCount;
        DocumentStripLabel.Text = $"{documents.Count} document{(documents.Count == 1 ? "" : "s")} · {pages} page{(pages == 1 ? "" : "s")}";
        AddFilesButton.IsEnabled = EmptyAddFilesButton.IsEnabled = ViewModel.DocumentsLockedReason is null;
        AddFilesButton.ToolTip = ViewModel.DocumentsLockedReason ?? "Add PDFs, pictures and text (Ctrl+O)";
        RecentButton.IsEnabled = EmptyRecentButton.IsEnabled = ViewModel.DocumentsLockedReason is null;
        SchedulePreview();
    }

    /// <summary>The card of the document, searching from the position it should be in; -1 when the strip has none.</summary>
    private int FindCard(LoadedDocument document, int from)
    {
        for (int i = from; i < _cards.Count; i++)
        {
            if (ReferenceEquals(_cards[i].Document, document)) return i;
        }
        return -1;
    }

    private async Task LoadThumbnailAsync(DocumentCard card)
    {
        var size = card.Document.Pages[0];
        // The card shows it at most 104 × 76 DIPs; drawn at twice that.
        double scale = 2 * Math.Min(104 / size.Width, 76 / size.Height);
        int width = Math.Max(1, (int)(size.Width * scale)), height = Math.Max(1, (int)(size.Height * scale));
        try
        {
            var thumbnail = await StaWork.Run(() => _loader.Render(card.Document, 0, null, width, height));
            card.SetThumbnail(thumbnail);
        }
        catch
        {
            // The card stays without a picture; the file may have gone, and printing will say so.
        }
    }

    private static DocumentCard? CardOf(object sender) => (sender as FrameworkElement)?.DataContext as DocumentCard;

    private void DocumentEarlier_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ViewModel.MoveDocument(card.Document, -1);
    }

    private void DocumentLater_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ViewModel.MoveDocument(card.Document, 1);
    }

    /// <summary>A card's menu holds only Lazy PDF, so a card that cannot be opened there has no menu.</summary>
    private void DocumentCard_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (CardOf(sender) is not { } card || !ViewModel.CanEditInLazyPdf(card.Document)) e.Handled = true;
    }

    private void DocumentLazyPdf_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ViewModel.EditInLazyPdf(card.Document);
    }

    private void DocumentRemove_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ViewModel.RemoveDocument(card.Document);
    }
}
