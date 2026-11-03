using System.Globalization;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppTrust.swift (the TLS hook and the certificate type differ).
//
// Printers make their own certificates, so one is trusted the first time the app connects (trust on first use) and
// pinned by the SHA-256 of its public key in ipp-trust.json; a different key for a known printer is refused until
// the user trusts it.

/// <summary>What the trust store says about a certificate a printer presented.</summary>
public enum IppTrustVerdict
{
    /// <summary>Neither this certificate nor the printer has been trusted before.</summary>
    Unknown,
    /// <summary>The certificate is trusted (pinned, or valid for Windows).</summary>
    Trusted,
    /// <summary>The printer was trusted with a different certificate.</summary>
    Changed,
    /// <summary>The printer presented no certificate that could be pinned.</summary>
    Invalid,
}

/// <summary>One trusted printer certificate (an entry of ipp-trust.json).</summary>
public sealed class IppTrustedCertificate
{
    /// <summary>SHA-256 of the certificate's public key (SubjectPublicKeyInfo), lowercase hex.</summary>
    public string Fingerprint { get; set; } = "";
    /// <summary>The printer's UUID (<see cref="IppTxtRecord.UuidKey"/>); "" when it was not known.</summary>
    public string DeviceUuid { get; set; } = "";
    /// <summary>Where the certificate was seen ("host:port", see <see cref="PrinterAddress.Authority"/>).</summary>
    public List<string> Addresses { get; set; } = [];
    /// <summary>The printer's name when it was trusted (for people reading the file).</summary>
    public string Name { get; set; } = "";
    /// <summary>When the user trusted it.</summary>
    public DateTimeOffset? Trusted { get; set; }
}

/// <summary>The contents of ipp-trust.json.</summary>
public sealed class IppTrustFile
{
    public List<IppTrustedCertificate> Certificates { get; set; } = [];
}

/// <summary>
/// The trusted printer certificates (ipp-trust.json), safe to use from any thread. The file
/// is re-read for every check and before every write, since several windows of the app may
/// share it; certificates trusted while the file could not be written stay trusted for the
/// rest of the session. It follows the settings-file rules (CONTRACTS.md, Global rule 5).
/// </summary>
public sealed class IppTrustStore
{
    /// <summary>Addresses remembered per certificate; the oldest are dropped beyond this.</summary>
    private const int MaxAddresses = 8;

    private readonly string _path;
    private readonly object _gate = new();
    private IppTrustFile _file;
    /// <summary>Certificates trusted (and the address they were trusted at) that are not in the file yet: its last write failed.</summary>
    private readonly List<(IppTrustedCertificate Pin, string Address)> _unsaved = [];

    public IppTrustStore() : this(StoreFiles.DefaultDirectory) { }

    /// <summary>Keeps ipp-trust.json in <paramref name="directory"/> instead of %APPDATA% (tests, harnesses).</summary>
    public IppTrustStore(string directory)
    {
        _path = Path.Combine(directory, "ipp-trust.json");
        _file = StoreFiles.Load<IppTrustFile>(_path) ?? new IppTrustFile();
    }

    /// <summary>
    /// Whether <paramref name="fingerprint"/> may be trusted for the printer with
    /// <paramref name="deviceUuid"/> (null when unknown) at <paramref name="authority"/>.
    /// A pinned public key is trusted wherever it shows up (only the printer holds its private
    /// key); the address it was reached at, and the printer's UUID when the pin did not have
    /// one, are remembered. Otherwise, a printer trusted before with another key — the same
    /// UUID, or, when either UUID is unknown, the same address — is
    /// <see cref="IppTrustVerdict.Changed"/> (<paramref name="previous"/> is that entry). A
    /// pinned key that claims the UUID of a printer trusted with another key is Changed too:
    /// a key vouches only for the printer it was trusted for.
    /// </summary>
    public IppTrustVerdict Check(string fingerprint, string? deviceUuid, string authority,
                                  out IppTrustedCertificate? previous)
    {
        previous = null;
        if (fingerprint.Length == 0) return IppTrustVerdict.Invalid;
        string uuid = IppTxtRecord.UuidKey(deviceUuid) ?? "";
        string address = authority.ToLowerInvariant();
        lock (_gate)
        {
            Reload();
            if (_file.Certificates.FirstOrDefault(c => c.Fingerprint == fingerprint) is { } pinned)
            {
                if (uuid.Length > 0 && pinned.DeviceUuid != uuid
                    && _file.Certificates.FirstOrDefault(c => c.DeviceUuid == uuid) is { } other)
                {
                    previous = other;
                    return IppTrustVerdict.Changed;
                }
                bool learned = false;
                if (pinned.DeviceUuid.Length == 0 && uuid.Length > 0)
                {
                    pinned.DeviceUuid = uuid;
                    learned = true;
                }
                if (!pinned.Addresses.Contains(address))
                {
                    pinned.Addresses.Add(address);
                    if (pinned.Addresses.Count > MaxAddresses) pinned.Addresses.RemoveAt(0);
                    learned = true;
                }
                if (learned) Save();
                return IppTrustVerdict.Trusted;
            }
            previous = _file.Certificates.FirstOrDefault(c => SamePrinter(c, uuid, address));
            return previous is null ? IppTrustVerdict.Unknown : IppTrustVerdict.Changed;
        }
    }

