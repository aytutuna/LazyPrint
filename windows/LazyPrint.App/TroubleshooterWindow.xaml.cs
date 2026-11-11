using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// "Why isn't my printer listed?": the troubleshooter's checks (<see cref="Troubleshooter.Diagnose"/>),
/// one card each with its status, what it means and the buttons that help (Refresh, Add printer
/// by address, the Windows Settings pages, and for stuck jobs and a paused printer, after asking, Clear
/// stuck jobs and Resume printer), and Copy diagnostics. It follows the app: the checks are made again
/// whenever the printer list or the view model changes. The Settings buttons open Windows Settings, where
/// the user decides.
/// </summary>
public partial class TroubleshooterWindow : Window
{
    /// <summary>How long a Refresh waits for printers to answer before the checks are made again.</summary>
    internal static readonly TimeSpan RefreshSettleTime = TimeSpan.FromSeconds(3);

    private readonly AppViewModel _viewModel;
    private readonly DispatcherTimer _updateTimer;
    private readonly DispatcherTimer _statusTimer;
    private IReadOnlyList<TroubleshootCheck> _shownChecks = [];
    private int _refreshes;

    /// <summary>The snapshot the cards show (Copy diagnostics copies it).</summary>
    internal PrinterSnapshot Snapshot { get; private set; } = new();

    /// <summary>
    /// Opens "Add printer by address" over this window; returns whether one was added (replaced in harnesses).
    /// </summary>
    internal Func<bool> AddPrinter { get; set; }

    /// <summary>
    /// Asks before something is changed (clearing jobs, resuming a printer); true to go ahead (replaced in harnesses).
    /// </summary>
    internal Func<string, string, bool> Confirm { get; set; }

