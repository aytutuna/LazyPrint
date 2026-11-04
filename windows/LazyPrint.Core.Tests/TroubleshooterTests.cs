using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/TroubleshooterTests.swift: the same cases.
// C#-only case: OperationCanceledException in PrinterFailure.From (Swift has CancellationError instead, tested there).

public class TroubleshooterTests
{
    private static readonly PrinterInfo Demo = new(PrinterMerge.DemoId, PrinterMerge.DemoName, null, null,
        PrinterRoute.Demo, null, false, PrinterState.Idle, [], []);

    private static PrinterInfo Queue(string name, PrinterProblem[]? problems = null) =>
        new("system:" + name, name, null, null, PrinterRoute.System, null, false, PrinterState.Idle, problems ?? [], []);

    private static readonly PrinterInfo LaserJet = Queue("HP LaserJet");

    private static PrinterInfo NetworkPrinter(string name) =>
        new("ipp:" + name, name, null, "192.168.1.20", PrinterRoute.Ipp, Endpoint(name), false, PrinterState.Idle, [], []);

    private static IppEndpoint Endpoint(string name)
    {
        var service = new IppService($"ipp:{name}", name, false, null, ["192.168.1.20"], 631, ["ty=Test"]);
        return IppEndpoint.Choose([service]).Single();
    }

    private static readonly PrinterProblem OutOfPaper = new(IppProblemText.OutOfPaper, IppProblemText.OutOfPaperAdvice, true);
    private static readonly PrinterProblem InkLow = new(IppProblemText.InkLow, IppProblemText.InkLowAdvice, false);
    private static readonly PrinterProblem Paused = new(IppProblemText.Paused, IppProblemText.PausedAdvice, true);

    private static List<string> Ids(IReadOnlyList<TroubleshootCheck> checks) => [.. checks.Select(c => c.Id)];

    private static TroubleshootCheck Check(IReadOnlyList<TroubleshootCheck> checks, string id) => checks.Single(c => c.Id == id);

    private static IReadOnlyList<TroubleshootCheck> Diagnose(PrinterSnapshot snapshot) => Troubleshooter.Diagnose(snapshot);

    /// <summary>A PC where everything that can be checked is fine.</summary>
    private static PrinterSnapshot HealthyWindows() => new()
    {
        Platform = AppPlatform.Windows,
        Printers = [Demo, NetworkPrinter("HP LaserJet")],
        Network = NetworkStatus.PrivateNetwork,
        Spooler = ServiceStatus.Running,
        Discovery = DiscoveryStatus.Running,
    };

    /// <summary>A PC where most things are wrong.</summary>
    private static PrinterSnapshot TroubledWindows() => new()
    {
        Platform = AppPlatform.Windows,
        Printers = [Demo, Queue("Brother", [OutOfPaper, InkLow]), Queue("Epson", [Paused])],
        Network = NetworkStatus.PublicNetwork,
        Spooler = ServiceStatus.Disabled,
        Discovery = DiscoveryStatus.Unavailable,
        DiscoveryDetail = "Access is denied.",
        ManualHosts = [new("192.168.1.50", false, "No printer answered at 192.168.1.50."), new("10.0.0.2", true)],
        StuckJobs = [new("system:Brother", "Brother", 3, 45, false)],
        LastFailure = new PrinterFailure("Brother", "The printer is busy", PrinterFailure.From("Brother", new PrintError.Busy())!.Problem),
    };

    // MARK: - iPhone and iPad (never produced on Windows)

    /// <summary>A phone on Wi-Fi that found a network printer.</summary>
    private static PrinterSnapshot HealthyPhone() => new()
    {
        Platform = AppPlatform.Ios,
        Printers = [Demo, NetworkPrinter("HP LaserJet")],
        Network = NetworkStatus.PrivateNetwork,
        Discovery = DiscoveryStatus.Running,
    };

    /// <summary>A phone off Wi-Fi, without Local Network access, with an address that does not answer.</summary>
    private static PrinterSnapshot TroubledPhone() => new()
    {
        Platform = AppPlatform.Ios,
        Printers = [Demo],
        Network = NetworkStatus.Offline,
        Discovery = DiscoveryStatus.Denied,
        ManualHosts = [new("192.168.1.50", false, "No printer answered at 192.168.1.50."), new("10.0.0.2", true)],
        LastFailure = new PrinterFailure("Office MFP", "Can't reach Office MFP: no answer in time"),
    };

    [Fact]
    public void HealthyWindows_ShowsWhatIsFineThenTheTips()
    {
        var snapshot = HealthyWindows();
        var checks = Diagnose(snapshot);
        Assert.Equal(["network", "spooler", "discovery", "usb", "asleep", "wifiDirect", "otherApps"], Ids(checks));
        Assert.Equal([CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Tip, CheckStatus.Tip, CheckStatus.Tip],
                     checks.Select(c => c.Status));
        Assert.Equal("1 printer found", Troubleshooter.Headline(snapshot));
        Assert.Equal("Nothing here stops printers from appearing. The tips below cover the usual causes.",
                     Troubleshooter.Summary(checks));
    }

