using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
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
    private string _shownWidth = "", _shownHeight = "";
    private readonly DispatcherTimer _printerPoll = new() { Interval = PrinterPollInterval };
    private readonly DispatcherTimer _statusPoll = new() { Interval = StatusPollInterval };

    public MainWindow()
    {
        InitializeComponent();
        var demo = new DemoPrinterState();
        var sheets = new RoutingSheetPrinter(new SpoolerPrinter(_loader, _loader), new IppSheetPrinter(_loader, _loader), new DemoPrinter(_loader, demo));
        ViewModel = new AppViewModel(new WindowsPrinters(), _loader, sheets, new WindowsSystemDiagnostics(), demo: demo,
                                     network: new NetworkPrinters(), logDirectory: AppViewModel.DefaultLogDirectory);
        ViewModel.ConfirmCertificate = ConfirmCertificate;
        ViewModel.AskPassword = AskPassword;
        ViewModel.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(RefreshFromViewModel);

        PrinterList.ItemsSource = ViewModel.Printers;
        PrinterBox.ItemsSource = ViewModel.Printers;
        JobList.ItemsSource = _jobRows;

        SetUpPhone();
        SetUpPreview();
        SetUpQueue();
        BuildChoices();
        SetUpInspectorSections();
        Placeholders.Attach(PageRangeBox, PageRangePlaceholder);

        Loaded += (_, _) =>
        {
            PushSettingsToUi();
            UpdatePane();
            _ = ViewModel.RefreshPrintersAsync();
            _ = ViewModel.ReadSystemStateAsync();
            _ = ViewModel.RefreshLazyScanAsync();
            _ = ViewModel.RefreshLazyPdfAsync();
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
            if (!IsLoaded) return;
            _ = ViewModel.RefreshPrintersAsync();
            _ = ViewModel.RefreshLazyScanAsync();
            _ = ViewModel.RefreshLazyPdfAsync();
        };
        Closing += MainWindow_Closing;
        Closed += (_, _) =>
        {
            _printerPoll.Stop();
            _statusPoll.Stop();
            ViewModel.Shutdown();
        };
        SizeChanged += (_, _) => UpdatePane();
    }

    private bool _closeConfirmed;
    private bool _stopping;

    /// <summary>Closing asks first while a job is going out, or while a two-sided job waits for its backs.</summary>
    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_closeConfirmed) return;
        if (_stopping)
        {
            e.Cancel = true;
            return;
        }
        if (ViewModel.IsBusy && !ViewModel.JobIsInSpooler)
        {
            e.Cancel = true;
            if (MessageBox.Show(this, "A job is still being sent to the printer.", "Stop it and quit?",
                                MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) == MessageBoxResult.OK)
                _ = StopJobAndClose();
        }
        else if (ViewModel.IsWaitingForBacks)
        {
            if (MessageBox.Show(this, "Closing now leaves the two-sided job half done.", "The backs are not printed yet",
                                MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK)
                e.Cancel = true;
        }
    }

    private async Task StopJobAndClose()
    {
        _stopping = true;
        bool stopped = await ViewModel.CancelJobAndWaitAsync();
        _stopping = false;
        // The pass may have ended while the box was open; then the normal checks run again.
        _closeConfirmed = stopped;
        Close();
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
        SyncQueue();
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
        var working = ViewModel.IsBusy || ViewModel.IsAddingFiles ? Visibility.Visible : Visibility.Collapsed;
        BusyBar.Visibility = CancelButton.Visibility = working;
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
            OpenSectionFor(ViewModel.Settings);
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
        SyncQueue();
    }

    /// <summary>The banner above the sheet preview: the Preset menu, and the preset in use if there is one.</summary>
    private void SyncBanner()
    {
        // A task chosen behind the two-sided card would do nothing.
        TaskButton.IsEnabled = !ViewModel.IsBusy && ViewModel.ManualStep == DuplexStep.None;
        var visibility = ViewModel.CurrentTask is null ? Visibility.Collapsed : Visibility.Visible;
        TaskBannerGlyph.Visibility = visibility;
        TaskBannerText.Visibility = visibility;
        ExitTaskButton.Visibility = visibility;
        if (ViewModel.CurrentTask is not { } task)
        {
            AutomationProperties.SetName(TaskBannerGroup, PrintText.PresetMenu);
            return;
        }
        var definition = TaskCatalog.Definition(task);
        TaskBannerGlyph.Text = TaskIcons.Glyph(definition.IconKey);
        TaskBannerTitle.Text = definition.Title;
        TaskBannerPrompt.Text = definition.Subtitle;
        AutomationProperties.SetName(TaskBannerGroup, $"{PrintText.PresetMenu}: {definition.Title}");
    }

    /// <summary>The built-in presets, the user's own with the ways to save, rename and delete them, then the actions (test page, Lazy Scan, from phone).</summary>
    private void TaskButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = TaskButton,
            Placement = PlacementMode.Bottom,
        };
        var tasks = TaskCatalog.Tasks(AppPlatform.Windows);
        AddTaskItems(menu, tasks.Where(d => d.Group != TaskGroup.Other));
        AddPresetItems(menu);
        menu.Items.Add(new Separator());
        AddTaskItems(menu, tasks.Where(d => d.Group == TaskGroup.Other));
        menu.IsOpen = true;
    }

    private void AddTaskItems(ContextMenu menu, IEnumerable<TaskDefinition> definitions)
    {
        var shown = definitions.ToList();
        foreach (var group in TaskGroups.All)
        {
            var inGroup = shown.Where(d => d.Group == group).ToList();
            if (inGroup.Count == 0) continue;
            if (menu.Items.Count > 0 && menu.Items[^1] is not Separator) menu.Items.Add(new Separator());
            foreach (var definition in inGroup)
            {
                var availability = ViewModel.AvailabilityOf(definition.Task);
                var item = new MenuItem
                {
                    Header = definition.Title,
                    IsCheckable = true,
                    IsChecked = ViewModel.CurrentTask == definition.Task,
                    IsEnabled = availability.IsAvailable,
                    InputGestureText = availability.IsAvailable ? "" : availability.Reason,
                    ToolTip =availability.Reason ?? definition.Subtitle,
                };
                ToolTipService.SetShowOnDisabled(item, true);
                item.Click += (_, _) => StartTask(definition.Task);
                menu.Items.Add(item);
            }
        }
    }

    /// <summary>The user's presets, checked while the options still equal the one applied last, then the ways to save, rename and delete them.</summary>
    private void AddPresetItems(ContextMenu menu)
    {
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        foreach (var preset in ViewModel.Presets)
        {
            var item = new MenuItem { Header = preset.Name, IsCheckable = true, IsChecked = ViewModel.IsCurrent(preset) };
            item.Click += (_, _) => ViewModel.ApplyPreset(preset.Name);
            menu.Items.Add(item);
        }
        var save = new MenuItem { Header = PrintText.SavePresetItem };
        save.Click += (_, _) => SavePreset();
        menu.Items.Add(save);
        if (ViewModel.Presets.Count == 0) return;
        var rename = new MenuItem { Header = PrintText.RenamePresetItem };
        var delete = new MenuItem { Header = PrintText.DeletePresetItem };
        foreach (var preset in ViewModel.Presets)
        {
            var name = preset.Name;
            var renameItem = new MenuItem { Header = name };
            renameItem.Click += (_, _) => RenamePreset(name);
            rename.Items.Add(renameItem);
            var deleteItem = new MenuItem { Header = name };
            deleteItem.Click += (_, _) => DeletePreset(name);
            delete.Items.Add(deleteItem);
        }
        menu.Items.Add(rename);
        menu.Items.Add(delete);
    }

    private void DeletePreset(string name)
    {
        var answer = MessageBox.Show(this, PrintText.DeletePresetMessage, PrintText.DeletePresetTitle(name),
                                     MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.OK) ViewModel.DeletePreset(name);
    }

    /// <summary>Asks for a name and keeps the options under it; a name in use asks before it replaces that preset.</summary>
    private void SavePreset()
    {
        var dialog = new PresetNameWindow(PrintText.SavePresetTitle, "", name =>
        {
            var check = UserPresets.Check(name, ViewModel.Presets);
            return check == PresetNameCheck.Exists ? PresetNameCheck.Ok : check;
        });
        if (IsVisible) dialog.Owner = this;
        if (dialog.ShowDialog() != true) return;
        if (ViewModel.SavePreset(dialog.PresetName) != PresetNameCheck.Exists) return;
        var answer = MessageBox.Show(this, PrintText.ReplacePresetMessage, PrintText.ReplacePresetTitle(dialog.PresetName),
                                     MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer == MessageBoxResult.OK) ViewModel.SavePreset(dialog.PresetName, replace: true);
    }

    private void RenamePreset(string name)
    {
        var dialog = new PresetNameWindow(PrintText.RenamePresetTitle, name,
            typed => UserPresets.Check(typed, ViewModel.Presets, renaming: name));
        if (IsVisible) dialog.Owner = this;
        if (dialog.ShowDialog() == true) ViewModel.RenamePreset(name, dialog.PresetName);
    }

    private void ExitTask_Click(object sender, RoutedEventArgs e) => ViewModel.ClearTask();

    // MARK: - Printing

    private async void Print_Click(object sender, RoutedEventArgs e) => await ViewModel.PrintAsync();

    private async void SavePdf_Click(object sender, RoutedEventArgs e) => await SavePdfAsync();

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.IsBusy) ViewModel.CancelJob();
        else ViewModel.CancelLoad();
    }

    // MARK: - Keyboard shortcuts

    /// <summary>Ctrl+O adds files, Ctrl+P prints, Ctrl+Shift+S saves a PDF, Ctrl+V pastes files and Delete removes the focused document. Paste and Delete are left to a text box.</summary>
    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (ViewModel.ManualStep != DuplexStep.None) return;
        bool typing = Keyboard.FocusedElement is TextBoxBase;
        bool ctrl = Keyboard.Modifiers == ModifierKeys.Control;
        if (e.Key == Key.Escape)
        {
            // A menu, a flyout or an open list takes Esc to close itself; only otherwise does it stop the work.
            bool closing = Keyboard.FocusedElement is System.Windows.Media.Visual focused && PresentationSource.FromVisual(focused) != PresentationSource.FromVisual(this)
                || Keyboard.FocusedElement is ComboBox { IsDropDownOpen: true };
            if (!closing && CancelButton.Visibility == Visibility.Visible && CancelButton.IsEnabled)
            {
                Cancel_Click(CancelButton, e);
                e.Handled = true;
            }
        }
        else if (ctrl && e.Key == Key.O)
        {
            AskForFiles();
            e.Handled = true;
        }
        else if (ctrl && e.Key == Key.P && PrintTab.IsSelected && ViewModel.CanPrint)
        {
            _ = ViewModel.PrintAsync();
            e.Handled = true;
        }
        else if (Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && e.Key == Key.S && PrintTab.IsSelected)
        {
            _ = SavePdfAsync();
            e.Handled = true;
        }
        else if (ctrl && e.Key == Key.V && !typing)
        {
            e.Handled = PasteFiles();
        }
        else if (TryZoomKey(e))
        {
            e.Handled = true;
        }
        else if (e.Key == Key.Delete && Keyboard.Modifiers == ModifierKeys.None && !typing && CardOf(Keyboard.FocusedElement) is { } card)
        {
            ViewModel.RemoveDocument(card.Document);
            e.Handled = true;
        }
    }

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

    private Task<string?> AskPassword(string name, bool wrong)
    {
        var dialog = new PasswordWindow(name, wrong);
        if (IsVisible) dialog.Owner = this;
        return Task.FromResult(dialog.ShowDialog() == true ? dialog.Password : null);
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
