using System.IO;
using LazyPrint.App;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Tests;

/// <summary>The spooler as the test says it is.</summary>
internal sealed class FakePrinterSystem : IPrinterSystem
{
    public List<SystemPrinter> Queue { get; } = [];
    public Dictionary<string, PrinterCapabilities> Capable { get; } = [];
    public bool Throws { get; set; }
    public List<string> Cleared { get; } = [];
    public List<string> Resumed { get; } = [];

    public IReadOnlyList<SystemPrinter> Queues() => Throws ? throw new InvalidOperationException("The spooler is not running.") : [.. Queue];

    public PrinterCapabilities? Capabilities(string queueName) => Capable.GetValueOrDefault(queueName);

    public void ClearJobs(string queueName) => Cleared.Add(queueName);

    public void Resume(string queueName) => Resumed.Add(queueName);
}

internal sealed class FakeLoader : IDocumentLoader
{
    /// <summary>The pages of every file it opens.</summary>
    public IReadOnlyList<LayoutSize> Pages { get; set; } = [new LayoutSize(612, 792)];

    public Task<LoadedDocument> LoadAsync(string path, CancellationToken token) =>
        path.Contains(".bad", StringComparison.Ordinal)
            ? throw new InvalidOperationException("Lazy Print prints PDFs and pictures. Save it as a PDF first.")
            : Task.FromResult(new LoadedDocument(Path.GetFileName(path), new DocumentKind.Pdf(false), Pages));
}

internal sealed class FakeSheetPrinter : ISheetPrinter
{
    /// <summary>Every pass sent, in order, with the pass.</summary>
    public List<(SheetJob Job, int Pass)> Passes { get; } = [];
    public IEnumerable<SheetJob> Jobs => Passes.Select(sent => sent.Job);
    public Exception? Fails { get; set; }

    /// <summary>Runs while a pass is being printed; a test holds the job here.</summary>
    public Func<SheetJob, int, CancellationToken, Task>? While { get; set; }

    public async Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        if (Fails is not null) throw Fails;
        Passes.Add((job, pass));
        if (While is not null) await While(job, pass, token);
    }
}

internal sealed class FakeDiagnostics : ISystemDiagnostics
{
    public bool LazyScan { get; set; }
    public bool LazyScanOpened { get; private set; }
    public string? Copied { get; private set; }
    public List<TroubleshootAction> Opened { get; } = [];

    public ServiceStatus SpoolerState { get; set; } = ServiceStatus.Running;
    public NetworkStatus NetworkState { get; set; } = NetworkStatus.PrivateNetwork;

    public ServiceStatus Spooler() => SpoolerState;

    public NetworkStatus Network() => NetworkState;

    public void OpenSettings(TroubleshootAction action) => Opened.Add(action);

    public void CopyText(string text) => Copied = text;

    public bool LazyScanInstalled() => LazyScan;

    public void OpenLazyScan() => LazyScanOpened = true;

    public List<string> Folders { get; } = [];

    public void OpenFolder(string path) => Folders.Add(path);
}

/// <summary>The network as the test says it is: the services found, and what each printer answers.</summary>
internal sealed class FakeNetwork : INetworkPrinters
{
    public List<IppService> Found { get; } = [];
    public List<ManualHostStatus> HostList { get; } = [];
    public DiscoveryStatus State { get; set; } = DiscoveryStatus.Running;
    public string? Detail { get; set; }
    /// <summary>What a printer answers, by the name of its endpoint; a printer not here does not answer.</summary>
    public Dictionary<string, AddressCheck> Answers { get; } = [];
    public List<IppCertificateException> Trusted { get; } = [];
    public int Restarts { get; private set; }
    public int Reads { get; private set; }

    public event Action? Changed;

    public IReadOnlyList<IppService> Services => [.. Found];
    public DiscoveryStatus Discovery => State;
    public string? DiscoveryDetail => Detail;
    public IReadOnlyList<ManualHostStatus> Hosts => [.. HostList];

    public void Start() { }

    public void Restart() => Restarts++;

    public void Raise() => Changed?.Invoke();

    public Task<AddressCheck> ReadAsync(IppEndpoint endpoint, CancellationToken token)
    {
        Reads++;
        return Task.FromResult(Answers.GetValueOrDefault(endpoint.Name) ?? new AddressCheck(endpoint.Addresses[0], null, null, "it did not answer in time"));
    }

    public Task<AddressCheck> CheckAsync(PrinterAddress address, string? firstUse, CancellationToken token) =>
        Task.FromResult(new AddressCheck(address, null, null, "it did not answer in time"));

    public void Add(PrinterAddress address, PrinterCapabilities capabilities) { }

    public void Trust(IppCertificateException certificate, string? deviceUuid, string name) => Trusted.Add(certificate);
}

/// <summary>A view model on stand-ins and a settings folder of its own, removed afterwards.</summary>
internal sealed class Rig : IDisposable
{
    public FakePrinterSystem Spooler { get; } = new();
    public FakeLoader Loader { get; } = new();
    public FakeSheetPrinter Sheets { get; } = new();
    public FakeDiagnostics Diagnostics { get; } = new();
    public FakeNetwork Network { get; } = new();
    public string Directory { get; } = Path.Combine(Path.GetTempPath(), "lazyprint-tests-" + Guid.NewGuid().ToString("N"));
    public string LogDirectory => Path.Combine(Directory, "logs");
    public AppViewModel Model { get; private set; }

    public Rig()
    {
        Model = Open();
    }

    /// <summary>A second view model on the same folder, as the next start of the app.</summary>
    public AppViewModel Open() =>
        Model = new AppViewModel(Spooler, Loader, Sheets, Diagnostics, Directory, network: Network, logDirectory: LogDirectory);

    public static SystemPrinter Queue(string name, bool isDefault = false, params SystemQueueState[] states) =>
        new(name, "Driver", "IP_192.168.1.20", isDefault, false, states, SystemQueueJobs.None);

    public static PrinterCapabilities Duplex() => new()
    {
        SidesSupported = ["one-sided", "two-sided-long-edge"],
        PrintColorModesSupported = ["color", "monochrome"],
        CopiesSupported = (1, 99),
    };

    public void Dispose()
    {
        if (System.IO.Directory.Exists(Directory)) System.IO.Directory.Delete(Directory, true);
    }
}
