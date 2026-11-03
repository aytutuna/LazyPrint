using System.IO;
using System.Windows;
using LazyPrint.App.Services;

namespace LazyPrint.App;

public partial class App : Application
{
    /// <summary>One instance per user session.</summary>
    private const string InstanceMutexName = @"Local\LazyPrint.App";

    private Mutex? _instance;
    private InstanceChannel? _channel;

    /// <summary>The files named on the command line; the main window takes them once it is open.</summary>
    public static IReadOnlyList<string> StartupFiles { get; private set; } = [];

    protected override void OnStartup(StartupEventArgs e)
    {
        string[] files = [.. e.Args.Where(arg => arg.Length > 0).Select(Path.GetFullPath)];
        _instance = new Mutex(true, InstanceMutexName, out bool first);
        if (!first)
        {
            // The running instance opens the files (or just comes forward); this one has nothing more to do, unless
            // nobody answers: then it opens them itself rather than lose them.
            bool handed = InstanceChannel.Send(files);
            _instance.Dispose();
            _instance = null;
            if (handed)
            {
                Shutdown();
                return;
            }
        }
        StartupFiles = files;
        if (first) _channel = new InstanceChannel(Opened);
        // Apply the saved appearance before the first window is created.
        ThemeService.Initialize();
        base.OnStartup(e);
    }

    /// <summary>Files handed over by a second start: opened at once, or kept for the window if it is not open yet.</summary>
    private void Opened(IReadOnlyList<string> paths) => Dispatcher.BeginInvoke(() =>
    {
        if (MainWindow is MainWindow { IsLoaded: true } window) window.OpenFiles(paths);
        else StartupFiles = [.. StartupFiles, .. paths];
    });

    protected override void OnExit(ExitEventArgs e)
    {
        _channel?.Dispose();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
