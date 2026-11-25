using System.Windows;
using System.Windows.Threading;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

/// <summary>Builds the main window and each dialog once, so a XAML or style error shows here and not at the first click.</summary>
public sealed class WindowSmokeTests
{
    // WPF windows and the application's resources live on one thread; every test runs there.
    private static readonly Lazy<Dispatcher> Ui = new(() =>
    {
        var ready = new ManualResetEventSlim();
        Dispatcher? dispatcher = null;
        var thread = new Thread(() =>
        {
            var app = new LazyPrint.App.App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.InitializeComponent();
            dispatcher = Dispatcher.CurrentDispatcher;
            ready.Set();
            Dispatcher.Run();
        }) { IsBackground = true, Name = "Window smoke tests" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Wait();
        return dispatcher!;
    });

    private static void OnUi(Action work)
    {
        Exception? failure = null;
        Ui.Value.Invoke(() =>
        {
            try { work(); }
            catch (Exception e) { failure = e; }
        });
        if (failure is not null) throw new Xunit.Sdk.XunitException(failure.ToString());
    }

    private static void Lay(Window window, double width = 1100, double height = 800)
    {
        var content = Assert.IsAssignableFrom<FrameworkElement>(window.Content);
        content.Measure(new Size(width, height));
        content.Arrange(new Rect(0, 0, width, height));
        content.UpdateLayout();
        Assert.True(content.DesiredSize.Width > 0 && content.DesiredSize.Height > 0);
    }

    [Fact]
    public void TheMainWindowIsBuilt() => OnUi(() =>
    {
        using var folder = new TempFolder();
        var window = new MainWindow(folder.Path, folder.Path);
        try { Lay(window); }
        finally { window.ViewModel.Shutdown(); }
    });

    [Fact]
    public async Task TheDialogsAreBuilt()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("Office"));
        rig.Spooler.Capable["Office"] = Rig.Duplex();
        await rig.Model.RefreshPrintersAsync();
        string id = rig.Model.Printers[0].Id;
        OnUi(() =>
        {
            Lay(new PasswordWindow("Report.pdf", wrong: false));
            Lay(new PasswordWindow("Report.pdf", wrong: true));
            Lay(new PresetNameWindow("Save preset", "Mine", _ => PresetNameCheck.Ok));
            Lay(new AddPrinterWindow(rig.Network));
            Lay(new PrinterDetailsWindow(rig.Model, id));
            Lay(new PrinterDetailsWindow(rig.Model, "gone"));
            Lay(new TroubleshooterWindow(rig.Model));
            Lay(new PhoneWindow(rig.Model));
            Lay(new CertificateTrustWindow(
                new IppCertificateException(IppTrustVerdict.Unknown, "Office printer", null, "Self-signed", "AA:BB", "CN=Office"),
                "Trust and print"));
        });
    }

    [Fact]
    public void ThePreviewResolutionFollowsTheScreenScale()
    {
        Assert.Equal(96, MainWindow.DpiFor(1.0, 1.0));
        Assert.Equal(144, MainWindow.DpiFor(1.0, 1.5));
        Assert.Equal(192, MainWindow.DpiFor(1.0, 2.0));
    }

    [Fact]
    public void ThePreviewIsDrawnAgainWhenTheScreenScaleChanges() => OnUi(() =>
    {
        using var folder = new TempFolder();
        var window = new MainWindow(folder.Path, folder.Path);
        try
        {
            Assert.False(window.PreviewIsScheduled);
            window.ForgetPreview();
            Assert.True(window.PreviewIsScheduled);
        }
        finally { window.ViewModel.Shutdown(); }
    });

    private sealed class TempFolder : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lazyprint-smoke-" + Guid.NewGuid().ToString("N"));

        public void Dispose()
        {
            if (Directory.Exists(Path)) Directory.Delete(Path, true);
        }
    }
}