    /// <summary>
    /// Trusts <paramref name="fingerprint"/> for a printer, replacing whatever was trusted for
    /// that printer before (see <see cref="Check"/>), and saves the file.
    /// </summary>
    public void Trust(string fingerprint, string? deviceUuid, string authority, string name)
    {
        if (fingerprint.Length == 0) throw new ArgumentException("No certificate to trust.", nameof(fingerprint));
        string uuid = IppTxtRecord.UuidKey(deviceUuid) ?? "";
        string address = authority.ToLowerInvariant();
        lock (_gate)
        {
            Reload();
            _unsaved.RemoveAll(u => Replaces(u.Pin, fingerprint, uuid, address));
            _file.Certificates.RemoveAll(c => Replaces(c, fingerprint, uuid, address));
            var pin = new IppTrustedCertificate
            {
                Fingerprint = fingerprint,
                DeviceUuid = uuid,
                Addresses = [address],
                Name = name,
                Trusted = DateTimeOffset.Now,
            };
            _file.Certificates.Add(pin);
            if (!Save()) _unsaved.Add((pin, address));
        }
    }

    /// <summary>
    /// Re-reads the file (under <see cref="_gate"/>): another window of the app may have trusted
    /// or replaced a certificate meanwhile, and writing the copy loaded earlier would undo that.
    /// Certificates trusted here that could not be saved are applied to it again.
    /// </summary>
    private void Reload()
    {
        var file = StoreFiles.Load<IppTrustFile>(_path) ?? _file;
        foreach (var (pin, address) in _unsaved)
        {
            if (file.Certificates.Contains(pin)) continue;
            file.Certificates.RemoveAll(c => Replaces(c, pin.Fingerprint, pin.DeviceUuid, address));
            file.Certificates.Add(pin);
        }
        _file = file;
    }

    /// <summary>Writes the file (under <see cref="_gate"/>); false when it could not be written.</summary>
    private bool Save()
    {
        if (!StoreFiles.Write(_file, _path)) return false;
        _unsaved.Clear();
        return true;
    }

    /// <summary>Whether trusting <paramref name="fingerprint"/> for that printer replaces <paramref name="entry"/>.</summary>
    private static bool Replaces(IppTrustedCertificate entry, string fingerprint, string uuid, string address) =>
        entry.Fingerprint == fingerprint || SamePrinter(entry, uuid, address);

    /// <summary>Whether a certificate is trusted for this printer already (same UUID or address, see <see cref="Check"/>).</summary>
    public bool Knows(string? deviceUuid, string authority)
    {
        string uuid = IppTxtRecord.UuidKey(deviceUuid) ?? "";
        string address = authority.ToLowerInvariant();
        lock (_gate)
        {
            Reload();
            return _file.Certificates.Any(c => SamePrinter(c, uuid, address));
        }
    }

    /// <summary>The trusted certificates (copies).</summary>
    public IReadOnlyList<IppTrustedCertificate> Certificates
    {
        get
        {
            lock (_gate)
            {
                return [.. _file.Certificates.Select(c => new IppTrustedCertificate
                {
                    Fingerprint = c.Fingerprint,
                    DeviceUuid = c.DeviceUuid,
                    Addresses = [.. c.Addresses],
                    Name = c.Name,
                    Trusted = c.Trusted,
                })];
            }
        }
    }

    private static bool SamePrinter(IppTrustedCertificate entry, string uuid, string address) =>
        uuid.Length > 0 && entry.DeviceUuid.Length > 0
            ? entry.DeviceUuid == uuid
            : entry.Addresses.Contains(address);
}

