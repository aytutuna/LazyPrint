using System.IO;
using System.Windows;
using System.Windows.Input;
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
        DispatcherUnhandledException += OnUnhandled;
        // An access key is for Alt; without it WPF also takes plain typing on a focused button as one.
        EventManager.RegisterClassHandler(typeof(UIElement), AccessKeyManager.AccessKeyPressedEvent,
                                          new AccessKeyPressedEventHandler(OnAccessKey));
        base.OnStartup(e);
    }

    private static void OnAccessKey(object sender, AccessKeyPressedEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Alt) != 0) return;
        e.Target = null;
        e.Handled = true;
    }

    private static bool _showing;

    /// <summary>
    /// Writes an exception nobody caught to Logs\errors.txt. The app carries on after a mistake of its own; one the process
    /// cannot recover from is left to end it.
    /// </summary>
    private void OnUnhandled(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            string folder = AppViewModel.DefaultLogDirectory;
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "errors.txt"), $"{DateTime.Now:g}\n{e.Exception}\n\n");
        }
        catch (Exception write)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not write the error log: {write.Message}");
        }
        if (e.Exception is OutOfMemoryException or AccessViolationException or InsufficientExecutionStackException) return;
        e.Handled = true;
        // The box pumps messages, so an error that keeps coming back would stack one per turn.
        if (_showing) return;
        _showing = true;
        try
        {
            MessageBox.Show("Something went wrong. The details are saved in errors.txt, in the Logs folder of Lazy Print under %LOCALAPPDATA%.",
                            "Lazy Print", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _showing = false;
        }
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