    [Fact]
    public void ProblemsComeFirst_ThenWarnings_ThenTips()
    {
        var snapshot = TroubledWindows();
        var checks = Diagnose(snapshot);
        Assert.Equal(["lastFailure", "spooler", "printer:system:Brother", "paused:system:Epson", "network", "discovery",
                      "stuckJobs:system:Brother", "manualHost:192.168.1.50", "usb", "asleep", "wifiDirect", "otherApps"],
                     Ids(checks));
        Assert.Equal([CheckStatus.Problem, CheckStatus.Problem, CheckStatus.Problem, CheckStatus.Problem,
                      CheckStatus.Warning, CheckStatus.Warning, CheckStatus.Warning, CheckStatus.Warning,
                      CheckStatus.Tip, CheckStatus.Tip, CheckStatus.Tip, CheckStatus.Tip], checks.Select(c => c.Status));
        Assert.Equal("2 printers found", Troubleshooter.Headline(snapshot));
        Assert.Equal("4 problems and 4 warnings found.", Troubleshooter.Summary(checks));
        Assert.Equal("2 printers found · 4 problems, 4 warnings", Troubleshooter.Overview(snapshot, checks));
    }

    [Fact]
    public void Overview_IsOneLine()
    {
        var healthy = HealthyWindows();
        Assert.Equal("1 printer found", Troubleshooter.Overview(healthy, Diagnose(healthy)));
        var publicNetwork = new PrinterSnapshot { Printers = [Demo], Network = NetworkStatus.PublicNetwork };
        Assert.Equal("No printer found · 1 warning", Troubleshooter.Overview(publicNetwork, Diagnose(publicNetwork)));
        var offline = new PrinterSnapshot { Network = NetworkStatus.Offline };
        Assert.Equal("No printer found · 1 problem", Troubleshooter.Overview(offline, Diagnose(offline)));
    }

    /// <summary>Every check the fixtures make, on every platform.</summary>
    private static IEnumerable<TroubleshootCheck> EveryCheck()
    {
        var snapshots = new List<PrinterSnapshot> { HealthyWindows(), TroubledWindows(), HealthyPhone(), TroubledPhone() };
        foreach (var platform in Enum.GetValues<AppPlatform>())
        {
            foreach (var service in Enum.GetValues<ServiceStatus>()) snapshots.Add(HealthyWindows() with { Platform = platform, Spooler = service });
            foreach (var network in Enum.GetValues<NetworkStatus>()) snapshots.Add(HealthyWindows() with { Platform = platform, Network = network });
            foreach (var discovery in Enum.GetValues<DiscoveryStatus>())
            {
                snapshots.Add(HealthyWindows() with { Platform = platform, Discovery = discovery });
                snapshots.Add(new PrinterSnapshot { Platform = platform, Discovery = discovery, DiscoveryDetail = "NoSuchRecord." });
            }
            snapshots.Add(TroubledWindows() with { Platform = platform });
            snapshots.Add(new PrinterSnapshot { Platform = platform });
        }
        PrintError[] errors =
        [
            new PrintError.BadResponse(), new PrintError.Unreachable("Office MFP", "no answer"), new PrintError.Refused(0x0400, ""),
            new PrintError.NeedsDriver(), new PrintError.Busy(), new PrintError.CertificateChanged(), new PrintError.NeedsSignIn(),
            new PrintError.NoPrinter(),
        ];
        foreach (var error in errors)
        {
            foreach (var platform in Enum.GetValues<AppPlatform>())
            {
                snapshots.Add(new PrinterSnapshot { Platform = platform, LastFailure = PrinterFailure.From("Office MFP", error) });
            }
        }
        foreach (var verdict in new[] { IppTrustVerdict.Unknown, IppTrustVerdict.Changed, IppTrustVerdict.Invalid })
        {
            var certificate = new IppCertificateException(verdict, "Office MFP", null, "192.168.1.9:631", "ab", "CN=x");
            snapshots.Add(new PrinterSnapshot { LastFailure = PrinterFailure.From("Office MFP", certificate) });
        }
        PrinterProblem[] problems =
        [
            OutOfPaper, InkLow, new(IppProblemText.Offline, IppProblemText.OfflineAdvice, true),
            new(IppProblemText.PrinterError, "The printer has a long message of its own that says so in more than fifteen words.", true),
        ];
        foreach (var problem in problems) snapshots.Add(new PrinterSnapshot { Printers = [Queue("Office", [problem, InkLow])] });
        snapshots.Add(new PrinterSnapshot { StuckJobs = [new("a", "Office", 1, 0, true), new("b", "Home", 5, 3000, false)] });
        return snapshots.SelectMany(Diagnose);
    }

    [Fact]
    public void EveryCheck_HasAShortTitle_AndAOneLineDetail_TheRestIsMoreHelp()
    {
        foreach (var check in EveryCheck())
        {
            Assert.InRange(StatusLine.Words(check.Title), 1, 6);
            Assert.InRange(StatusLine.Words(check.Detail), 1, 15);
            Assert.Equal(check.More.Length == 0 ? check.Detail : $"{check.Detail} {check.More}", check.FullDetail);
            Assert.DoesNotContain(check.Detail, check.More);
        }
        foreach (var action in Enum.GetValues<TroubleshootAction>())
        {
            foreach (var platform in Enum.GetValues<AppPlatform>())
            {
                Assert.InRange(StatusLine.Words(Troubleshooter.Label(action, platform)), 1, 3);
            }
        }
    }

    [Fact]
    public void EveryCheck_HasAStableIdAndAtMostThreeActions()
    {
        foreach (var check in EveryCheck())
        {
            Assert.NotEmpty(check.Id);
            Assert.InRange(check.Actions.Count, 0, 3);
        }
    }

    [Fact]
    public void NothingKnown_OnlyTheTips()
    {
        Assert.Equal(["usb", "asleep", "wifiDirect", "otherApps"], Ids(Diagnose(new PrinterSnapshot { Platform = AppPlatform.Windows })));
        Assert.Equal(["usb", "asleep", "wifiDirect", "otherApps"], Ids(Diagnose(new PrinterSnapshot { Platform = AppPlatform.Mac })));
    }