/// <summary>A printer's certificate was refused: not trusted yet, changed, or unusable.</summary>
public sealed class IppCertificateException : Exception
{
    public IppTrustVerdict Verdict { get; }
    public string DeviceName { get; }
    /// <summary>The printer's UUID as known when connecting; null when unknown.</summary>
    public string? DeviceUuid { get; }
    /// <summary>"host:port" the certificate was presented at.</summary>
    public string Authority { get; }
    /// <summary>SPKI SHA-256 of the presented certificate, lowercase hex ("" when there was none).</summary>
    public string Fingerprint { get; }
    /// <summary>The previously trusted certificate, for <see cref="IppTrustVerdict.Changed"/>.</summary>
    public IppTrustedCertificate? Previous { get; }
    /// <summary>The certificate's subject, e.g. "CN=HPA1B2C3"; "" when there was none.</summary>
    public string Subject { get; }

    public IppCertificateException(IppTrustVerdict verdict, string deviceName, string? deviceUuid, string authority,
                                    string fingerprint, string subject, IppTrustedCertificate? previous = null)
        : base(MessageFor(verdict, deviceName))
    {
        Verdict = verdict;
        DeviceName = deviceName;
        DeviceUuid = deviceUuid;
        Authority = authority;
        Fingerprint = fingerprint;
        Subject = subject;
        Previous = previous;
    }

    /// <summary>The certificate can be trusted by the user (it exists and can be pinned).</summary>
    public bool CanTrust => (Verdict is IppTrustVerdict.Unknown or IppTrustVerdict.Changed) && Fingerprint.Length > 0;

    private static string MessageFor(IppTrustVerdict verdict, string name) => verdict switch
    {
        IppTrustVerdict.Changed =>
            $"The security certificate of {name} has changed since you trusted it, so Lazy Print did not connect. "
            + "A firmware update or a reset of the printer can change it, but so can another device pretending to be your printer.",
        IppTrustVerdict.Invalid =>
            $"{name} did not present a usable security certificate, so Lazy Print did not connect.",
        _ => $"{name} uses a security certificate that has not been trusted yet, so Lazy Print did not connect.",
    };
}

/// <summary>Fingerprints of printer certificates.</summary>
public static class IppCertificates
{
    /// <summary>SHA-256 of the certificate's SubjectPublicKeyInfo, lowercase hex (the key, not the whole certificate, is pinned).</summary>
    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexStringLower(SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo()));

    /// <summary>"AB:CD:…" for people to compare; groups of <paramref name="bytesPerLine"/> bytes per line when positive.</summary>
    public static string Format(string fingerprint, int bytesPerLine = 0)
    {
        var pairs = Enumerable.Range(0, fingerprint.Length / 2)
            .Select(i => fingerprint.Substring(i * 2, 2).ToUpperInvariant()).ToList();
        if (bytesPerLine <= 0) return string.Join(':', pairs);
        return string.Join('\n', pairs.Chunk(bytesPerLine).Select(line => string.Join(':', line)));
    }
}