    public TroubleshooterWindow(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        AddPrinter = ShowAddPrinterDialog;
        Confirm = AskInDialog;
        _updateTimer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(400) };
        _updateTimer.Tick += async (_, _) =>
        {
            _updateTimer.Stop();
            await UpdateAsync();
        };
        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        _statusTimer.Tick += (_, _) =>
        {
            _statusTimer.Stop();
            FooterStatus.Text = "";
        };
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        _viewModel.Printers.CollectionChanged += Printers_CollectionChanged;
        Closed += (_, _) =>
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
            _viewModel.Printers.CollectionChanged -= Printers_CollectionChanged;
            _updateTimer.Stop();
            _statusTimer.Stop();
        };
        // The checks of the moment at once (the service and network as last read), then fresh ones.
        ShowChecks(_viewModel.TroubleshootSnapshot());
        Loaded += async (_, _) =>
        {
            FocusFirstAction();
            await UpdateAsync();
        };
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e) => ScheduleUpdate();

    private void Printers_CollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) =>
        ScheduleUpdate();

    /// <summary>Makes the checks again soon; a burst of changes (a job's progress) makes them once.</summary>
    private void ScheduleUpdate()
    {
        if (!_updateTimer.IsEnabled) _updateTimer.Start();
    }

    /// <summary>Reads the Print Spooler and the network again, then shows the checks.</summary>
    internal async Task UpdateAsync()
    {
        await _viewModel.ReadSystemStateAsync();
        ShowChecks(_viewModel.TroubleshootSnapshot());
    }

    /// <summary>
    /// Shows the checks for <paramref name="snapshot"/>. The cards are rebuilt only when the
    /// checks changed, and keyboard focus stays on the same button when its card is still there.
    /// </summary>
    internal void ShowChecks(PrinterSnapshot snapshot)
    {
        Snapshot = snapshot;
        var checks = Troubleshooter.Diagnose(snapshot);
        // One line: "No printer found · 1 warning".
        string headline = Troubleshooter.Overview(snapshot, checks);
        if (HeadlineText.Text != headline && _refreshes == 0) Announce(HeadlineText, headline);
        else HeadlineText.Text = headline;
        if (checks.SequenceEqual(_shownChecks)) return;

        // Where keyboard focus was: the check and the action of the focused button.
        (string Id, TroubleshootAction Action)? focused =
            Keyboard.FocusedElement is Button { Tag: ActionTag tag } && ChecksPanel.IsKeyboardFocusWithin
                ? (tag.CheckId, tag.Action) : null;
        _shownChecks = checks;
        ChecksPanel.Children.Clear();
        foreach (var check in checks) ChecksPanel.Children.Add(Card(check));
        if (focused is { } was)
        {
            var again = ActionButtons().FirstOrDefault(b => ((ActionTag)b.Tag).CheckId == was.Id && ((ActionTag)b.Tag).Action == was.Action);
            if (again is not null) again.Focus();
            else FocusFirstAction();
        }
    }

    /// <summary>A check's button: which check it belongs to and what it does.</summary>
    private sealed record ActionTag(string CheckId, TroubleshootAction Action);

    internal IEnumerable<Button> ActionButtons() =>
        ChecksPanel.Children.OfType<FrameworkElement>()
            .SelectMany(card => FindButtons(card));

    private static IEnumerable<Button> FindButtons(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is Button button) yield return button;
            foreach (var nested in FindButtons(child)) yield return nested;
        }
    }

    private void FocusFirstAction()
    {
        // The first check's first button, else Refresh: Tab then reaches the rest in reading order.
        if (ActionButtons().FirstOrDefault() is { } first) first.Focus();
        else RefreshButton.Focus();
    }

    /// <summary>
    /// One check: a passed one with nothing to do as a compact row (its title; what it found is the
    /// tooltip), any other (a passed one that offers an action too) as a card with the status glyph
    /// (named for screen readers), the title, the one-line detail, its buttons and a "More help"
    /// expander with the rest (<see cref="TroubleshootCheck.More"/>). Refresh is the footer's, not
    /// repeated in a card. Screen readers see the card as a group named with the status and title,
    /// with the whole explanation as its help text.
    /// </summary>
    private Border Card(TroubleshootCheck check)
    {
        var (glyph, brush) = check.Status switch
        {
            CheckStatus.Problem => ("", "SystemFillColorCriticalBrush"),
            CheckStatus.Warning => ("", "SystemFillColorCautionBrush"),
            CheckStatus.Ok => ("", "SystemFillColorSuccessBrush"),
            _ => ("", "AccentTextFillColorPrimaryBrush"),
        };
        string status = Troubleshooter.StatusLabel(check.Status);
        var icon = new TextBlock
        {
            Text = glyph,
            Style = (Style)FindResource("GlyphText"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 2, 12, 0),
        };
        icon.SetResourceReference(TextBlock.ForegroundProperty, brush);
        AutomationProperties.SetName(icon, status);
        DockPanel.SetDock(icon, Dock.Left);

        var title = new TextBlock { Text = check.Title, Style = (Style)FindResource("BodyStrongText"), TextWrapping = TextWrapping.Wrap };
        var actions = check.Actions.Where(a => a != TroubleshootAction.Refresh).ToList();
        if (check.Status == CheckStatus.Ok && actions.Count == 0)
        {
            // Passed: a compact row with the title; what was found is the tooltip.
            icon.Margin = new Thickness(0, 1, 10, 0);
            var okRow = new DockPanel();
            okRow.Children.Add(icon);
            okRow.Children.Add(title);
            var row = new CheckCard
            {
                Padding = new Thickness(16, 6, 16, 6),
                Margin = new Thickness(0, 0, 0, 4),
                Background = System.Windows.Media.Brushes.Transparent,
                Child = okRow,
                ToolTip = check.FullDetail,
            };
            AutomationProperties.SetName(row, $"{status}: {check.Title}");
            AutomationProperties.SetHelpText(row, check.FullDetail);
            AutomationProperties.SetAutomationId(row, check.Id);
            return row;
        }
        string more = check.More;
        var detail = new TextBlock
        {
            Text = check.Detail,
            Style = (Style)FindResource("BodyText"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
        };
        var texts = new StackPanel();
        texts.Children.Add(title);
        texts.Children.Add(detail);
        if (actions.Count > 0)
        {
            var buttons = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
            foreach (var action in actions)
            {
                var button = new Button
                {
                    Content = Troubleshooter.Label(action, AppPlatform.Windows),
                    Tag = new ActionTag(check.Id, action),
                    Margin = new Thickness(0, 4, 8, 0),
                };
                LazyPrint.App.Icon.SetGlyph(button, ActionGlyph(action));
                button.Style = (Style)FindResource("IconTextButtonStyle");
                // The button's own name plus which check it is for (several cards offer the same one).
                AutomationProperties.SetHelpText(button, $"{status}: {check.Title}");
                button.Click += Action_Click;
                buttons.Children.Add(button);
            }
            texts.Children.Add(buttons);
        }
        if (more.Length > 0)
        {
            var moreText = new TextBlock { Text = more, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
            moreText.SetResourceReference(StyleProperty, "SecondaryBodyText");
            var expander = new Expander
            {
                Header = "More help",
                Content = moreText,
                Margin = new Thickness(0, 6, 0, 0),
                Padding = new Thickness(0),
                // A light disclosure inside the card, not a card of its own.
                Background = System.Windows.Media.Brushes.Transparent,
                BorderThickness = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetName(expander, $"More help: {check.Title}");
            texts.Children.Add(expander);
        }

        var cardRow = new DockPanel();
        cardRow.Children.Add(icon);
        cardRow.Children.Add(texts);
        var card = new CheckCard
        {
            Style = (Style)FindResource("CardStyle"),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(0, 0, 0, 8),
            Child = cardRow,
        };
        AutomationProperties.SetName(card, $"{status}: {check.Title}");
        AutomationProperties.SetHelpText(card, check.FullDetail);
        AutomationProperties.SetAutomationId(card, check.Id);
        return card;
    }

    private static string ActionGlyph(TroubleshootAction action) => action switch
    {
        TroubleshootAction.Refresh => "",
        TroubleshootAction.AddByAddress => "",
        TroubleshootAction.OpenPrinterSettings => "",
        TroubleshootAction.OpenNetworkSettings => "",
        TroubleshootAction.CopyDiagnostics => "",
        TroubleshootAction.ClearStuckJobs => "",
        TroubleshootAction.ResumePrinter => "",
        TroubleshootAction.PrintTestPage => "",
        _ => "",
    };

    private async void Action_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ActionTag tag }) await RunAsync(tag.Action, tag.CheckId);
    }

    /// <summary>Carries out an action of a card or the footer. The ones that change something ask first.</summary>
    internal async Task RunAsync(TroubleshootAction action, string? checkId = null)
    {
        string? printerId = checkId is not null && checkId.IndexOf(':') is > 0 and var colon ? checkId[(colon + 1)..] : null;
        switch (action)
        {
            case TroubleshootAction.Refresh:
                await RefreshAsync();
                break;
            case TroubleshootAction.AddByAddress:
                if (AddPrinter()) await UpdateAsync();
                break;
            case TroubleshootAction.OpenPrinterSettings:
            case TroubleshootAction.OpenNetworkSettings:
                if (!_viewModel.OpenSystemSettings(action)) ShowStatus("Settings did not open.");
                break;
            case TroubleshootAction.CopyDiagnostics:
                Copy();
                break;
            case TroubleshootAction.ClearStuckJobs when printerId is not null:
                if (Confirm("Clear stuck jobs?", "Every job waiting in this printer's queue is removed.")
                    && await _viewModel.ClearStuckJobsAsync(printerId))
                {
                    ShowStatus("Stuck jobs cleared.");
                    await UpdateAsync();
                }
                break;
            case TroubleshootAction.ResumePrinter when printerId is not null:
                if (Confirm("Resume this printer?", "Its queue starts printing the jobs waiting in it.")
                    && await _viewModel.ResumePrinterAsync(printerId))
                {
                    ShowStatus("Printer resumed.");
                    await UpdateAsync();
                }
                break;
            case TroubleshootAction.PrintTestPage:
                if (_viewModel.IsBusy || _viewModel.IsWaitingForBacks)
                {
                    ShowStatus("Wait for the job to finish.");
                    break;
                }
                if (_viewModel.SelectedPrinter is null or { Route: PrinterRoute.Demo })
                {
                    ShowStatus("Choose a printer first.");
                    break;
                }
                await _viewModel.PrintTestPageAsync();
                if (_viewModel.ErrorMessage is { } failure) ShowStatus($"Couldn't print the test page: {failure}");
                else if (_viewModel.SentMessage is { } sent) ShowStatus(sent);
                break;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private void Copy_Click(object sender, RoutedEventArgs e) => Copy();

    /// <summary>
    /// Looks for printers again, waits for them to answer, then makes the checks again.
    /// A Refresh while one runs is ignored, so the search is not restarted before it can answer.
    /// The buttons stay enabled: disabling the focused one would move keyboard focus away.
    /// </summary>
    internal async Task RefreshAsync()
    {
        if (_refreshes > 0) return;
        _refreshes++;
        SummaryText.Visibility = Visibility.Visible;
        Announce(SummaryText, "Looking for printers…");
        try
        {
            _viewModel.RefreshNetwork();
            await _viewModel.RefreshPrintersAsync();
            await Task.Delay(RefreshSettleTime);
        }
        finally
        {
            _refreshes--;
        }
        SummaryText.Text = "";
        SummaryText.Visibility = Visibility.Collapsed;
        await UpdateAsync();
    }

    private void Copy()
    {
        if (_viewModel.CopyDiagnostics(Snapshot)) ShowStatus("Copied to the clipboard.");
        else ShowStatus("Could not copy.");
    }

    /// <summary>What the footer says after Copy or a Settings button (harnesses read it).</summary>
    internal string FooterMessage => FooterStatus.Text;

    private void ShowStatus(string text)
    {
        _statusTimer.Stop();
        Announce(FooterStatus, text);
        _statusTimer.Start();
    }

    /// <summary>Sets the text and tells screen readers it changed.</summary>
    private static void Announce(TextBlock target, string text)
    {
        target.Text = text;
        var peer = UIElementAutomationPeer.FromElement(target) ?? UIElementAutomationPeer.CreatePeerForElement(target);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private bool ShowAddPrinterDialog()
    {
        if (_viewModel.Network is not { } network) return false;
        var dialog = new AddPrinterWindow(network) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Address is not { } address) return false;
        _ = _viewModel.SelectAddedAsync(address);
        return true;
    }

    private bool AskInDialog(string title, string text) =>
        MessageBox.Show(this, text, title, MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) == MessageBoxResult.OK;
}

/// <summary>
/// A troubleshooter card. A plain Border has no automation peer, so its name would never reach
/// screen readers; this one is a named group around the card's texts and buttons.
/// </summary>
internal sealed class CheckCard : Border
{
    protected override AutomationPeer OnCreateAutomationPeer() => new CheckCardAutomationPeer(this);

    private sealed class CheckCardAutomationPeer(CheckCard owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

        protected override string GetClassNameCore() => nameof(CheckCard);
    }
}
