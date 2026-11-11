using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
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
    private const int HighestPreviewDpi = 300;

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

    private void StageHost_SizeChanged(object sender, SizeChangedEventArgs e) => SchedulePreview();

    // MARK: - The sheet

    private async Task UpdatePreviewAsync()
    {
        var plan = ViewModel.Plan();
        if (plan is null || plan.Plan.Sheets.Count == 0)
        {
            _previewKey = null;
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
        int dpi = PreviewDpi(area.Paper);
        var documents = ViewModel.Documents.ToList();
        bool marks = ViewModel.DrawsCutMarks;
        bool gray = ViewModel.Settings.Color == ColorChoice.Gray;
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

    /// <summary>The resolution that fills the stage with the sheet on this screen, in steps so a small resize draws nothing.</summary>
    private int PreviewDpi(LayoutSize paper)
    {
        double width = StageHost.ActualWidth - 2 * StagePadding, height = StageHost.ActualHeight - 2 * StagePadding;
        if (width <= 0 || height <= 0) return 96;
        // Device pixels the sheet gets on the stage, over its width in inches.
        double scale = Math.Min(width / paper.Width, height / paper.Height) * VisualTreeHelper.GetDpi(this).DpiScaleX;
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
        for (int i = 0; i < _cards.Count; i++) _cards[i].SetPosition(i, _cards.Count);

        bool any = documents.Count > 0;
        DocumentStrip.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmptyStage.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        int pages = ViewModel.PageCount;
        DocumentStripLabel.Text = $"{documents.Count} document{(documents.Count == 1 ? "" : "s")} · {pages} page{(pages == 1 ? "" : "s")}";
        AddFilesButton.IsEnabled = EmptyAddFilesButton.IsEnabled = !ViewModel.IsBusy;
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

    private void DocumentRemove_Click(object sender, RoutedEventArgs e)
    {
        if (CardOf(sender) is { } card) ViewModel.RemoveDocument(card.Document);
    }
}