    [Fact]
    public void Windows_Tips()
    {
        var checks = Diagnose(HealthyWindows());
        Assert.Equal(new TroubleshootCheck(
            "usb", CheckStatus.Tip, "Connected by USB?",
            "Connect it directly and use the maker's driver or the one Windows offers.",
            [TroubleshootAction.OpenPrinterSettings, TroubleshootAction.Refresh],
            "Windows lists a USB printer only after its driver is installed. Get it from the maker's website, or let "
            + "Windows install the one it offers, then select Refresh. Printer settings show whether Windows sees it."),
            Check(checks, "usb"));
        Assert.Equal(new TroubleshootCheck(
            "asleep", CheckStatus.Tip, "Printer asleep?",
            "Press any button on it, then select Refresh.",
            [TroubleshootAction.Refresh],
            "A printer in sleep mode can stop answering on the network until it wakes."), Check(checks, "asleep"));
        var wifi = Check(checks, "wifiDirect");
        Assert.Equal(("On the printer's own Wi-Fi?", "A printer's own Wi-Fi is another network."), (wifi.Title, wifi.Detail));
        Assert.Equal("A printer's own Wi-Fi (Wi-Fi Direct) hides it from the network this PC uses. Join the printer to "
                     + "your Wi-Fi, or this PC to its network.", wifi.More);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings], wifi.Actions);
        var other = Check(checks, "otherApps");
        Assert.Equal(("Still not listed?", "Restart the printer and close other printing apps."), (other.Title, other.Detail));
        Assert.Equal("Turn the printer off and on. Close other printing apps. Some printers print only through their "
                     + "maker's app.", other.More);
    }

    [Fact]
    public void Mac_Tips_AndNoWindowsChecks()
    {
        var snapshot = TroubledWindows() with { Platform = AppPlatform.Mac, Discovery = DiscoveryStatus.Running };
        var checks = Diagnose(snapshot);
        Assert.DoesNotContain("spooler", Ids(checks));
        var usb = Check(checks, "usb");
        Assert.Equal("Connect it directly and add it in Printers & Scanners.", usb.Detail);
        Assert.Equal("macOS sets up most USB printers by itself. If Printers & Scanners doesn't show it either, macOS "
                     + "doesn't see it.", usb.More);
        Assert.Equal([TroubleshootAction.OpenPrinterSettings, TroubleshootAction.Refresh], usb.Actions);
        Assert.Contains("this Mac", Check(checks, "wifiDirect").More);
    }

    [Fact]
    public void Phone_Healthy_ShowsWhatIsFineThenItsTips()
    {
        var snapshot = HealthyPhone();
        var checks = Diagnose(snapshot);
        Assert.Equal(["network", "discovery", "networkPrinter", "localNetworkAccess", "airPrint", "asleep", "wifiDirect", "otherApps"],
                     Ids(checks));
        Assert.Equal("1 printer found", Troubleshooter.Overview(snapshot, checks));
        var network = Check(checks, "network");
        Assert.Equal(("Connected to a local network", "Network printers on this network can be found."), (network.Title, network.Detail));
        Assert.Equal(new TroubleshootCheck(
            "networkPrinter", CheckStatus.Tip, "Printer on the same Wi-Fi?",
            "This device and the printer must be on the same Wi-Fi.",
            [TroubleshootAction.AddByAddress],
            "Guest networks and some VPNs hide printers. Try adding the printer by its address."), Check(checks, "networkPrinter"));
        Assert.Equal(new TroubleshootCheck(
            "localNetworkAccess", CheckStatus.Tip, "Local Network allowed?",
            "Lazy Print needs Local Network access to find printers.",
            [TroubleshootAction.OpenAppSettings],
            "Turn it on for Lazy Print in Settings. If it's on already, turn it off and on again."), Check(checks, "localNetworkAccess"));
        Assert.Equal(new TroubleshootCheck(
            "airPrint", CheckStatus.Tip, "Does it support AirPrint?",
            "Lazy Print prints to AirPrint and other driverless printers.",
            [],
            "A printer that needs its own driver doesn't appear, and iPhone and iPad can't use USB printers. The "
            + "printer's manual says whether it supports AirPrint."), Check(checks, "airPrint"));
        Assert.Equal("Press any button on it, then tap Refresh.", Check(checks, "asleep").Detail);
        Assert.Empty(Check(checks, "wifiDirect").Actions);
        Assert.Equal("Turn the printer off and on. Close printing apps on other devices. Some printers print only "
                     + "through their maker's app.", Check(checks, "otherApps").More);
    }

    [Fact]
    public void Phone_Troubled_LocalNetworkAccessOffComesFirstWithSettings()
    {
        var snapshot = TroubledPhone();
        var checks = Diagnose(snapshot);
        Assert.Equal(["network", "localNetwork", "lastFailure", "manualHost:192.168.1.50", "networkPrinter", "localNetworkAccess",
                      "airPrint", "asleep", "wifiDirect", "otherApps"], Ids(checks));
        Assert.Equal("No printer found · 2 problems, 2 warnings", Troubleshooter.Overview(snapshot, checks));
        Assert.Equal(new TroubleshootCheck(
            "localNetwork", CheckStatus.Problem, "Local Network access is off",
            "Turn on Local Network for Lazy Print in Settings.",
            [TroubleshootAction.OpenAppSettings],
            "Without it, the app can't find or reach printers on your network. Printers appear as soon as it's on. "
            + "If it's on already, turn it off and on again."), Check(checks, "localNetwork"));
        Assert.Equal(new TroubleshootCheck(
            "network", CheckStatus.Problem, "Not connected to Wi-Fi",
            "Join the printer's Wi-Fi network, then tap Refresh.",
            [TroubleshootAction.Refresh],
            "Network printers are found only on Wi-Fi or a wired network."), Check(checks, "network"));
        Assert.Equal("Can't reach Office MFP: no answer in time. It must be on the same network as this device.",
                     Check(checks, "lastFailure").More);
        Assert.DoesNotContain("manualHost:10.0.0.2", Ids(checks));
    }

    [Fact]
    public void Phone_SearchStates_SayWhatIOSDoes()
    {
        string Detail(PrinterSnapshot s) => Check(Diagnose(s), "discovery").FullDetail;
        Assert.Equal("Printers on the network appear as they answer. The search has just started.",
                     Detail(HealthyPhone() with { Discovery = DiscoveryStatus.Searching }));
        var unavailable = Check(Diagnose(HealthyPhone() with
        {
            Discovery = DiscoveryStatus.Unavailable,
            DiscoveryDetail = "NoSuchRecord.",
        }), "discovery");
        Assert.Equal((CheckStatus.Warning, "Network search is not working"), (unavailable.Status, unavailable.Title));
        Assert.Equal("iOS could not search the network for printers (NoSuchRecord).", unavailable.More);
        Assert.DoesNotContain("discovery", Ids(Diagnose(HealthyPhone() with { Discovery = DiscoveryStatus.Off })));
        var denied = Diagnose(HealthyPhone() with { Discovery = DiscoveryStatus.Denied });
        Assert.DoesNotContain("discovery", Ids(denied));
        Assert.Contains("localNetwork", Ids(denied));
        // iOS has no public networks: any local network is fine; an unknown one has no check.
        Assert.Equal(CheckStatus.Ok, Check(Diagnose(HealthyPhone() with { Network = NetworkStatus.PublicNetwork }), "network").Status);
        Assert.DoesNotContain("network", Ids(Diagnose(HealthyPhone() with { Network = NetworkStatus.Unknown })));
    }

    [Fact]
    public void Phone_NeverOffersTheComputersActions_AndTheComputersNeverOfferSettings()
    {
        var computerActions = new[] { TroubleshootAction.OpenPrinterSettings, TroubleshootAction.OpenNetworkSettings };
        var phone = new List<TroubleshootCheck>();
        foreach (var snapshot in new[] { HealthyPhone(), TroubledPhone() })
        {
            foreach (var network in Enum.GetValues<NetworkStatus>())
            {
                foreach (var discovery in Enum.GetValues<DiscoveryStatus>())
                {
                    phone.AddRange(Diagnose(snapshot with { Network = network, Discovery = discovery }));
                }
            }
        }
        Assert.DoesNotContain(phone, c => c.Actions.Intersect(computerActions).Any());
        // Windows and the Mac never report denied access; the only check that offers the phone's Settings is the iPhone's tip.
        Assert.DoesNotContain(Diagnose(TroubledWindows()), c => c.Actions.Contains(TroubleshootAction.OpenAppSettings));
        Assert.DoesNotContain(Diagnose(HealthyWindows() with { Platform = AppPlatform.Mac }),
                              c => c.Actions.Contains(TroubleshootAction.OpenAppSettings));
    }

    // MARK: - The last failure

    [Fact]
    public void BusyPrinter_SaysToCloseOtherApps()
    {
        var check = Check(Diagnose(TroubledWindows()), "lastFailure");
        Assert.Equal(new TroubleshootCheck(
            "lastFailure", CheckStatus.Problem, "Printer busy: Brother",
            "Wait until it has finished, then print again.",
            [TroubleshootAction.Refresh],
            "A printer works on one job at a time; other printing apps may be using it."), check);
    }

    [Fact]
    public void FailureWithoutProblem_IsAWarningWithTheMessage()
    {
        var snapshot = new PrinterSnapshot
        {
            LastFailure = new PrinterFailure("Office MFP", "Can't reach Office MFP: no answer in time"),
        };
        var check = Check(Diagnose(snapshot), "lastFailure");
        Assert.Equal(CheckStatus.Warning, check.Status);
        Assert.Equal("Could not print to Office MFP", check.Title);
        Assert.Equal("Check that it is on, awake and connected.", check.Detail);
        Assert.Equal("Can't reach Office MFP: no answer in time. It must be connected by its cable or to the same "
                     + "network as this PC.", check.More);
        var mac = Check(Diagnose(snapshot with { Platform = AppPlatform.Mac }), "lastFailure");
        Assert.EndsWith("to the same network as this Mac.", mac.More);
    }

    [Fact]
    public void FailureWithAProblem_UsesItsTextAndSeverity()
    {
        var error = Check(Diagnose(new PrinterSnapshot
        {
            LastFailure = new PrinterFailure("Office", "x", new PrinterProblem("Cover open", "Close the cover or door, then press Resume.", true)),
        }), "lastFailure");
        Assert.Equal((CheckStatus.Problem, "Cover open: Office"), (error.Status, error.Title));
        Assert.Equal("Close the cover or door, then press Resume.", error.Detail);
        Assert.Equal("", error.More);
        var warning = Check(Diagnose(new PrinterSnapshot
        {
            LastFailure = new PrinterFailure("Office", "x", new PrinterProblem("Ink low", "Order a new cartridge soon.", false)),
        }), "lastFailure");
        Assert.Equal(CheckStatus.Warning, warning.Status);
    }

    [Fact]
    public void FailureFrom_MapsPrintErrors()
    {
        Assert.Equal(new PrinterFailure("Acme", "The printer's answer could not be read"),
                     PrinterFailure.From("Acme", new PrintError.BadResponse()));
        Assert.Equal(new PrinterFailure("Acme", "Can't reach Acme: gone"),
                     PrinterFailure.From("Acme", new PrintError.Unreachable("Acme", "gone")));
        Assert.Equal(new PrinterFailure("Acme", "Out of paper"), PrinterFailure.From("Acme", new PrintError.Refused(0x0507, "Out of paper")));

        var busy = PrinterFailure.From("Acme", new PrintError.Busy())!;
        Assert.Equal(("The printer is busy", "Printer busy", true), (busy.Message, busy.Problem!.Title, busy.Problem.IsError));
        var driver = PrinterFailure.From("Acme", new PrintError.NeedsDriver())!;
        Assert.Equal(("Needs its driver", "Install the maker's driver, then print again."), (driver.Problem!.Title, driver.Problem.Advice));
        var signIn = PrinterFailure.From("Acme", new PrintError.NeedsSignIn())!;
        Assert.Equal(("Needs a sign-in", "Lazy Print can't sign in to printers yet."), (signIn.Problem!.Title, signIn.Problem.Advice));
        var changed = PrinterFailure.From("Acme", new PrintError.CertificateChanged())!;
        Assert.Equal(("Certificate changed", true), (changed.Problem!.Title, changed.Problem.IsError));

        // A page that could not be prepared says nothing about reaching the printer.
        Assert.Null(PrinterFailure.From("Acme", new PrintError.BadRaster(1, 2, 3)));
        // Nor does a file that can't be read.
        Assert.Null(PrinterFailure.From("Acme", new PrintError.Unreadable(DocumentText.Unreadable)));
        Assert.Equal(busy, PrinterFailure.From("Acme", new PrintException(new PrintError.Busy())));
    }

    [Fact]
    public void FailureFrom_MapsCertificateErrors()
    {
        IppCertificateException Error(IppTrustVerdict verdict) =>
            new(verdict, "Acme", null, "192.168.1.9:631", "ab", "CN=Acme");
        var changed = PrinterFailure.From("Acme", Error(IppTrustVerdict.Changed))!;
        Assert.Equal(("Certificate changed", "Check the printer, then trust it again.", true),
                     (changed.Problem!.Title, changed.Problem.Advice, changed.Problem.IsError));
        Assert.Contains("has changed since you trusted it", changed.Message);
        foreach (var verdict in new[] { IppTrustVerdict.Unknown, IppTrustVerdict.Invalid })
        {
            var untrusted = PrinterFailure.From("Acme", Error(verdict))!;
            Assert.Equal(("Certificate not trusted", false), (untrusted.Problem!.Title, untrusted.Problem.IsError));
        }
        var check = Check(Diagnose(new PrinterSnapshot { LastFailure = PrinterFailure.From("Acme", Error(IppTrustVerdict.Unknown)) }),
                          "lastFailure");
        Assert.Equal((CheckStatus.Warning, "Certificate not trusted: Acme"), (check.Status, check.Title));
    }

    [Fact]
    public void FailureFrom_IgnoresCancellation()
    {
        Assert.Null(PrinterFailure.From("Acme", new OperationCanceledException()));
        Assert.Equal(new PrinterFailure("Acme", "boom"), PrinterFailure.From("Acme", new InvalidOperationException("boom")));
    }

    // MARK: - Network, spooler, search

    [Fact]
    public void Network()
    {
        var offline = Check(Diagnose(HealthyWindows() with { Network = NetworkStatus.Offline }), "network");
        Assert.Equal((CheckStatus.Problem, "Not connected to a network"), (offline.Status, offline.Title));
        Assert.Equal("Connect to the network the printer is on, then select Refresh.", offline.Detail);
        Assert.Equal("This PC is not on a network, so network printers can't be found. Printers connected by USB are "
                     + "not affected.", offline.More);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings, TroubleshootAction.Refresh], offline.Actions);

        var publicNetwork = Check(Diagnose(HealthyWindows() with { Network = NetworkStatus.PublicNetwork }), "network");
        Assert.Equal((CheckStatus.Warning, "Network set to Public"), (publicNetwork.Status, publicNetwork.Title));
        Assert.Equal("Windows won't find network printers on a Public network.", publicNetwork.Detail);
        Assert.Equal("If this is your home or office network, set it to Private in network settings. You can also add "
                     + "the printer by its address.", publicNetwork.More);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings, TroubleshootAction.AddByAddress], publicNetwork.Actions);

        foreach (var status in new[] { NetworkStatus.PrivateNetwork, NetworkStatus.DomainNetwork })
        {
            var ok = Check(Diagnose(HealthyWindows() with { Network = status }), "network");
            Assert.Equal((CheckStatus.Ok, "Connected to a private network"), (ok.Status, ok.Title));
        }
        Assert.DoesNotContain("network", Ids(Diagnose(HealthyWindows() with { Network = NetworkStatus.Unknown })));
    }

    public static TheoryData<ServiceStatus, CheckStatus, string> SpoolerStates => new()
    {
        { ServiceStatus.Running, CheckStatus.Ok, "Print spooler is on" },
        { ServiceStatus.Starting, CheckStatus.Warning, "Print spooler is starting" },
        { ServiceStatus.Stopped, CheckStatus.Problem, "Print spooler is not running" },
        { ServiceStatus.Stopping, CheckStatus.Problem, "Print spooler is not running" },
        { ServiceStatus.Paused, CheckStatus.Problem, "Print spooler is not running" },
        { ServiceStatus.Disabled, CheckStatus.Problem, "Print spooler is turned off" },
        { ServiceStatus.NotInstalled, CheckStatus.Problem, "Print spooler is missing" },
    };

    [Theory]
    [MemberData(nameof(SpoolerStates))]
    public void Spooler(ServiceStatus service, CheckStatus status, string title)
    {
        var check = Check(Diagnose(HealthyWindows() with { Spooler = service }), "spooler");
        Assert.Equal(status, check.Status);
        Assert.Equal(title, check.Title);
        if (service != ServiceStatus.NotInstalled) Assert.Contains("Print Spooler", check.FullDetail);
    }

    [Fact]
    public void Spooler_UnknownHasNoCheck_AndOnlyWindowsHasOne()
    {
        Assert.DoesNotContain("spooler", Ids(Diagnose(HealthyWindows() with { Spooler = ServiceStatus.Unknown })));
        Assert.DoesNotContain("spooler", Ids(Diagnose(HealthyWindows() with { Platform = AppPlatform.Mac })));
        Assert.DoesNotContain("spooler", Ids(Diagnose(HealthyWindows() with { Platform = AppPlatform.Ios })));
    }

    [Fact]
    public void DisabledSpooler_SaysHowToTurnItOnWithoutDoingIt()
    {
        var check = Check(Diagnose(HealthyWindows() with { Spooler = ServiceStatus.Disabled }), "spooler");
        Assert.Equal("An administrator can set it to Automatic in Services.", check.Detail);
        Assert.Equal("The Print Spooler, which queues every print job, is disabled, so printers set up in Windows can't "
                     + "print. Someone with administrator rights can set its startup type to Automatic in Services, then "
                     + "restart the PC.", check.More);
        Assert.Equal([TroubleshootAction.Refresh], check.Actions);
        Assert.Equal([TroubleshootAction.AddByAddress],
                     Check(Diagnose(HealthyWindows() with { Spooler = ServiceStatus.NotInstalled }), "spooler").Actions);
    }

    [Fact]
    public void NetworkSearch()
    {
        string Detail(PrinterSnapshot s) => Check(Diagnose(s), "discovery").FullDetail;
        Assert.Equal("1 network printer found. A printer that doesn't appear can be added by its address.", Detail(HealthyWindows()));
        Assert.Equal("No network printer has been found on this network yet. A printer that doesn't appear can be added by its address.",
                     Detail(HealthyWindows() with { Printers = [Demo, LaserJet] }));
        Assert.Equal("2 network printers found. A printer that doesn't appear can be added by its address.",
                     Detail(HealthyWindows() with { Printers = [Demo, NetworkPrinter("A"), NetworkPrinter("B")] }));
        Assert.Equal("Printers on the network appear as they answer. The search has just started.",
                     Detail(HealthyWindows() with { Discovery = DiscoveryStatus.Searching }));
        var running = Check(Diagnose(HealthyWindows()), "discovery");
        Assert.Equal((CheckStatus.Ok, "Looking for network printers"), (running.Status, running.Title));
        Assert.Equal([TroubleshootAction.AddByAddress], running.Actions);

        var unavailable = Check(Diagnose(TroubledWindows()), "discovery");
        Assert.Equal((CheckStatus.Warning, "Network search is not working"), (unavailable.Status, unavailable.Title));
        Assert.Equal("You can still add a network printer by its address.", unavailable.Detail);
        Assert.Equal("Windows could not search the network for printers (Access is denied).", unavailable.More);
        Assert.Equal([TroubleshootAction.AddByAddress, TroubleshootAction.Refresh], unavailable.Actions);
        var mac = Check(Diagnose(TroubledWindows() with { Platform = AppPlatform.Mac }), "discovery");
        Assert.StartsWith("macOS could not search", mac.More);
        Assert.DoesNotContain("discovery", Ids(Diagnose(HealthyWindows() with { Discovery = DiscoveryStatus.Off })));
        Assert.DoesNotContain("discovery", Ids(Diagnose(HealthyWindows() with { Discovery = DiscoveryStatus.Unknown })));
    }

    // MARK: - Printers

    [Fact]
    public void PrinterProblems_AreChecksNamedByThePrinter()
    {
        var checks = Diagnose(new PrinterSnapshot { Printers = [Demo, Queue("HP LaserJet", [OutOfPaper, InkLow]), Queue("Epson", [InkLow])] });
        Assert.Equal(new TroubleshootCheck(
            "printer:system:HP LaserJet", CheckStatus.Problem, "Out of paper: HP LaserJet",
            "Load paper in the tray, then press Resume.", [TroubleshootAction.Refresh], "Also: Ink low."),
            Check(checks, "printer:system:HP LaserJet"));
        var low = Check(checks, "printer:system:Epson");
        Assert.Equal((CheckStatus.Warning, "Ink low: Epson", "Order a new cartridge soon.", ""), (low.Status, low.Title, low.Detail, low.More));
        Assert.DoesNotContain("printer:demo", Ids(checks));
        Assert.DoesNotContain("printer:system:Nobody", Ids(Diagnose(new PrinterSnapshot { Printers = [LaserJet] })));
    }

    [Fact]
    public void ALongPrinterMessage_MovesToMoreHelp()
    {
        const string message = "The printer has a long message of its own that says so in more than fifteen words.";
        var check = Check(Diagnose(new PrinterSnapshot
        {
            Printers = [Queue("Office", [new PrinterProblem(IppProblemText.PrinterError, message, true)])],
        }), "printer:system:Office");
        Assert.Equal(IppProblemText.PrinterErrorAdvice, check.Detail);
        Assert.Equal(message, check.More);
    }

    [Fact]
    public void APausedPrinter_OnThePhoneSaysToPressResumeOnIt()
    {
        var phone = new PrinterSnapshot { Platform = AppPlatform.Ios, Printers = [Queue("Epson", [Paused])] };
        Assert.Equal(new TroubleshootCheck(
            "paused:system:Epson", CheckStatus.Problem, "Epson is paused",
            "Press Resume on the printer to let its jobs print.", [],
            "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer."),
            Check(Diagnose(phone), "paused:system:Epson"));
    }

    [Fact]
    public void APausedPrinter_WithNoQueue_SaysToPressResumeOnIt()
    {
        var network = NetworkPrinter("Epson") with { State = PrinterState.Stopped, Problems = [Paused] };
        Assert.Equal(new TroubleshootCheck(
            "paused:ipp:Epson", CheckStatus.Problem, "Epson is paused",
            "Press Resume on the printer to let its jobs print.", [],
            "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer."),
            Check(Diagnose(new PrinterSnapshot { Printers = [network] }), "paused:ipp:Epson"));
    }

    [Fact]
    public void APausedPrinter_HasItsOwnCheckWithResume()
    {
        var checks = Diagnose(new PrinterSnapshot { Printers = [Queue("Epson", [Paused, InkLow])] });
        Assert.Equal(new TroubleshootCheck(
            "paused:system:Epson", CheckStatus.Problem, "Epson is paused",
            "Resume it to let its jobs print.", [TroubleshootAction.ResumePrinter],
            "Jobs wait while a printer is paused. If it stays paused, press Resume on the printer."),
            Check(checks, "paused:system:Epson"));
        // The pause is not repeated in the printer's problems.
        Assert.Equal("Ink low: Epson", Check(checks, "printer:system:Epson").Title);
        Assert.DoesNotContain("printer:system:Epson", Ids(Diagnose(new PrinterSnapshot { Printers = [Queue("Epson", [Paused])] })));
    }

    [Fact]
    public void StuckJobs_AreCountedAndCanBeCleared()
    {
        var checks = Diagnose(new PrinterSnapshot
        {
            StuckJobs = [new("system:HP", "HP LaserJet", 3, 45, false), new("system:Epson", "Epson", 1, 200, true), new("x", "Gone", 0, 0, false)],
        });
        Assert.Equal(new TroubleshootCheck(
            "stuckJobs:system:HP", CheckStatus.Warning, "3 jobs stuck on HP LaserJet",
            "Clearing them lets new jobs print.", [TroubleshootAction.ClearStuckJobs],
            "The oldest has waited 45 minutes."), Check(checks, "stuckJobs:system:HP"));
        Assert.Equal(new TroubleshootCheck(
            "stuckJobs:system:Epson", CheckStatus.Problem, "1 job stuck on Epson",
            "Clearing it lets new jobs print.", [TroubleshootAction.ClearStuckJobs],
            "It has waited 3 hours. It is in error."), Check(checks, "stuckJobs:system:Epson"));
        Assert.DoesNotContain("stuckJobs:x", Ids(checks));
    }

    [Theory]
    [InlineData(5, "5 minutes")]
    [InlineData(119, "119 minutes")]
    [InlineData(120, "2 hours")]
    [InlineData(3000, "2 days")]
    public void StuckJobs_SayHowLongTheOldestWaited(int minutes, string waited)
    {
        var check = Check(Diagnose(new PrinterSnapshot { StuckJobs = [new("a", "HP", 2, minutes, false)] }), "stuckJobs:a");
        Assert.Equal($"The oldest has waited {waited}.", check.More);
    }

    [Fact]
    public void StuckJobs_AJobThatIsPrintingNowIsNotStuck()
    {
        var checks = Diagnose(new PrinterSnapshot
        {
            StuckJobs = [new("a", "HP", 1, 0, false), new("b", "Epson", 2, 4, false), new("c", "Canon", 1, 0, true), new("d", "Brother", 1, 5, false)],
        });
        Assert.Equal(["stuckJobs:c", "stuckJobs:d"], Ids(checks).Where(id => id.StartsWith("stuckJobs:")));
    }

    [Fact]
    public void AddressesAddedByHand_OnlyThoseNotAnsweringAreChecks()
    {
        var checks = Diagnose(TroubledWindows());
        Assert.DoesNotContain("manualHost:10.0.0.2", Ids(checks));
        Assert.Equal(new TroubleshootCheck(
            "manualHost:192.168.1.50", CheckStatus.Warning, "No printer answers at 192.168.1.50",
            "Check that it is on and its address hasn't changed.",
            [TroubleshootAction.Refresh],
            "No printer answered at 192.168.1.50. Its network settings page or control panel shows the current address. "
            + "The app tries the address again every minute."), Check(checks, "manualHost:192.168.1.50"));
        foreach (var platform in Enum.GetValues<AppPlatform>())
        {
            var unchecked_ = Check(Diagnose(new PrinterSnapshot { Platform = platform, ManualHosts = [new("printer.local", false)] }),
                                   "manualHost:printer.local");
            Assert.StartsWith("Its network settings page", unchecked_.More);
        }
    }

    // MARK: - Headline, summary, labels, report

    [Fact]
    public void Headline_CountsPrintersButNotTheDemo()
    {
        Assert.Equal("No printer found", Troubleshooter.Headline(new PrinterSnapshot()));
        Assert.Equal("No printer found", Troubleshooter.Headline(new PrinterSnapshot { Printers = [Demo] }));
        Assert.Equal("1 printer found", Troubleshooter.Headline(new PrinterSnapshot { Printers = [Demo, LaserJet] }));
        Assert.Equal("2 printers found", Troubleshooter.Headline(new PrinterSnapshot { Printers = [Demo, LaserJet, Queue("Epson")] }));
    }

    [Fact]
    public void Summary_CountsProblemsAndWarnings()
    {
        TroubleshootCheck Make(CheckStatus status) => new("x", status, "t", "d", []);
        Assert.Equal("1 problem found.", Troubleshooter.Summary([Make(CheckStatus.Problem), Make(CheckStatus.Ok)]));
        Assert.Equal("1 warning found.", Troubleshooter.Summary([Make(CheckStatus.Warning), Make(CheckStatus.Tip)]));
        Assert.Equal("2 problems and 1 warning found.",
                     Troubleshooter.Summary([Make(CheckStatus.Problem), Make(CheckStatus.Warning), Make(CheckStatus.Problem)]));
    }

    [Fact]
    public void Labels()
    {
        Assert.Equal("Refresh", Troubleshooter.Label(TroubleshootAction.Refresh, AppPlatform.Windows));
        Assert.Equal("Add by address…", Troubleshooter.Label(TroubleshootAction.AddByAddress, AppPlatform.Windows));
        Assert.Equal("Add by address…", Troubleshooter.Label(TroubleshootAction.AddByAddress, AppPlatform.Ios));
        Assert.Equal("Printer settings", Troubleshooter.Label(TroubleshootAction.OpenPrinterSettings, AppPlatform.Windows));
        Assert.Equal("Printers & Scanners", Troubleshooter.Label(TroubleshootAction.OpenPrinterSettings, AppPlatform.Mac));
        Assert.Equal("Network settings", Troubleshooter.Label(TroubleshootAction.OpenNetworkSettings, AppPlatform.Mac));
        Assert.Equal("Copy diagnostics", Troubleshooter.Label(TroubleshootAction.CopyDiagnostics, AppPlatform.Mac));
        Assert.Equal("Open Settings", Troubleshooter.Label(TroubleshootAction.OpenAppSettings, AppPlatform.Ios));
        Assert.Equal("Clear stuck jobs", Troubleshooter.Label(TroubleshootAction.ClearStuckJobs, AppPlatform.Windows));
        Assert.Equal("Resume printer", Troubleshooter.Label(TroubleshootAction.ResumePrinter, AppPlatform.Mac));
        Assert.Equal("Print test page", Troubleshooter.Label(TroubleshootAction.PrintTestPage, AppPlatform.Windows));
        Assert.Equal(["OK", "Tip", "Warning", "Problem"],
                     new[] { CheckStatus.Ok, CheckStatus.Tip, CheckStatus.Warning, CheckStatus.Problem }.Select(Troubleshooter.StatusLabel));
    }

    [Fact]
    public void Actions_AreInTheContractsOrder()
    {
        Assert.Equal(["Refresh", "AddByAddress", "OpenPrinterSettings", "OpenNetworkSettings", "CopyDiagnostics", "OpenAppSettings",
                      "ClearStuckJobs", "ResumePrinter", "PrintTestPage"],
                     Enum.GetValues<TroubleshootAction>().Select(a => a.ToString()));
    }

    [Fact]
    public void Report_ListsEveryCheckWithItsDetail_AndItsMoreHelp()
    {
        var snapshot = HealthyWindows();
        var checks = Diagnose(snapshot);
        string report = Troubleshooter.Report(snapshot, checks);
        var lines = report.Split('\n');
        Assert.Equal("Why isn't my printer listed?", lines[0]);
        Assert.Equal("1 printer found. Nothing here stops printers from appearing. The tips below cover the usual causes.", lines[1]);
        Assert.Equal("OK: Connected to a private network", lines[2]);
        Assert.Equal("  Network printers on this network can be found.", lines[3]);
        Assert.Equal("Tip: Still not listed?", lines[^4]);
        Assert.Equal("  Restart the printer and close other printing apps.", lines[^3]);
        Assert.Equal("  Turn the printer off and on. Close other printing apps. Some printers print only through their "
                     + "maker's app.", lines[^2]);
        Assert.Equal("", lines[^1]);
        Assert.Equal(2 + 2 * checks.Count + checks.Count(c => c.More.Length > 0) + 1, lines.Length);
    }

    [Fact]
    public void CombineNetworks()
    {
        Assert.Equal(NetworkStatus.Offline, Troubleshooter.CombineNetworks([]));
        Assert.Equal(NetworkStatus.PublicNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PublicNetwork]));
        Assert.Equal(NetworkStatus.PublicNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PublicNetwork, NetworkStatus.PrivateNetwork]));
        Assert.Equal(NetworkStatus.PrivateNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PrivateNetwork]));
        Assert.Equal(NetworkStatus.DomainNetwork, Troubleshooter.CombineNetworks([NetworkStatus.PrivateNetwork, NetworkStatus.DomainNetwork]));
        Assert.Equal(NetworkStatus.Unknown, Troubleshooter.CombineNetworks([NetworkStatus.Unknown]));
        Assert.Equal(NetworkStatus.PublicNetwork, Troubleshooter.CombineNetworks([NetworkStatus.Unknown, NetworkStatus.PublicNetwork]));
    }
}
