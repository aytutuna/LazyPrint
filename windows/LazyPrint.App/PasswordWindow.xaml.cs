using System.Windows;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>Asks for the password of a locked PDF.</summary>
public partial class PasswordWindow : Window
{
    public string Password => PasswordBox.Password;

    public PasswordWindow(string name, bool wrong)
    {
        InitializeComponent();
        MessageText.Text = DocumentText.PasswordMessage(name, wrong);
        Loaded += (_, _) => PasswordBox.Focus();
    }

    private void Open_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
