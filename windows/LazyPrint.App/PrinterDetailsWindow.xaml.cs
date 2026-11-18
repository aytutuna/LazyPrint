using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>One printer's state, model, address, problems and supplies, the demo printer's switches and a test page.</summary>
public partial class PrinterDetailsWindow : Window
{
    private readonly AppViewModel _viewModel;
    private readonly string _printerId;

    public PrinterDetailsWindow(AppViewModel viewModel, string printerId)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _printerId = printerId;
        Build();
    }

    private void Build()
    {
        Body.Children.Clear();
        if (_viewModel.Printers.FirstOrDefault(row => row.Id == _printerId)?.Info is not { } printer)
        {
            Title = "Printer";
            Body.Children.Add(Text("This printer is no longer listed.", "SecondaryBodyText"));
            TestPageButton.IsEnabled = false;
            return;
        }
        Title = printer.Name;
        Body.Children.Add(Text(printer.Name, "SubtitleText"));
        Body.Children.Add(Pair("State", printer.State switch
        {
            PrinterState.Idle => "Ready",
            PrinterState.Printing => "Printing",
            PrinterState.Stopped => "Stopped",
            PrinterState.Offline => "Offline",
            _ => "Unknown",
        }));
        if (printer.Model is { } model) Body.Children.Add(Pair("Model", model));
        if (printer.Address is { } address) Body.Children.Add(Pair("Address", address));
        if (printer.Id == _viewModel.SelectedPrinter?.Id)
        {
            Body.Children.Add(Pair("Two-sided by hand", _viewModel.SelectedPrefs.PaperPath.Checked ? "Checked" : "Not checked yet"));
        }
        foreach (var problem in printer.Problems)
        {
            var title = Text(problem.Title, "BodyText");
            title.Foreground = (Brush)FindResource(problem.IsError ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");
            title.Margin = new Thickness(0, 12, 0, 0);
            Body.Children.Add(title);
            Body.Children.Add(Text(problem.Advice, "SecondaryBodyText"));
        }
        if (printer.Supplies.Count > 0)
        {
            Body.Children.Add(Header("Supplies"));
            foreach (var supply in printer.Supplies) Body.Children.Add(SupplyRow(supply));
        }
        if (printer.Route == PrinterRoute.Demo)
        {
            Body.Children.Add(Header("Demo printer"));
            var duplex = Switch("Prints both sides", _viewModel.Demo.Duplex);
            duplex.Click += async (_, _) =>
            {
                await _viewModel.SetDemoDuplexAsync(duplex.IsChecked == true);
                Build();
            };
            var outOfPaper = Switch("Out of paper", _viewModel.Demo.OutOfPaper);
            outOfPaper.Click += (_, _) =>
            {
                _viewModel.SetDemoOutOfPaper(outOfPaper.IsChecked == true);
                Build();
            };
            Body.Children.Add(duplex);
            Body.Children.Add(outOfPaper);
        }
        TestPageButton.IsEnabled = !_viewModel.IsBusy && !_viewModel.IsAddingFiles && _viewModel.ManualStep == DuplexStep.None;
    }

    private TextBlock Text(string text, string style) =>
        new() { Text = text, Style = (Style)FindResource(style), TextWrapping = TextWrapping.Wrap };

    private TextBlock Header(string text)
    {
        var header = Text(text, "SectionHeaderText");
        header.Margin = new Thickness(0, 16, 0, 0);
        return header;
    }

    private UIElement Pair(string label, string value)
    {
        var grid = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(Text(label, "SecondaryBodyText"));
        var content = Text(value, "BodyText");
        Grid.SetColumn(content, 1);
        grid.Children.Add(content);
        return grid;
    }

    private UIElement SupplyRow(Supply supply)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        var line = new DockPanel();
        var level = Text(supply.Level is { } percent ? $"{percent} %" : "Unknown", "BodyText");
        if (supply.IsLow) level.Foreground = (Brush)FindResource("SystemFillColorCautionBrush");
        DockPanel.SetDock(level, Dock.Right);
        line.Children.Add(level);
        line.Children.Add(Text(supply.Name, "BodyText"));
        panel.Children.Add(line);
        if (supply.Level is not null)
        {
            var bar = new SupplyBar(supply);
            var progress = new ProgressBar
            {
                Minimum = 0,
                Maximum = 1,
                Value = bar.Fraction,
                Foreground = bar.Fill,
                Height = 4,
                Margin = new Thickness(0, 4, 0, 0),
            };
            System.Windows.Automation.AutomationProperties.SetName(progress, bar.Description);
            panel.Children.Add(progress);
        }
        return panel;
    }

    private CheckBox Switch(string label, bool on) => new()
    {
        Content = label,
        IsChecked = on,
        Style = (Style)FindResource("ToggleSwitchStyle"),
        Margin = new Thickness(0, 8, 0, 0),
    };

    private async void TestPage_Click(object sender, RoutedEventArgs e)
    {
        TestPageButton.IsEnabled = false;
        await _viewModel.SelectPrinterAsync(_printerId);
        await _viewModel.PrintTestPageAsync();
        Close();
    }
}