/// <summary>
/// Checks the certificates one printer presents, against <see cref="IppTrustStore"/>. A
/// certificate Windows accepts (valid chain, matching name) is trusted as is; any other is
/// trusted only when pinned, or, for <paramref name="firstUse"/>, provisionally until
/// <see cref="RememberDevice"/>. A refusal is kept for <see cref="TakeRejection"/>, since
/// HttpClient reports it only as a failed connection. Safe to use from any thread.
/// </summary>
/// <param name="firstUse">
/// The fingerprint of a certificate the store does not know (<see cref="IppTrustVerdict.Unknown"/>)
/// that may be used to ask the printer who it is: it is accepted without being pinned, and
/// <see cref="RememberDevice"/> pins it once the printer's UUID shows it is not another key
/// for a printer trusted before (trust on first use).
/// </param>
public sealed class IppCertificateValidator(IppTrustStore store, string? deviceUuid, string deviceName,
                                             string? firstUse = null)
{
    /// <summary>A certificate accepted, where, and whether it was pinned or only accepted as <see cref="_firstUse"/>.</summary>
    private sealed record Accepted(string Fingerprint, string Authority, string Subject, bool Pinned);

    /// <summary>Set on a request whose TLS connection reached the certificate check.</summary>
    internal static readonly HttpRequestOptionsKey<bool> CertificateSeen = new("lp-certificate-seen");

    private readonly object _gate = new();
    private IppCertificateException? _rejection;
    /// <summary>The certificate accepted last.</summary>
    private Accepted? _accepted;
    private string? _firstUse = firstUse;

    public string DeviceName { get; } = deviceName;
    public string? DeviceUuid { get; } = deviceUuid;

    /// <summary>The TLS check for a request to <paramref name="requestUri"/>.</summary>
    public bool Validate(Uri? requestUri, X509Certificate2? certificate, SslPolicyErrors errors)
    {
        if (errors == SslPolicyErrors.None && certificate is not null) return true;
        string authority = requestUri is null ? "" : AuthorityOf(requestUri);
        if (certificate is null)
        {
            Interlocked.Exchange(ref _rejection, new IppCertificateException(
                IppTrustVerdict.Invalid, DeviceName, DeviceUuid, authority, "", ""));
            return false;
        }
        string fingerprint = IppCertificates.Fingerprint(certificate);
        var verdict = store.Check(fingerprint, DeviceUuid, authority, out var previous);
        lock (_gate)
        {
            if (verdict == IppTrustVerdict.Trusted
                || (verdict == IppTrustVerdict.Unknown && fingerprint == _firstUse))
            {
                _accepted = new Accepted(fingerprint, authority, certificate.Subject, verdict == IppTrustVerdict.Trusted);
                return true;
            }
        }
        Interlocked.Exchange(ref _rejection, new IppCertificateException(
            verdict, DeviceName, DeviceUuid, authority, fingerprint, certificate.Subject, previous));
        return false;
    }

    /// <summary>
    /// Checks the certificate the printer was reached through against the UUID it reported
    /// (its capabilities). A pinned certificate learns the UUID when it did not have it yet: a
    /// certificate trusted for an address added by hand then also identifies the printer when
    /// discovery finds it. A <c>firstUse</c> certificate is pinned now, with the UUID. Throws
    /// <see cref="IppCertificateException"/> (<see cref="IppTrustVerdict.Changed"/>, nothing
    /// pinned or learned) when another certificate is trusted for that printer.
    /// </summary>
    public void RememberDevice(string? deviceUuid)
    {
        Accepted? accepted;
        lock (_gate) accepted = _accepted;
        if (accepted is null || (accepted.Pinned && deviceUuid is null)) return;
        string? uuid = deviceUuid ?? DeviceUuid;
        var verdict = store.Check(accepted.Fingerprint, uuid, accepted.Authority, out var previous);
        if (verdict == IppTrustVerdict.Changed)
        {
            throw new IppCertificateException(IppTrustVerdict.Changed, DeviceName, uuid, accepted.Authority,
                                               accepted.Fingerprint, accepted.Subject, previous);
        }
        if (accepted.Pinned) return;
        if (verdict == IppTrustVerdict.Unknown) store.Trust(accepted.Fingerprint, uuid, accepted.Authority, DeviceName);
        lock (_gate)
        {
            _firstUse = null;
            _accepted = accepted with { Pinned = true };
        }
    }

    /// <summary>The last refusal, cleared by reading it; null when nothing was refused since.</summary>
    public IppCertificateException? TakeRejection() => Interlocked.Exchange(ref _rejection, null);

    /// <summary>The printer is trusted for this address or UUID already: it must not be reached without TLS.</summary>
    public bool Knows(string authority) => store.Knows(DeviceUuid, authority);

    /// <summary>A first-use certificate is waiting for <see cref="RememberDevice"/> to pin it.</summary>
    public bool HasPendingFirstUse
    {
        get
        {
            lock (_gate) return _firstUse is not null;
        }
    }

    /// <summary>A handler whose TLS connections are checked by this validator.</summary>
    public HttpMessageHandler CreateHandler() => new HttpClientHandler
    {
        UseProxy = false,
        ServerCertificateCustomValidationCallback = (request, certificate, _, errors) =>
        {
            request.Options.Set(CertificateSeen, true);
            return Validate(request.RequestUri, certificate, errors);
        },
    };

    /// <summary>"host:port" of a request, in the form <see cref="PrinterAddress.Authority"/> uses.</summary>
    internal static string AuthorityOf(Uri uri)
    {
        string host = uri.HostNameType == UriHostNameType.IPv6 ? "[" + uri.DnsSafeHost + "]" : uri.DnsSafeHost;
        return $"{host.ToLowerInvariant()}:{uri.Port.ToString(CultureInfo.InvariantCulture)}";
    }
}
