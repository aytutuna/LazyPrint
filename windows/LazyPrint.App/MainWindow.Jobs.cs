using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

// The Jobs tab and the demo printer's menu.
public partial class MainWindow
{
    private readonly ObservableCollection<JobRow> _jobRows = [];

    /// <summary>The rows follow the view model's records, newest first, each updated in place.</summary>
    private void SyncJobs()
    {
        var records = ViewModel.Jobs;
        for (int i = 0; i < records.Count; i++)
        {
            string? folder = ViewModel.DemoFolderOf(records[i].Id);
            int at = _jobRows.ToList().FindIndex(row => row.Id == records[i].Id);
            if (at < 0)
            {
                _jobRows.Insert(i, new JobRow(records[i], folder));
            }
            else
            {
                if (at != i) _jobRows.Move(at, i);
                _jobRows[i].Update(records[i], folder);
            }
        }
        for (int i = _jobRows.Count - 1; i >= records.Count; i--) _jobRows.RemoveAt(i);
        EmptyJobs.Visibility = records.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static JobRow? RowOf(object sender) => (sender as FrameworkElement)?.DataContext as JobRow;

    private void JobCancel_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) ViewModel.CancelJob(row.Id);
    }

    private async void JobAgain_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) await ViewModel.PrintAgainAsync(row.Id);
    }

    private void JobFolder_Click(object sender, RoutedEventArgs e)
    {
        if (RowOf(sender) is { } row) ViewModel.ShowDemoFolder(row.Id);
    }

    private static ListBoxItem? RowItemOf(DependencyObject? element)
    {
        while (element is not null and not ListBoxItem) element = VisualTreeHelper.GetParent(element);
        return element as ListBoxItem;
    }

    /// <summary>
    /// Right-click, or the menu key, on the demo printer's row: a switch for printing both sides and "Out of paper", to try
    /// the troubleshooter and the two-sided card. Other printers have no menu. The menu is opened here, at the list, because
    /// a row's own menu would have to exist before the event reaches it.
    /// </summary>
    private void PrinterList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        // The mouse says which row it is over; the keyboard (no cursor position) means the selected one.
        var item = e.CursorLeft < 0
            ? PrinterList.ItemContainerGenerator.ContainerFromItem(PrinterList.SelectedItem) as ListBoxItem
            : RowItemOf(e.OriginalSource as DependencyObject);
        if (item?.DataContext is not PrinterRow { Info.Route: PrinterRoute.Demo })
        {
            e.Handled = true;
            return;
        }
        var duplex = new MenuItem { Header = "Prints both sides", IsCheckable = true, IsChecked = ViewModel.Demo.Duplex };
        duplex.Click += async (_, _) => await ViewModel.SetDemoDuplexAsync(duplex.IsChecked);
        var outOfPaper = new MenuItem { Header = "Out of paper", IsCheckable = true, IsChecked = ViewModel.Demo.OutOfPaper };
        outOfPaper.Click += (_, _) => ViewModel.SetDemoOutOfPaper(outOfPaper.IsChecked);
        new ContextMenu
        {
            Items = { duplex, outOfPaper },
            PlacementTarget = item,
            // From the keyboard the menu hangs from the row, not from wherever the mouse happens to be.
            Placement = e.CursorLeft < 0 ? PlacementMode.Bottom : PlacementMode.MousePoint,
            IsOpen = true,
        };
        e.Handled = true;
    }

    // MARK: - The printer's queue

    private static readonly TimeSpan QueueEvery = TimeSpan.FromSeconds(4);

    private readonly PrinterQueue _printerQueue = new();
    private readonly DispatcherTimer _queueTimer = new() { Interval = QueueEvery };
    private readonly ObservableCollection<QueueRow> _queueRows = [];
    /// <summary>The printer whose queue is on show; null while the section is not being kept fresh.</summary>
    private string? _queuePrinterId;
    private bool _queueReading;

    private void SetUpQueue()
    {
        QueueList.ItemsSource = _queueRows;
        _queueTimer.Tick += (_, _) => _ = RefreshQueueAsync();
    }

    /// <summary>The section shows for a printer that has a queue; it is read every few seconds while the Jobs tab is in front.</summary>
    private void SyncQueue()
    {
        var printer = ViewModel.SelectedPrinter;
        bool has = printer is not null && PrinterQueue.Has(printer);
        QueueSection.Visibility = has ? Visibility.Visible : Visibility.Collapsed;
        if (printer is null || !has || !JobsTab.IsSelected)
        {
            _queueTimer.Stop();
            _queuePrinterId = null;
            return;
        }
        if (_queuePrinterId != printer.Id)
        {
            _queuePrinterId = printer.Id;
            _queueRows.Clear();
            QueueNote.Text = "";
            _ = RefreshQueueAsync();
        }
        if (!_queueTimer.IsEnabled) _queueTimer.Start();
    }

    private async Task RefreshQueueAsync()
    {
        if (_queueReading || ViewModel.SelectedPrinter is not { } printer || _queuePrinterId != printer.Id
            || WindowState == WindowState.Minimized) return;
        _queueReading = true;
        try
        {
            var jobs = await _printerQueue.JobsAsync(printer, CancellationToken.None);
            if (_queuePrinterId != printer.Id) return;
            if (!_queueRows.Select(row => row.Job).SequenceEqual(jobs))
            {
                _queueRows.Clear();
                foreach (var job in jobs) _queueRows.Add(new QueueRow(job));
            }
            QueueNote.Text = jobs.Count == 0 ? PrintText.QueueEmpty : "";
        }
        catch (Exception)
        {
            if (_queuePrinterId != printer.Id) return;
            _queueRows.Clear();
            QueueNote.Text = PrintText.QueueUnreadable;
        }
        finally
        {
            _queueReading = false;
        }
    }

    private async void QueueCancel_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not QueueRow row || ViewModel.SelectedPrinter is not { } printer) return;
        try
        {
            await _printerQueue.CancelAsync(printer, row.Job.Id, CancellationToken.None);
        }
        catch (Exception ex)
        {
            ViewModel.ShowNotice("Couldn't cancel the job", ex.Message);
        }
        await RefreshQueueAsync();
    }
}
