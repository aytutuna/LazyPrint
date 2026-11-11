using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace LazyPrint.App;

// The phone link in the main window: the Phone button opens PhoneWindow, and the bar offers what a phone sent. The
// taskbar button flashes when a batch arrives while the window is in the background.
public partial class MainWindow
{
    private void SetUpPhone()
    {
        ViewModel.PhoneWindowRequested += () => PhoneButton_Click(this, new RoutedEventArgs());
        ViewModel.PhoneFilesArrived += () =>
        {
            if (!IsActive && IsVisible) FlashTaskbarButton();
        };
    }

    private void PhoneButton_Click(object sender, RoutedEventArgs e)
    {
        new PhoneWindow(ViewModel) { Owner = this }.ShowDialog();
    }

    /// <summary>The batch the bar showed last, so the next one is announced even when it reads the same.</summary>
    private string? _phoneBarBatch;

    /// <summary>Shows the oldest batch waiting, with its buttons off while a job runs.</summary>
    private void SyncPhoneBar()
    {
        if (ViewModel.PhoneBatch is not { } batch || ViewModel.PhoneBatchMessage is not { } message)
        {
            PhoneBar.Visibility = Visibility.Collapsed;
            _phoneBarBatch = null;
            return;
        }
        bool changed = _phoneBarBatch != batch.Id || PhoneBarMessage.Text != message;
        _phoneBarBatch = batch.Id;
        PhoneBarMessage.Text = message;
        PhoneBarAddButton.IsEnabled = true;
        PhoneBarNewButton.IsEnabled = ViewModel.DocumentsLockedReason is null;
        if (PhoneBar.Visibility != Visibility.Visible || changed)
        {
            PhoneBar.Visibility = Visibility.Visible;
            Announce(PhoneBarText);
        }
    }

    private async void PhoneBarAdd_Click(object sender, RoutedEventArgs e) => await UsePhoneBatchAsync(startNew: false);

    private async void PhoneBarNew_Click(object sender, RoutedEventArgs e) => await UsePhoneBatchAsync(startNew: true);

    private void PhoneBarDismiss_Click(object sender, RoutedEventArgs e) => ViewModel.DismissPhoneBatch();

    private async Task UsePhoneBatchAsync(bool startNew)
    {
        if (await ViewModel.UsePhoneBatchAsync(startNew)) ShowPrintTab();
    }

    /// <summary>Flashes the taskbar button until the window comes to the front (FlashWindowEx).</summary>
    private void FlashTaskbarButton()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var info = new FlashInfo
        {
            Size = (uint)Marshal.SizeOf<FlashInfo>(),
            Window = handle,
            Flags = FlashTray | FlashTimerNoForeground,
            Count = 3,
            Timeout = 0,
        };
        FlashWindowEx(ref info);
    }

    private const uint FlashTray = 0x00000002;
    private const uint FlashTimerNoForeground = 0x0000000C;

    [StructLayout(LayoutKind.Sequential)]
    private struct FlashInfo
    {
        public uint Size;
        public IntPtr Window;
        public uint Flags;
        public uint Count;
        public uint Timeout;
    }

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FlashWindowEx(ref FlashInfo info);
}
