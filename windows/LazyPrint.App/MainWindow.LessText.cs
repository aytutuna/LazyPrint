using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using LazyPrint.Core;

namespace LazyPrint.App;

// The short visible texts of the window: the status line (the whole sentence stays its accessible name).
public partial class MainWindow
{
    /// <summary>The status sentence last shown, so a change is read out once.</summary>
    private string? _statusShown;

    /// <summary>At most six words, facts only (<see cref="StatusLine.Short"/>); the whole sentence is the line's name.</summary>
    private void SyncStatusLine()
    {
        string full = ViewModel.StatusMessage;
        StatusText.Text = StatusLine.Short(full, ViewModel.SelectedPrinter?.Name);
        AutomationProperties.SetName(StatusText, full);
        if (full != _statusShown)
        {
            _statusShown = full;
            if (StatusText.IsVisible)
            {
                var peer = UIElementAutomationPeer.FromElement(StatusText) ?? UIElementAutomationPeer.CreatePeerForElement(StatusText);
                peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
        }
    }
}

/// <summary>Shows a placeholder over a text box while the box is empty.</summary>
internal static class Placeholders
{
    public static void Attach(TextBox box, TextBlock placeholder)
    {
        void Sync() => placeholder.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => Sync();
        Sync();
    }
}
