using System.IO;
using System.Windows;
using LazyPrint.App.Services;
using LazyPrint.Core;

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
        var files = FilesOf(e.Args);
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

    /// <summary>
    /// The files a command line asks for: each argument is a path, except one that starts with <c>lazyprint:</c>, which is
    /// the address Lazy Scan opens the app with (<see cref="LazyPrintUrl"/>) and stands for the files in it. The scheme's
    /// command is <c>"exe" "%1"</c>, so an address with a quote in it can add arguments of its own: when the first one is an
    /// address, it is the only one read.
    /// </summary>
    internal static IReadOnlyList<string> FilesOf(IEnumerable<string> args)
    {
        var all = args.Where(arg => arg.Length > 0).ToList();
        if (all.Count > 0 && IsAddress(all[0])) return [.. LazyPrintUrl.Parse(all[0]).Select(Path.GetFullPath)];
        return [.. all.SelectMany(arg => IsAddress(arg) ? LazyPrintUrl.Parse(arg).Select(Path.GetFullPath) : [Path.GetFullPath(arg)])];
    }

    private static bool IsAddress(string arg) => arg.TrimStart().StartsWith(LazyPrintUrl.Scheme + ":", StringComparison.OrdinalIgnoreCase);

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
