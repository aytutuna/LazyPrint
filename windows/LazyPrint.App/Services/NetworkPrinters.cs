using System.Net;
using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>
/// The network printers of the app: what <see cref="IppDiscovery"/> finds, and the addresses of ipp-hosts.json. An address
/// is asked with Get-Printer-Attributes when the app starts and again every minute while it does not answer; one that
/// answers is handed over as an <see cref="IppService"/> like a discovered one, so the printer list merges it by UUID.
/// </summary>
public sealed class NetworkPrinters : INetworkPrinters, IDisposable
{
    /// <summary>How often the addresses that did not answer are asked again.</summary>
    internal static readonly TimeSpan RecheckInterval = TimeSpan.FromMinutes(1);

    private readonly IppDiscovery _discovery = new();
    private readonly IppHostList _hosts;
    private readonly IppTrustStore _trust;
    private readonly TimeSpan _recheck;
    private readonly object _gate = new();
    private readonly Dictionary<PrinterAddress, Host> _manual = [];
    private CancellationTokenSource? _loop;
    private SynchronizationContext? _context;
    private bool _discover;

    /// <summary>An address of the host list and what asking it came to.</summary>
    private sealed record Host(bool Listed, string? Name, string? Uuid, string? Problem, IppService? Service);

    /// <param name="directory">Where ipp-hosts.json and ipp-trust.json are; the settings folder by default.</param>
    /// <param name="discover">Browse with the Windows device watcher; tests leave it off.</param>
    /// <param name="recheck">How often unanswered addresses are asked again; a minute by default.</param>
    public NetworkPrinters(string? directory = null, bool discover = true, TimeSpan? recheck = null)
    {
        directory ??= StoreFiles.DefaultDirectory;
        _hosts = new IppHostList(directory);
        _trust = new IppTrustStore(directory);
        _discover = discover;
        _recheck = recheck ?? RecheckInterval;
        _discovery.Changed += () => Changed?.Invoke();
    }

    public event Action? Changed;

    public IReadOnlyList<IppService> Services
    {
        get
        {
            lock (_gate)
            {
                return [.. _discovery.Services, .. _manual.Values.Select(h => h.Service).OfType<IppService>()];
            }
        }
    }

    public DiscoveryStatus Discovery => _discover ? _discovery.State : DiscoveryStatus.Unknown;

    public string? DiscoveryDetail => _discovery.Failure;

    public IReadOnlyList<ManualHostStatus> Hosts
    {
        get
        {
            lock (_gate)
            {
                return [.. _hosts.Load().Select(a => _manual.TryGetValue(a, out var host)
                    ? new ManualHostStatus(a.ToString(), host.Listed, host.Problem)
                    : new ManualHostStatus(a.ToString(), false))];
            }
        }
    }

    public void Start()
    {
        _context = SynchronizationContext.Current;
        if (_discover) _discovery.Start();
        StartLoop();
    }

    public void Restart()
    {
        if (_discover) _discovery.Restart();
        StartLoop();
    }

    public void Dispose()
    {
        _loop?.Cancel();
        _discovery.Dispose();
    }

    /// <summary>Checks the listed addresses now and keeps checking those that do not answer; a loop already running is replaced.</summary>
    private void StartLoop()
    {
        var loop = new CancellationTokenSource();
        _loop?.Cancel();
        _loop = loop;
        _ = Task.Run(() => CheckHostsAsync(loop.Token));
    }

    private async Task CheckHostsAsync(CancellationToken token)
    {
        bool onlyUnlisted = false;
        try
        {
            while (true)
            {
                var addresses = _hosts.Load();
                lock (_gate)
                {
                    foreach (var gone in _manual.Keys.Where(a => !addresses.Contains(a)).ToList()) _manual.Remove(gone);
                }
                var toCheck = addresses.Where(a => !onlyUnlisted || !IsListed(a)).ToList();
                var checks = toCheck.Select(a => (Address: a, Check: Probe(a, token))).ToList();
                foreach (var (address, check) in checks)
                {
                    var result = await check;
                    lock (_gate) _manual[address] = ToHost(address, result);
                }
                PostChanged();
                lock (_gate)
                {
                    if (addresses.All(a => _manual.TryGetValue(a, out var host) && host.Listed)) return;
                }
                await Task.Delay(_recheck, token);
                onlyUnlisted = true;
            }
        }
        catch (OperationCanceledException)
        {
            // Replaced by a newer loop, or the app is closing.
        }
    }

