using System.Windows;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>Asks for the name of a preset; stays open and says what is wrong while the name will not do.</summary>
public partial class PresetNameWindow : Window
{
    private readonly Func<string, PresetNameCheck> _check;

    public string PresetName => NameBox.Text.Trim();

    /// <param name="check">Judges the typed name; Ok closes the window.</param>
    public PresetNameWindow(string title, string name, Func<string, PresetNameCheck> check)
    {
        InitializeComponent();
        Title = title;
        NameBox.Text = name;
        _check = check;
        Loaded += (_, _) =>
        {
            NameBox.Focus();
            NameBox.SelectAll();
        };
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var check = _check(NameBox.Text);
        ProblemText.Text = PrintText.PresetNameProblem(check);
        ProblemText.Visibility = check == PresetNameCheck.Ok ? Visibility.Collapsed : Visibility.Visible;
        if (check == PresetNameCheck.Ok) DialogResult = true;
    }
}
