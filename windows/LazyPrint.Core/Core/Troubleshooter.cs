using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/Troubleshooter.swift (Lazy Scan's Troubleshooter, for printers): "Why isn't my
// printer listed?". What the app knows about finding printers goes into one snapshot and comes out as plain-language
// checks, each with the actions that help. Diagnosing only reads; the app asks before it runs an action that changes
// something (clearing stuck jobs, resuming a printer).

/// <summary>The network the computer is on, as far as finding network printers goes.</summary>
public enum NetworkStatus
{
    /// <summary>Not known (not checked).</summary>
    Unknown,
    Offline,
    /// <summary>Every connected network is public: Windows does not look for devices there.</summary>
    PublicNetwork,
    PrivateNetwork,
    DomainNetwork,
}

/// <summary>The state of a system service (on Windows, the Print Spooler).</summary>
public enum ServiceStatus
{
    /// <summary>Not known (not checked, or the system would not say).</summary>
    Unknown,
    Running,
    Starting,
    Stopping,
    Stopped,
    Paused,
    /// <summary>Stopped and set not to start.</summary>
    Disabled,
    NotInstalled,
}

/// <summary>The automatic search for network printers (DNS-SD, _ipp._tcp and _ipps._tcp).</summary>
public enum DiscoveryStatus
{
    /// <summary>Not known; no check is shown.</summary>
    Unknown,
    Off,
    /// <summary>Started; the first pass has not finished.</summary>
    Searching,
    Running,
    /// <summary>The system would not search.</summary>
    Unavailable,
    /// <summary>The user turned off the app's access to the local network (iPhone and iPad). Windows and the Mac never produce it.</summary>
    Denied,
}

/// <summary>How a check came out. The order is not the display order (see <see cref="Troubleshooter.Diagnose"/>).</summary>
public enum CheckStatus
{
    Ok,
    /// <summary>Advice that applies whatever the checks found.</summary>
    Tip,
    Warning,
    Problem,
}

/// <summary>Something the troubleshooter offers to do; the app carries it out.</summary>
public enum TroubleshootAction
{
    /// <summary>Look for printers again.</summary>
    Refresh,
    /// <summary>The "Add printer by address" dialog.</summary>
    AddByAddress,
    /// <summary>Windows: Settings, Printers &amp; scanners. Mac: System Settings, Printers &amp; Scanners.</summary>
    OpenPrinterSettings,
    /// <summary>Windows: Settings, Network &amp; internet. Mac: System Settings, Network.</summary>
    OpenNetworkSettings,
    /// <summary>Copies the checks as text.</summary>
    CopyDiagnostics,
    /// <summary>The app's own page in the Settings app (iPhone and iPad), where Local Network access is turned on.</summary>
    OpenAppSettings,
    /// <summary>Removes the jobs waiting in the printer of the check (<c>stuckJobs:&lt;id&gt;</c>). Changes something: the app asks first.</summary>
    ClearStuckJobs,
    /// <summary>Resumes the printer of the check (<c>paused:&lt;id&gt;</c>). Changes something: the app asks first.</summary>
    ResumePrinter,
    PrintTestPage,
}

/// <summary>An address added by hand and whether a printer answers there.</summary>
/// <param name="Address">As the user would write it, e.g. "192.168.1.50" or "printer.local".</param>
/// <param name="Listed">A printer answered and is listed.</param>
/// <param name="Problem">Why nothing is listed, in plain language; null when listed or not checked yet.</param>
public sealed record ManualHostStatus(string Address, bool Listed, string? Problem = null);

/// <summary>Jobs waiting in a printer's queue.</summary>
/// <param name="OldestMinutes">How long the oldest has been waiting.</param>
/// <param name="AnyInError">A job in the queue is in error, which holds up the rest.</param>
public sealed record StuckJobs(string PrinterId, string PrinterName, int Count, int OldestMinutes, bool AnyInError)
{
    public const int StuckAfterMinutes = 5;

    /// <summary>Jobs are stuck when one is in error or the oldest has waited five minutes; a job printing now is not.</summary>
    public bool IsStuck => Count > 0 && (AnyInError || OldestMinutes >= StuckAfterMinutes);
}

/// <summary>The last time a job or a connection to a printer failed.</summary>
/// <param name="PrinterName">The printer's name as listed.</param>
/// <param name="Message">The error the user was shown.</param>
/// <param name="Problem">The condition behind it, when the error says; a problem that <see cref="PrinterProblem.IsError"/> is a Problem check, else a Warning.</param>
public sealed record PrinterFailure(string PrinterName, string Message, PrinterProblem? Problem = null)
{
    internal static readonly PrinterProblem Busy = new("Printer busy", "Wait until it has finished, then print again.", true);
    private static readonly PrinterProblem NeedsDriver = new("Needs its driver", "Install the maker's driver, then print again.", true);
    private static readonly PrinterProblem NeedsSignIn = new("Needs a sign-in", "Lazy Print can't sign in to printers yet.", true);
    private static readonly PrinterProblem CertificateChanged =
        new("Certificate changed", "Check the printer, then trust it again.", true);
    private static readonly PrinterProblem CertificateNotTrusted =
        new("Certificate not trusted", "Print again and trust the printer when asked.", false);

    /// <summary>
    /// What a failed job or connection tells the troubleshooter; null for errors that say nothing about reaching the
    /// printer (cancelled, a page that could not be prepared).
    /// </summary>
    public static PrinterFailure? From(string printerName, Exception error) => error switch
    {
        OperationCanceledException => null,
        PrintException print => From(printerName, print.Error),
        IppCertificateException certificate => new PrinterFailure(
            printerName, certificate.Message,
            certificate.Verdict == IppTrustVerdict.Changed ? CertificateChanged : CertificateNotTrusted),
        _ => new PrinterFailure(printerName, error.Message),
    };

    public static PrinterFailure? From(string printerName, PrintError error) => error switch
    {
        PrintError.BadRaster or PrintError.Unreadable => null,
        PrintError.Busy => new PrinterFailure(printerName, error.Message, Busy),
        PrintError.NeedsDriver => new PrinterFailure(printerName, error.Message, NeedsDriver),
        PrintError.NeedsSignIn => new PrinterFailure(printerName, error.Message, NeedsSignIn),
        PrintError.CertificateChanged => new PrinterFailure(printerName, error.Message, CertificateChanged),
        _ => new PrinterFailure(printerName, error.Message),
    };
}

/// <summary>
/// Everything the troubleshooter looks at, read at one moment. Fields left at their defaults (Unknown, empty) produce
/// no check.
/// </summary>
public sealed record PrinterSnapshot
{
    public AppPlatform Platform { get; init; }
    /// <summary>The printers listed, one per row, the demo printer included.</summary>
    public IReadOnlyList<PrinterInfo> Printers { get; init; } = [];
    public NetworkStatus Network { get; init; }
    /// <summary>The Print Spooler; Windows only.</summary>
    public ServiceStatus Spooler { get; init; }
    public DiscoveryStatus Discovery { get; init; }
    /// <summary>Why the search is unavailable, as the system put it; null otherwise.</summary>
    public string? DiscoveryDetail { get; init; }
    public IReadOnlyList<ManualHostStatus> ManualHosts { get; init; } = [];
    public IReadOnlyList<StuckJobs> StuckJobs { get; init; } = [];
    public PrinterFailure? LastFailure { get; init; }

    /// <summary>The printers listed other than the demo printer.</summary>
    public int ListedPrinterCount => Printers.Count(printer => printer.Route != PrinterRoute.Demo);
}

/// <summary>One line of the troubleshooter: what was checked, how it came out, what to do.</summary>
/// <param name="Id">Stable identifier ("network", "printer:ipp:4509a320", "manualHost:192.168.1.50", ...).</param>
/// <param name="Status">How it came out.</param>
/// <param name="Title">Six words at most.</param>
/// <param name="Detail">What it means or what to do, in one line of fifteen words at most.</param>
/// <param name="Actions">Buttons offered with it, in order.</param>
/// <param name="More">The rest of the explanation, behind "More help"; empty when the detail says it all.</param>
public sealed record TroubleshootCheck(string Id, CheckStatus Status, string Title, string Detail,
                                       IReadOnlyList<TroubleshootAction> Actions, string More = "")
{
    public bool Equals(TroubleshootCheck? other) =>
        other is not null && Id == other.Id && Status == other.Status && Title == other.Title
        && Detail == other.Detail && More == other.More && Actions.SequenceEqual(other.Actions);

    public override int GetHashCode() => HashCode.Combine(Id, Status, Title, Detail, More, Actions.Count);

    /// <summary>The detail and the more help as one text, for screen readers and the copied diagnostics.</summary>
    public string FullDetail => More.Length == 0 ? Detail : $"{Detail} {More}";
}

public static class Troubleshooter
{
    /// <summary>
    /// The checks for <paramref name="snapshot"/>: problems first, then warnings, then what is fine, then the tips that
    /// always apply; within each, in this order: the last failure, the network, the spooler, the automatic search (or
    /// the local network access it was refused), each printer's problems, stuck jobs, paused printers, the addresses
    /// added by hand, then the tips. The iPhone and iPad get their own wording and tips.
    /// </summary>
    public static IReadOnlyList<TroubleshootCheck> Diagnose(PrinterSnapshot snapshot)
    {
        var platform = snapshot.Platform;
        var checks = new List<TroubleshootCheck>();

        if (snapshot.LastFailure is { } failure) checks.Add(FailureCheck(failure, platform));
        if (NetworkCheck(snapshot) is { } network) checks.Add(network);
        if (platform == AppPlatform.Windows && SpoolerCheck(snapshot.Spooler) is { } spooler) checks.Add(spooler);
        if (DiscoveryCheck(snapshot) is { } discovery) checks.Add(discovery);
        var listed = snapshot.Printers.Where(printer => printer.Route != PrinterRoute.Demo).ToList();
        foreach (var printer in listed)
        {
            if (PrinterCheck(printer) is { } check) checks.Add(check);
        }
        foreach (var jobs in snapshot.StuckJobs.Where(jobs => jobs.IsStuck)) checks.Add(StuckJobsCheck(jobs));
        foreach (var printer in listed.Where(printer => printer.Problems.Any(problem => problem.Title == IppProblemText.Paused)))
        {
            checks.Add(PausedCheck(printer, platform));
        }
        foreach (var host in snapshot.ManualHosts.Where(host => !host.Listed))
        {
            checks.Add(new TroubleshootCheck(
                $"manualHost:{host.Address}", CheckStatus.Warning,
                $"No printer answers at {host.Address}",
                "Check that it is on and its address hasn't changed.",
                [TroubleshootAction.Refresh],
                JoinSentences(host.Problem,
                              "Its network settings page or control panel shows the current address. The app "
                              + "tries the address again every minute.")));
        }
        checks.AddRange(Tips(platform, snapshot.Printers.Any(p => p.Route != PrinterRoute.Demo)));

        // A stable sort: problems, warnings, what is fine, tips.
        return [.. checks.Select((check, index) => (check, index))
                         .OrderBy(pair => Rank(pair.check.Status))
                         .ThenBy(pair => pair.index)
                         .Select(pair => pair.check)];
    }

    /// <summary>"No printer found", "1 printer found", "3 printers found" (the demo printer does not count).</summary>
    public static string Headline(PrinterSnapshot snapshot) => snapshot.ListedPrinterCount switch
    {
        0 => "No printer found",
        1 => "1 printer found",
        int count => $"{count} printers found",
    };

    /// <summary>"2 problems and 1 warning found.", or that nothing stops printers from appearing.</summary>
    public static string Summary(IReadOnlyList<TroubleshootCheck> checks)
    {
        var parts = Counts(checks);
        if (parts.Count == 0)
        {
            return "Nothing here stops printers from appearing. The tips below cover the usual causes.";
        }
        return $"{string.Join(" and ", parts)} found.";
    }

    /// <summary>
    /// The troubleshooter's one-line headline: what is listed, then how many problems and warnings there are
    /// ("No printer found · 2 problems, 1 warning"); just what is listed when there are none.
    /// </summary>
    public static string Overview(PrinterSnapshot snapshot, IReadOnlyList<TroubleshootCheck> checks)
    {
        var parts = Counts(checks);
        string headline = Headline(snapshot);
        return parts.Count == 0 ? headline : $"{headline} · {string.Join(", ", parts)}";
    }

    /// <summary>The button text for an action.</summary>
    public static string Label(TroubleshootAction action, AppPlatform platform) => action switch
    {
        TroubleshootAction.Refresh => "Refresh",
        TroubleshootAction.AddByAddress => "Add by address…",
        TroubleshootAction.OpenPrinterSettings => platform == AppPlatform.Windows ? "Printer settings" : "Printers & Scanners",
        TroubleshootAction.OpenNetworkSettings => "Network settings",
        TroubleshootAction.CopyDiagnostics => "Copy diagnostics",
        TroubleshootAction.OpenAppSettings => "Open Settings",
        TroubleshootAction.ClearStuckJobs => "Clear stuck jobs",
        TroubleshootAction.ResumePrinter => "Resume printer",
        TroubleshootAction.PrintTestPage => "Print test page",
        _ => action.ToString(),
    };

    /// <summary>The status as a word, for screen readers and the copied text: "OK", "Tip", "Warning", "Problem".</summary>
    public static string StatusLabel(CheckStatus status) => status switch
    {
        CheckStatus.Ok => "OK",
        CheckStatus.Tip => "Tip",
        CheckStatus.Warning => "Warning",
        CheckStatus.Problem => "Problem",
        _ => status.ToString(),
    };

    /// <summary>
    /// The checks as plain text, for the clipboard: the heading, the headline and summary, then one "Status: title"
    /// line per check with its detail indented below, and its more help (when it has some) on the line after.
    /// </summary>
    public static string Report(PrinterSnapshot snapshot, IReadOnlyList<TroubleshootCheck> checks)
    {
        var text = new StringBuilder();
        text.Append("Why isn't my printer listed?\n");
        text.Append(Headline(snapshot)).Append(". ").Append(Summary(checks)).Append('\n');
        foreach (var check in checks)
        {
            text.Append(StatusLabel(check.Status)).Append(": ").Append(check.Title).Append('\n');
            text.Append("  ").Append(check.Detail).Append('\n');
            if (check.More.Length > 0) text.Append("  ").Append(check.More).Append('\n');
        }
        return text.ToString();
    }

    /// <summary>
    /// The network status of a computer connected to these networks: none is offline; a public network among them
    /// wins, since a VPN or other private adapter says nothing about the Wi-Fi the printer is on.
    /// </summary>
    public static NetworkStatus CombineNetworks(IEnumerable<NetworkStatus> connected)
    {
        var all = connected.Where(status => status is not (NetworkStatus.Unknown or NetworkStatus.Offline)).ToList();
        if (all.Count == 0) return connected.Any(status => status == NetworkStatus.Unknown) ? NetworkStatus.Unknown : NetworkStatus.Offline;
        if (all.Contains(NetworkStatus.PublicNetwork)) return NetworkStatus.PublicNetwork;
        if (all.Contains(NetworkStatus.DomainNetwork)) return NetworkStatus.DomainNetwork;
        return NetworkStatus.PrivateNetwork;
    }

    // MARK: - The checks

    private static int Rank(CheckStatus status) => status switch
    {
        CheckStatus.Problem => 0,
        CheckStatus.Warning => 1,
        CheckStatus.Ok => 2,
        _ => 3,
    };

    private static List<string> Counts(IReadOnlyList<TroubleshootCheck> checks)
    {
        int problems = checks.Count(check => check.Status == CheckStatus.Problem);
        int warnings = checks.Count(check => check.Status == CheckStatus.Warning);
        var parts = new List<string>();
        if (problems > 0) parts.Add(problems == 1 ? "1 problem" : $"{problems} problems");
        if (warnings > 0) parts.Add(warnings == 1 ? "1 warning" : $"{warnings} warnings");
        return parts;
    }

    private static string Computer(AppPlatform platform) => platform switch
    {
        AppPlatform.Windows => "PC",
        AppPlatform.Ios => "device",
        _ => "Mac",
    };

    private static string OtherApps(AppPlatform platform) =>
        platform == AppPlatform.Ios ? "printing apps on other devices" : "other printing apps";

    /// <summary>The system that searches the network, in the discovery check's more help.</summary>
    private static string SearchingSystem(AppPlatform platform) => platform switch
    {
        AppPlatform.Windows => "Windows",
        AppPlatform.Mac => "macOS",
        _ => "iOS",
    };

    private static TroubleshootCheck FailureCheck(PrinterFailure failure, AppPlatform platform)
    {
        string name = failure.PrinterName;
        if (failure.Problem is not { } problem)
        {
            return new TroubleshootCheck(
                "lastFailure", CheckStatus.Warning, $"Could not print to {name}",
                "Check that it is on, awake and connected.",
                [TroubleshootAction.Refresh],
                JoinSentences(failure.Message,
                              platform == AppPlatform.Ios
                                  ? "It must be on the same network as this " + Computer(platform) + "."
                                  : "It must be connected by its cable or to the same network as this " + Computer(platform) + "."));
        }
        return new TroubleshootCheck(
            "lastFailure", problem.IsError ? CheckStatus.Problem : CheckStatus.Warning, $"{problem.Title}: {name}",
            problem.Advice, [TroubleshootAction.Refresh],
            problem == PrinterFailure.Busy
                ? $"A printer works on one job at a time; {OtherApps(platform)} may be using it."
                : "");
    }

    private static TroubleshootCheck? NetworkCheck(PrinterSnapshot snapshot)
    {
        var platform = snapshot.Platform;
        if (platform == AppPlatform.Ios) return PhoneNetworkCheck(snapshot.Network);
        return snapshot.Network switch
        {
            NetworkStatus.Offline => new TroubleshootCheck(
                "network", CheckStatus.Problem, "Not connected to a network",
                "Connect to the network the printer is on, then select Refresh.",
                [TroubleshootAction.OpenNetworkSettings, TroubleshootAction.Refresh],
                $"This {Computer(platform)} is not on a network, so network printers can't be found. "
                + "Printers connected by USB are not affected."),
            NetworkStatus.PublicNetwork => new TroubleshootCheck(
                "network", CheckStatus.Warning, "Network set to Public",
                "Windows won't find network printers on a Public network.",
                [TroubleshootAction.OpenNetworkSettings, TroubleshootAction.AddByAddress],
                "If this is your home or office network, set it to Private in network settings. You can also add "
                + "the printer by its address."),
            NetworkStatus.PrivateNetwork or NetworkStatus.DomainNetwork => new TroubleshootCheck(
                "network", CheckStatus.Ok, "Connected to a private network",
                "Network printers on this network can be found.", []),
            _ => null,
        };
    }

    /// <summary>The iPhone's and iPad's network: Wi-Fi or a wired network, or none. iOS has no public or private networks.</summary>
    private static TroubleshootCheck? PhoneNetworkCheck(NetworkStatus network) => network switch
    {
        NetworkStatus.Offline => new TroubleshootCheck(
            "network", CheckStatus.Problem, "Not connected to Wi-Fi",
            "Join the printer's Wi-Fi network, then tap Refresh.",
            [TroubleshootAction.Refresh],
            "Network printers are found only on Wi-Fi or a wired network."),
        NetworkStatus.PublicNetwork or NetworkStatus.PrivateNetwork or NetworkStatus.DomainNetwork => new TroubleshootCheck(
            "network", CheckStatus.Ok, "Connected to a local network",
            "Network printers on this network can be found.", []),
        _ => null,
    };

    private static TroubleshootCheck LocalNetworkDeniedCheck() => new(
        "localNetwork", CheckStatus.Problem, "Local Network access is off",
        "Turn on Local Network for Lazy Print in Settings.",
        [TroubleshootAction.OpenAppSettings],
        "Without it, the app can't find or reach printers on your network. Printers appear as soon as it's on. "
        + "If it's on already, turn it off and on again.");

    private static TroubleshootCheck? SpoolerCheck(ServiceStatus status) => status switch
    {
        ServiceStatus.Running => new TroubleshootCheck(
            "spooler", CheckStatus.Ok, "Print spooler is on",
            "The Print Spooler, which queues every print job, is on.", []),
        ServiceStatus.Starting => new TroubleshootCheck(
            "spooler", CheckStatus.Warning, "Print spooler is starting",
            "Wait a moment, then select Refresh.",
            [TroubleshootAction.Refresh],
            "The Print Spooler, which queues every print job, is starting."),
        ServiceStatus.Stopped or ServiceStatus.Stopping or ServiceStatus.Paused => new TroubleshootCheck(
            "spooler", CheckStatus.Problem, "Print spooler is not running",
            "Restarting the PC usually starts it again.",
            [TroubleshootAction.Refresh],
            "The Print Spooler, which queues every print job, is not running, so printers set up in Windows can't "
            + "print. To start it now, someone with administrator rights can start Print Spooler in Services."),
        ServiceStatus.Disabled => new TroubleshootCheck(
            "spooler", CheckStatus.Problem, "Print spooler is turned off",
            "An administrator can set it to Automatic in Services.",
            [TroubleshootAction.Refresh],
            "The Print Spooler, which queues every print job, is disabled, so printers set up in Windows can't print. "
            + "Someone with administrator rights can set its startup type to Automatic in Services, then restart the PC."),
        ServiceStatus.NotInstalled => new TroubleshootCheck(
            "spooler", CheckStatus.Problem, "Print spooler is missing",
            "Network printers can still print straight to the printer.",
            [TroubleshootAction.AddByAddress],
            "This copy of Windows has no Print Spooler service."),
        _ => null,
    };

    private static TroubleshootCheck? DiscoveryCheck(PrinterSnapshot snapshot)
    {
        if (snapshot.Discovery == DiscoveryStatus.Denied) return LocalNetworkDeniedCheck();
        string detail = string.IsNullOrWhiteSpace(snapshot.DiscoveryDetail) ? "" : $" ({snapshot.DiscoveryDetail.Trim().TrimEnd('.')})";
        return snapshot.Discovery switch
        {
            DiscoveryStatus.Searching => new TroubleshootCheck(
                "discovery", CheckStatus.Ok, "Looking for network printers",
                "Printers on the network appear as they answer.",
                [TroubleshootAction.AddByAddress],
                "The search has just started."),
            DiscoveryStatus.Running => new TroubleshootCheck(
                "discovery", CheckStatus.Ok, "Looking for network printers",
                snapshot.Printers.Count(printer => printer.Route != PrinterRoute.Demo && printer.IppEndpoint is not null) switch
                {
                    0 => "No network printer has been found on this network yet.",
                    1 => "1 network printer found.",
                    int count => $"{count} network printers found.",
                },
                [TroubleshootAction.AddByAddress],
                "A printer that doesn't appear can be added by its address."),
            DiscoveryStatus.Unavailable => new TroubleshootCheck(
                "discovery", CheckStatus.Warning, "Network search is not working",
                "You can still add a network printer by its address.",
                [TroubleshootAction.AddByAddress, TroubleshootAction.Refresh],
                $"{SearchingSystem(snapshot.Platform)} could not search the network for printers{detail}."),
            _ => null,
        };
    }

    /// <summary>
    /// The first problem the printer reports, as a check; the others are named in its more help. A paused printer has
    /// its own check.
    /// </summary>
    private static TroubleshootCheck? PrinterCheck(PrinterInfo printer)
    {
        var problems = printer.Problems.Where(problem => problem.Title != IppProblemText.Paused).ToList();
        if (problems.Count == 0) return null;
        var first = problems[0];
        string detail = first.Advice;
        string more = "";
        // An unknown error carries the printer's own message, which can be long.
        if (StatusLine.Words(detail) > 15)
        {
            more = detail;
            detail = IppProblemText.PrinterErrorAdvice;
        }
        if (problems.Count > 1)
        {
            string others = $"Also: {string.Join(", ", problems.Skip(1).Select(problem => problem.Title))}.";
            more = more.Length == 0 ? others : $"{more} {others}";
        }
        return new TroubleshootCheck(
            $"printer:{printer.Id}", first.IsError ? CheckStatus.Problem : CheckStatus.Warning,
            $"{first.Title}: {printer.Name}", detail, [TroubleshootAction.Refresh], more);
    }

    private static TroubleshootCheck StuckJobsCheck(StuckJobs jobs)
    {
        bool one = jobs.Count == 1;
        string waited = Duration(jobs.OldestMinutes);
        string more = one
            ? $"It has waited {waited}." + (jobs.AnyInError ? " It is in error." : "")
            : $"The oldest has waited {waited}." + (jobs.AnyInError ? " One of them is in error, which holds up the rest." : "");
        return new TroubleshootCheck(
            $"stuckJobs:{jobs.PrinterId}", jobs.AnyInError ? CheckStatus.Problem : CheckStatus.Warning,
            one ? $"1 job stuck on {jobs.PrinterName}" : $"{jobs.Count} jobs stuck on {jobs.PrinterName}",
            one ? "Clearing it lets new jobs print." : "Clearing them lets new jobs print.",
            [TroubleshootAction.ClearStuckJobs], more);
    }

    /// <summary>
    /// The iPhone cannot resume a printer, nor can any app resume one that has no queue here (a network printer alone), so
    /// the card says to press Resume on the printer and offers no button.
    /// </summary>
    private static TroubleshootCheck PausedCheck(PrinterInfo printer, AppPlatform platform)
    {
        bool byHand = platform == AppPlatform.Ios || !printer.Id.StartsWith("system:", StringComparison.Ordinal);
        return new(
            $"paused:{printer.Id}", CheckStatus.Problem, $"{printer.Name} is paused",
            byHand ? "Press Resume on the printer to let its jobs print." : "Resume it to let its jobs print.",
            byHand ? [] : [TroubleshootAction.ResumePrinter],
            "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer.");
    }

    private static string Duration(int minutes) => minutes switch
    {
        < 1 => "less than a minute",
        1 => "1 minute",
        < 120 => $"{minutes} minutes",
        < 2880 => $"{minutes / 60} hours",
        _ => $"{minutes / 1440} days",
    };

    private static IEnumerable<TroubleshootCheck> Tips(AppPlatform platform, bool canPrint)
    {
        if (platform == AppPlatform.Ios)
        {
            yield return new TroubleshootCheck(
                "networkPrinter", CheckStatus.Tip, "Printer on the same Wi-Fi?",
                "This device and the printer must be on the same Wi-Fi.",
                [TroubleshootAction.AddByAddress],
                "Guest networks and some VPNs hide printers. Try adding the printer by its address.");
            yield return new TroubleshootCheck(
                "localNetworkAccess", CheckStatus.Tip, "Local Network allowed?",
                "Lazy Print needs Local Network access to find printers.",
                [TroubleshootAction.OpenAppSettings],
                "Turn it on for Lazy Print in Settings. If it's on already, turn it off and on again.");
            yield return new TroubleshootCheck(
                "airPrint", CheckStatus.Tip, "Does it support AirPrint?",
                "Lazy Print prints to AirPrint and other driverless printers.",
                [],
                "A printer that needs its own driver doesn't appear, and iPhone and iPad can't use USB printers. "
                + "The printer's manual says whether it supports AirPrint.");
        }
        else if (platform == AppPlatform.Windows)
        {
            yield return new TroubleshootCheck(
                "usb", CheckStatus.Tip, "Connected by USB?",
                "Connect it directly and use the maker's driver or the one Windows offers.",
                [TroubleshootAction.OpenPrinterSettings, TroubleshootAction.Refresh],
                "Windows lists a USB printer only after its driver is installed. Get it from the maker's website, "
                + "or let Windows install the one it offers, then select Refresh. Printer settings show whether "
                + "Windows sees it.");
        }
        else
        {
            yield return new TroubleshootCheck(
                "usb", CheckStatus.Tip, "Connected by USB?",
                "Connect it directly and add it in Printers & Scanners.",
                [TroubleshootAction.OpenPrinterSettings, TroubleshootAction.Refresh],
                "macOS sets up most USB printers by itself. If Printers & Scanners doesn't show it either, "
                + "macOS doesn't see it.");
        }
        string refresh = platform == AppPlatform.Ios ? "tap" : "select";
        yield return new TroubleshootCheck(
            "asleep", CheckStatus.Tip, "Printer asleep?",
            $"Press any button on it, then {refresh} Refresh.",
            [TroubleshootAction.Refresh],
            "A printer in sleep mode can stop answering on the network until it wakes.");
        string computer = Computer(platform);
        yield return new TroubleshootCheck(
            "wifiDirect", CheckStatus.Tip, "On the printer's own Wi-Fi?",
            "A printer's own Wi-Fi is another network.",
            platform == AppPlatform.Ios ? [] : [TroubleshootAction.OpenNetworkSettings],
            $"A printer's own Wi-Fi (Wi-Fi Direct) hides it from the network this {computer} uses. Join the printer "
            + "to your Wi-Fi, or this " + computer + " to its network.");
        yield return new TroubleshootCheck(
            "otherApps", CheckStatus.Tip, "Still not listed?",
            "Restart the printer and close other printing apps.",
            [TroubleshootAction.Refresh],
            $"Turn the printer off and on. Close {OtherApps(platform)}. Some printers print only through their maker's app.");
        if (canPrint)
        {
            yield return new TroubleshootCheck(
                "testPage", CheckStatus.Tip, "Prints, but not right?",
                "Print a test page to check colors, lines and size.",
                [TroubleshootAction.PrintTestPage],
                "It has color bars, a gray ramp, a fine-line grid, a 1 inch square and a ruler. A ruler that measures "
                + "less than its label means the page was shrunk to fit.");
        }
    }

    /// <summary>The first text as a sentence, then the second; the first may be missing.</summary>
    private static string JoinSentences(string? first, string second)
    {
        string head = first?.Trim() ?? "";
        if (head.Length == 0) return second;
        if (!".!?".Contains(head[^1])) head += ".";
        return $"{head} {second}";
    }
}