    private bool IsListed(PrinterAddress address)
    {
        lock (_gate) return _manual.TryGetValue(address, out var host) && host.Listed;
    }

    /// <summary>
    /// An address in the list: a new certificate is trusted on first use, since the user put the address there. A changed
    /// one lists nothing (the service would not be reachable), and the problem says so.
    /// </summary>
    private async Task<AddressCheck> Probe(PrinterAddress address, CancellationToken token)
    {
        var result = await CheckAsync(address, null, token);
        if (result.Certificate is not { Verdict: IppTrustVerdict.Unknown, CanTrust: true } certificate) return result;
        return await CheckAsync(address, certificate.Fingerprint, token);
    }

    private static Host ToHost(PrinterAddress address, AddressCheck result) =>
        result.Capabilities is { } caps
            ? new Host(true, caps.Name, caps.Uuid, null, ServiceOf(result.Address, caps))
            : new Host(false, null, null, result.Certificate?.Message ?? result.Error, null);

    /// <summary>
    /// The service an address that answered stands for: its host as an address or a name, its resource path and what the
    /// printer says of itself in the TXT keys <see cref="IppEndpoint"/> uses.
    /// </summary>
    internal static IppService ServiceOf(PrinterAddress address, PrinterCapabilities caps)
    {
        bool ip = IPAddress.TryParse(address.Host, out _);
        var txt = new List<string> { $"rp={address.ResourcePath}" };
        if (caps.MakeAndModel.Length > 0) txt.Add($"ty={caps.MakeAndModel}");
        if (caps.Uuid is { Length: > 0 } uuid) txt.Add($"UUID={uuid}");
        string name = caps.Name.Length > 0 ? caps.Name : caps.MakeAndModel.Length > 0 ? caps.MakeAndModel : address.Host;
        return new IppService("address:" + address, name, address.Secure, ip ? null : address.Host,
                              ip ? [address.Host] : [], address.Port, txt);
    }

    public async Task<AddressCheck> ReadAsync(IppEndpoint endpoint, CancellationToken token)
    {
        AddressCheck? last = null;
        AddressCheck? refused = null;
        foreach (var address in endpoint.Addresses)
        {
            // A new certificate is not pinned by discovery: it is shown when the user selects or prints to the printer.
            // The other addresses still tell how the printer is.
            var result = await CheckAsync(address, endpoint.Uuid, endpoint.Name, null, token);
            if (result.Certificate is not null) refused ??= result;
            else if (result.Capabilities is not null) return result with { Certificate = refused?.Certificate };
            else last = result;
        }
        return refused ?? last ?? new AddressCheck(endpoint.Addresses[0], null, null, "it has no address");
    }

    public Task<AddressCheck> CheckAsync(PrinterAddress address, string? firstUse, CancellationToken token) =>
        CheckAsync(address, null, address.ToString(), firstUse, token);

    private async Task<AddressCheck> CheckAsync(PrinterAddress address, string? uuid, string name, string? firstUse,
                                                CancellationToken token)
    {
        var validator = new IppCertificateValidator(_trust, uuid, name, firstUse);
        using var client = new IppClient(address, validator.CreateHandler(), name, Environment.UserName, validator);
        try
        {
            var capabilities = await client.CapabilitiesAsync(token);
            return new AddressCheck(client.Address, capabilities, null, null);
        }
        catch (IppCertificateException e)
        {
            return new AddressCheck(address, null, e, null);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw;
        }
        catch (PrintException e)
        {
            return new AddressCheck(address, null, null, e.Message);
        }
    }

    public void Add(PrinterAddress address, PrinterCapabilities capabilities)
    {
        _hosts.Add(address);
        lock (_gate) _manual[address] = ToHost(address, new AddressCheck(address, capabilities, null, null));
        PostChanged();
        // The checks of the other addresses go on, or start if every address answered before.
        if (_loop is null || _loop.IsCancellationRequested) StartLoop();
    }

    public void Trust(IppCertificateException certificate, string? deviceUuid, string name) =>
        _trust.Trust(certificate.Fingerprint, deviceUuid ?? certificate.DeviceUuid, certificate.Authority, name);

    /// <summary>Raises <see cref="Changed"/> on the thread the search was started on.</summary>
    private void PostChanged()
    {
        if (_context is { } context) context.Post(_ => Changed?.Invoke(), null);
        else Changed?.Invoke();
    }
}
