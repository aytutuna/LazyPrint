using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using LazyPrint.App.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

public partial class MainWindow : Window
{
    /// <summary>How often the spooler is asked for its queues while the window is open.</summary>
    private static readonly TimeSpan PrinterPollInterval = TimeSpan.FromSeconds(5);

    /// <summary>How often network printers are asked for their state, problems and supplies while the window is open.</summary>
    private static readonly TimeSpan StatusPollInterval = TimeSpan.FromSeconds(30);

    public AppViewModel ViewModel { get; }

    private bool _updatingUi;
    private readonly DispatcherTimer _printerPoll = new() { Interval = PrinterPollInterval };
    private readonly DispatcherTimer _statusPoll = new() { Interval = StatusPollInterval };

    public MainWindow()
    {
        InitializeComponent();
        var demo = new DemoPrinterState();
        var sheets = new RoutingSheetPrinter(new SpoolerPrinter(_loader), new IppSheetPrinter(_loader, _loader), new DemoPrinter(_loader, demo));
        ViewModel = new AppViewModel(new WindowsPrinters(), _loader, sheets, new WindowsSystemDiagnostics(), demo: demo,
                                     network: new NetworkPrinters(), logDirectory: AppViewModel.DefaultLogDirectory);
        ViewModel.ConfirmCertificate = ConfirmCertificate;
        ViewModel.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(RefreshFromViewModel);

        PrinterList.ItemsSource = ViewModel.Printers;
        PrinterBox.ItemsSource = ViewModel.Printers;
        JobList.ItemsSource = _jobRows;

        SetUpPhone();
        SetUpPreview();
        BuildChoices();
        SetUpInspectorSections();
        Placeholders.Attach(PageRangeBox, PageRangePlaceholder);

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            UpdatePane();
            _ = ViewModel.RefreshPrintersAsync();
            _ = ViewModel.ReadSystemStateAsync();
            ViewModel.StartNetwork();
            ViewModel.StartCompanionIfPaired();
            _ = Task.Run(FileAssociation.RegisterForCurrentUser);
            _printerPoll.Tick += async (_, _) => await ViewModel.RefreshPrintersAsync();
            _printerPoll.Start();
            _statusPoll.Tick += async (_, _) => await ViewModel.RefreshNetworkStatusAsync();
            _statusPoll.Start();
            if (App.StartupFiles.Count > 0) OpenFiles(App.StartupFiles);
            else if (ViewModel.Documents.Count == 0) EmptyAddFilesButton.Focus();
        };
        // A printer added or removed while the app was in the background (in Windows Settings, say)
        // is seen when the window is back in front.
        Activated += (_, _) =>
        {
            if (IsLoaded) _ = ViewModel.RefreshPrintersAsync();
        };
        Closed += (_, _) =>
        {
            _printerPoll.Stop();
            _statusPoll.Stop();
            ViewModel.Shutdown();
        };
        SizeChanged += (_, _) => UpdatePane();
    }

    // MARK: - Side pane (full width, or an icon rail in narrow windows)

    /// <summary>Below this window width the side pane folds to an icon rail, leaving room for the preview.</summary>
    private const double CompactPaneBelowWidth = 900;
    private const double PaneWidth = 216;
    private const double RailWidth = 48;

    /// <summary>The side pane shows icons only; the item templates bind to this.</summary>
    public static readonly DependencyProperty IsPaneCompactProperty = DependencyProperty.Register(
        nameof(IsPaneCompact), typeof(bool), typeof(MainWindow), new PropertyMetadata(false));

    public bool IsPaneCompact
    {
        get => (bool)GetValue(IsPaneCompactProperty);
        private set => SetValue(IsPaneCompactProperty, value);
    }

    /// <summary>Whether the window was narrow at the last layout.</summary>
    private bool _narrow;
    /// <summary>The user expanded or folded the pane with its toggle; reset when the window crosses the threshold.</summary>
    private bool? _paneCompactChoice;
    /// <summary>The pane state last applied to the controls.</summary>
    private (bool Compact, bool Narrow)? _paneApplied;

    private void PaneToggle_Click(object sender, RoutedEventArgs e)
    {
        _paneCompactChoice = !IsPaneCompact;
        UpdatePane();
    }

    private void UpdatePane()
    {
        bool narrow = ActualWidth < CompactPaneBelowWidth;
        if (narrow != _narrow)
        {
            _narrow = narrow;
            _paneCompactChoice = null;
        }
        bool compact = _paneCompactChoice ?? narrow;
        if (_paneApplied == (compact, narrow)) return;
        _paneApplied = (compact, narrow);

        IsPaneCompact = compact;
        Sidebar.Width = compact ? RailWidth : PaneWidth;
        // The toggle is offered only where the pane folds on its own.
        PaneToggleButton.Visibility = narrow ? Visibility.Visible : Visibility.Collapsed;
        string toggleText = compact ? "Show printer names" : "Hide printer names";
        PaneToggleButton.ToolTip = toggleText;
        AutomationProperties.SetName(PaneToggleButton, toggleText);
        PrintersHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        AddPrinterButton.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        UpdateEmptyPrintersHint();
        PrintersHeader.Margin = narrow ? new Thickness(0, 0, 16, 0) : new Thickness(16, 8, 16, 6);
        if (compact)
        {
            AppearanceButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Center;
            AppearanceButton.ToolTip = "Appearance: light, dark, or follow Windows";
            PhoneButton.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            PhoneButton.HorizontalContentAlignment = HorizontalAlignment.Center;
            PhoneButton.ToolTip = "Phone: print files from your phone";
        }
        else
        {
            AppearanceButton.ClearValue(ContentControl.ContentTemplateProperty);
            AppearanceButton.HorizontalContentAlignment = HorizontalAlignment.Left;
            AppearanceButton.ToolTip = "Light, dark, or follow Windows";
            PhoneButton.ClearValue(ContentControl.ContentTemplateProperty);
            PhoneButton.HorizontalContentAlignment = HorizontalAlignment.Left;
            PhoneButton.ToolTip = "Print files from your phone";
        }
    }

    /// <summary>
    /// The sidebar's empty state (the troubleshooter) while no printer but the demo printer is listed, and the header's ?
    /// button once one is, so the two are never shown together; neither in the icon rail, where the header buttons are
    /// hidden too.
    /// </summary>
    private void UpdateEmptyPrintersHint()
    {
        bool help = ViewModel.HasRealPrinters && !IsPaneCompact;
        TroubleshootButton.Visibility = help ? Visibility.Visible : Visibility.Collapsed;
        // Alone, the + sits where the ? does.
        AddPrinterButton.Margin = new Thickness(0, 4, help ? 2 : 8, 0);
        EmptyPrintersHint.Visibility = !ViewModel.HasRealPrinters && !IsPaneCompact ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Following the view model

    /// <summary>Brings every part of the window in line with the view model.</summary>
    private void RefreshFromViewModel()
    {
        SyncPrinterList();
        SyncBars();
        SyncPhoneBar();
        SyncStatusLine();
        SyncBanner();
        PushSettingsToUi();
        UpdateEmptyPrintersHint();
        SyncJobs();
        SyncDuplexCard();
        SyncDocuments();
    }

    /// <summary>The sidebar and the inspector's picker select the printer in use.</summary>
    private void SyncPrinterList()
    {
        var selected = ViewModel.Printers.FirstOrDefault(row => row.Id == ViewModel.SelectedPrinter?.Id);
        bool wasUpdating = _updatingUi;
        _updatingUi = true;
        try
        {
            if (!ReferenceEquals(PrinterList.SelectedItem, selected)) PrinterList.SelectedItem = selected;
            if (!ReferenceEquals(PrinterBox.SelectedItem, selected)) PrinterBox.SelectedItem = selected;
        }
        finally
        {
            _updatingUi = wasUpdating;
        }
    }

    private async void PrinterList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || PrinterList.SelectedItem is not PrinterRow row) return;
        await ViewModel.SelectPrinterAsync(row.Id);
    }

    private async void PrinterBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingUi || PrinterBox.SelectedItem is not PrinterRow row) return;
        await ViewModel.SelectPrinterAsync(row.Id);
    }

    // MARK: - Bars

    /// <summary>The error bar and the bar after a job, from what the view model holds.</summary>
    private void SyncBars()
    {
        if (ViewModel.ErrorMessage is { } message)
        {
            bool notice = ViewModel.ErrorIsNotice;
            InfoBarTitle.Text = ViewModel.ErrorTitle ?? "Couldn't print";
            InfoBarMessage.Text = message;
            InfoBarGlyph.Text = notice ? "" : "";
            InfoBarGlyph.SetResourceReference(TextBlock.ForegroundProperty,
                notice ? "TextFillColorSecondaryBrush" : "SystemFillColorCriticalBrush");
            InfoBarTroubleshootButton.Visibility = ViewModel.ErrorSuggestsTroubleshooter ? Visibility.Visible : Visibility.Collapsed;
            if (InfoBar.Visibility != Visibility.Visible || _errorShown != message)
            {
                _errorShown = message;
                InfoBar.Visibility = Visibility.Visible;
                Announce(InfoBarText);
            }
        }
        else
        {
            _errorShown = null;
            InfoBar.Visibility = Visibility.Collapsed;
        }

        if (ViewModel.SentMessage is { } sent)
        {
            SentBarMessage.Text = sent;
            if (SentBar.Visibility != Visibility.Visible || _sentShown != sent)
            {
                _sentShown = sent;
                SentBar.Visibility = Visibility.Visible;
                Announce(SentBarText);
            }
        }
        else
        {
            _sentShown = null;
            SentBar.Visibility = Visibility.Collapsed;
        }

        SentJobsButton.Visibility = JobsTab.IsSelected ? Visibility.Collapsed : Visibility.Visible;
        BusyBar.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = ViewModel.IsBusy ? Visibility.Visible : Visibility.Collapsed;
    }

    private string? _errorShown;
    private string? _sentShown;

    /// <summary>Tells screen readers a bar's text changed.</summary>
    private static void Announce(TextBlock text)
    {
        var peer = UIElementAutomationPeer.FromElement(text) ?? UIElementAutomationPeer.CreatePeerForElement(text);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void InfoBarClose_Click(object sender, RoutedEventArgs e) => ViewModel.DismissError();

    private void SentBarClose_Click(object sender, RoutedEventArgs e) => ViewModel.DismissSent();

    private void SentJobs_Click(object sender, RoutedEventArgs e) => MainTabs.SelectedItem = JobsTab;

    // MARK: - Tasks and tabs

    /// <summary>
    /// A task was picked: its settings are applied, and a task that starts with files asks for them. The test page
    /// prints at once, and its result shows in the bars.
    /// </summary>
    private async void StartTask(PrintTask task)
    {
        await ViewModel.StartTaskAsync(task);
        if (ViewModel.SelectedTask == task && TaskCatalog.Definition(task).OpensFiles)
        {
            OpenSectionFor(task);
            MainTabs.SelectedItem = PrintTab;
            // A task starts by asking for files, unless some are there already; cancelling leaves the empty print screen.
            if (ViewModel.Documents.Count == 0) _ = Dispatcher.BeginInvoke(AskForFiles, DispatcherPriority.Background);
        }
    }

    private void MainTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // The tab control's own selection events bubble up from the lists inside it.
        if (!ReferenceEquals(e.OriginalSource, MainTabs)) return;
        SentJobsButton.Visibility = JobsTab.IsSelected ? Visibility.Collapsed : Visibility.Visible;
        if (PrintTab.IsSelected) PushSettingsToUi();
    }

    /// <summary>The banner above the sheet preview: the Task menu, and the task in use if there is one.</summary>
    private void SyncBanner()
    {
        TaskButton.IsEnabled = !ViewModel.IsBusy;
        var visibility = ViewModel.SelectedTask is null ? Visibility.Collapsed : Visibility.Visible;
        TaskBannerGlyph.Visibility = visibility;
        TaskBannerText.Visibility = visibility;
        ExitTaskButton.Visibility = visibility;
        if (ViewModel.SelectedTask is not { } task)
        {
            AutomationProperties.SetName(TaskBannerGroup, "Task");
            return;
        }
        var definition = TaskCatalog.Definition(task);
        TaskBannerGlyph.Text = TaskIcons.Glyph(definition.IconKey);
        TaskBannerTitle.Text = definition.Title;
        TaskBannerPrompt.Text = definition.Subtitle;
        AutomationProperties.SetName(TaskBannerGroup, $"Task: {definition.Title}");
    }

    private void TaskButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = TaskButton,
            Placement = PlacementMode.Bottom,
        };
        var tasks = TaskCatalog.Tasks(AppPlatform.Windows);
        foreach (var group in TaskGroups.All)
        {
            var definitions = tasks.Where(d => d.Group == group).ToList();
            if (definitions.Count == 0) continue;
            if (menu.Items.Count > 0) menu.Items.Add(new Separator());
            foreach (var definition in definitions)
            {
                var availability = ViewModel.AvailabilityOf(definition.Task);
                var item = new MenuItem
                {
                    Header = definition.Title,
                    IsCheckable = true,
                    IsChecked = ViewModel.SelectedTask == definition.Task,
                    IsEnabled = availability.IsAvailable,
                    InputGestureText = availability.IsAvailable ? "" : availability.Reason,
                    ToolTip =availability.Reason ?? definition.Subtitle,
                };
                ToolTipService.SetShowOnDisabled(item, true);
                item.Click += (_, _) => StartTask(definition.Task);
                menu.Items.Add(item);
            }
        }
        menu.IsOpen = true;
    }

    private void ExitTask_Click(object sender, RoutedEventArgs e) => ViewModel.ClearTask();

    // MARK: - Printing

    private async void Print_Click(object sender, RoutedEventArgs e) => await ViewModel.PrintAsync();

    private void Cancel_Click(object sender, RoutedEventArgs e) => ViewModel.CancelJob();

    // MARK: - Dialogs and menus

    /// <summary>"Why isn't my printer listed?": the troubleshooter, from the sidebar and from an error about a printer. It follows the app while open.</summary>
    private void Troubleshoot_Click(object sender, RoutedEventArgs e)
    {
        if (sender == InfoBarTroubleshootButton) ViewModel.DismissError();
        new TroubleshooterWindow(ViewModel) { Owner = this }.ShowDialog();
    }

    /// <summary>"Add printer by address": the dialog checks and adds it; it is then selected.</summary>
    private async void AddPrinter_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Network is not { } network) return;
        var dialog = new AddPrinterWindow(network) { Owner = this };
        if (dialog.ShowDialog() == true && dialog.Address is { } address) await ViewModel.SelectAddedAsync(address);
    }

    /// <summary>
    /// Asked when the user chooses or prints to a network printer whose certificate is new or has changed since it was
    /// trusted.
    /// </summary>
    private Task<bool> ConfirmCertificate(IppCertificateException certificate)
    {
        var dialog = new CertificateTrustWindow(certificate, CertificateTrustWindow.ConnectAction);
        if (IsVisible) dialog.Owner = this;
        return Task.FromResult(dialog.ShowDialog() == true);
    }

    private void AppearanceButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = AppearanceButton,
            Placement = PlacementMode.Top,
        };
        foreach (var (appearance, label) in new[]
        {
            (AppAppearance.System, "Use system setting"),
            (AppAppearance.Light, "Light"),
            (AppAppearance.Dark, "Dark"),
        })
        {
            var item = new MenuItem
            {
                Header = label,
                IsCheckable = true,
                IsChecked = ThemeService.Appearance == appearance,
            };
            item.Click += (_, _) => ThemeService.Set(appearance);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }
}
