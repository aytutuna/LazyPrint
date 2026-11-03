using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPrint.Core;

namespace LazyPrint.App;

// The two-sided card: where a job done by hand waits for the stack to go back, and the one-sheet check.
public partial class MainWindow
{
    private const string GlyphCancel = "";
    private const string GlyphPrint = "";
    private const string GlyphCheck = "";

    /// <summary>What the card showed at the last refresh, so it is rebuilt (and focus moves into it) only when that changes.</summary>
    private (DuplexStep Step, bool Busy, string Text)? _duplexShown;

    private void SyncDuplexCard()
    {
        var step = ViewModel.ManualStep;
        DuplexOverlay.Visibility = step == DuplexStep.None ? Visibility.Collapsed : Visibility.Visible;
        if (step == DuplexStep.None)
        {
            _duplexShown = null;
            return;
        }
        // The busy bar and Cancel of the status bar stay; the card's buttons wait while something prints.
        bool busy = ViewModel.IsBusy;
        if (_duplexShown == (step, busy, ViewModel.ManualText)) return;
        _duplexShown = (step, busy, ViewModel.ManualText);
        DuplexTitle.Text = ViewModel.ManualTitle;
        DuplexText.Text = ViewModel.ManualText;
        // Turn the stack over, or put it back as it lies.
        DuplexPicture.Text = step == DuplexStep.CheckAnswer || !ViewModel.StackIsTurnedOver ? "" : "";
        DuplexButtons.Children.Clear();
        switch (step)
        {
            case DuplexStep.Reload:
                AddDuplexButton(ManualDuplexText.BacksTitle, GlyphPrint, true, () => _ = ViewModel.PrintBacksAsync(), busy);
                AddDuplexButton(ManualDuplexText.CheckTitle, GlyphCheck, false, () => _ = ViewModel.CheckDuplexAsync(), busy,
                                "Prints a numbered sheet to learn how this printer takes the stack back");
                break;
            case DuplexStep.CheckBack:
                AddDuplexButton("Print the back", GlyphPrint, true, () => _ = ViewModel.PrintCheckBackAsync(), busy);
                break;
            default:
                foreach (var answer in new[] { DuplexCheckAnswer.SameEdge, DuplexCheckAnswer.OppositeEdges, DuplexCheckAnswer.BothOnOneSide })
                {
                    var chosen = answer;
                    AddDuplexButton(ManualDuplexText.Answer(answer), GlyphCheck, answer == DuplexCheckAnswer.SameEdge,
                                    () => ViewModel.AnswerDuplexCheck(chosen), busy);
                }
                break;
        }
        AddDuplexButton("Cancel", GlyphCancel, false, ViewModel.CancelManualDuplex, busy);
        // The first button is the one the step is for.
        if (!busy) Dispatcher.BeginInvoke(() => (DuplexButtons.Children[0] as Control)?.Focus(), DispatcherPriority.Background);
    }

    private void AddDuplexButton(string text, string glyph, bool accent, Action click, bool busy, string? tip = null)
    {
        var button = new Button
        {
            Content = text,
            Style = (Style)FindResource(accent ? "AccentIconTextButtonStyle" : "IconTextButtonStyle"),
            MinWidth = 120,
            Margin = new Thickness(DuplexButtons.Children.Count == 0 ? 0 : 8, 4, 0, 4),
            IsEnabled = !busy,
            ToolTip = tip,
        };
        global::LazyPrint.App.Icon.SetGlyph(button, glyph);
        button.Click += (_, _) => click();
        DuplexButtons.Children.Add(button);
    }

    private void DuplexOverlay_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape || ViewModel.IsBusy) return;
        // The fronts are already printed and the backs cannot be picked up again: Escape only goes to Cancel.
        (DuplexButtons.Children[^1] as Control)?.Focus();
        e.Handled = true;
    }
}
