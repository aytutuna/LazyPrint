using System.Windows;

namespace LazyPrint.App;

/// <summary>Asks for the password of a locked PDF.</summary>
public partial class PasswordWindow : Window
{
    public string Password => PasswordBox.Password;

    public PasswordWindow(string name, bool wrong)
    {
        InitializeComponent();
        MessageText.Text = wrong ? $"That password did not open {name}. Try again." : $"{name} is locked. Enter its password.";
        Loaded += (_, _) => PasswordBox.Focus();
    }

    private void Open_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
