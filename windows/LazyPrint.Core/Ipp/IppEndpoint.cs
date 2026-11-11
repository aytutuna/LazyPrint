using System.Net;
using System.Net.Sockets;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppEndpoint.swift: the same rules and tests on both platforms.

/// <summary>
/// One DNS-SD service instance of a network printer, as the operating system reports it:
/// _ipp._tcp (<paramref name="Secure"/> false) or _ipps._tcp (true).
/// </summary>
/// <param name="Id">The system's id for the service instance.</param>
/// <param name="InstanceName">e.g. "HP Color LaserJet MFP M479fdw (A1B2C3)".</param>
/// <param name="HostName">e.g. "HPA1B2C3.local"; null when not reported.</param>
/// <param name="Addresses">
/// IP addresses as text, e.g. "192.168.1.20", "fe80::1%12" (the zone as an interface index or
/// name; an address whose zone names no interface here is skipped).
/// </param>
/// <param name="TextAttributes">TXT record entries ("key=value").</param>
public sealed record IppService(string Id, string InstanceName, bool Secure, string? HostName,
                                IReadOnlyList<string> Addresses, int Port, IReadOnlyList<string> TextAttributes);

/// <summary>
/// A discovered network printer: its _ipp and _ipps services merged, with the addresses to
/// connect through in the order to try them.
/// </summary>
public sealed class IppEndpoint
{
    /// <summary>"uuid:" + <see cref="IppTxtRecord.UuidKey"/>, or "name:" + the instance name (lowercase) without a UUID.</summary>
    public required string Key { get; init; }
    /// <summary>The model from the TXT record, else the service instance name.</summary>
    public required string Name { get; init; }
    /// <summary>The TXT record of the first service (the secure one when both are advertised).</summary>
    public required IppTxtRecord Txt { get; init; }
    /// <summary>
    /// Where to connect, best first: every ipps address before every ipp one (a read that
    /// answered on plain ipp does not change that), and within each, IPv4 addresses, then the host name, then IPv6 addresses.
    /// </summary>
    public required IReadOnlyList<PrinterAddress> Addresses { get; init; }
    /// <summary>The service instance names it was advertised under, e.g. "HP LaserJet Pro M404dn (A1B2C3)", without repeats.</summary>
    public IReadOnlyList<string> InstanceNames { get; init; } = [];

    /// <summary>The printer UUID from the TXT record, as advertised; null when there is none.</summary>
    public string? Uuid => Txt.Uuid;

    /// <summary>
    /// The endpoint with <paramref name="address"/> tried first; as it is when the address is not one of its own.
    /// A plain ipp address never goes ahead of an ipps one: the ipps address of the same host goes first
    /// instead, and the order stays when there is none.
    /// </summary>
    public IppEndpoint Preferring(PrinterAddress address)
    {
        if (!address.Secure && Addresses.Any(a => a.Secure))
        {
            address = Addresses.FirstOrDefault(a => a.Secure && a.Host == address.Host) ?? Addresses[0];
        }
        if (Addresses[0].Equals(address) || !Addresses.Contains(address)) return this;
        return new IppEndpoint
        {
            Key = Key,
            Name = Name,
            Txt = Txt,
            Addresses = [address, .. Addresses.Where(a => !a.Equals(address))],
            InstanceNames = InstanceNames,
        };
    }

    /// <summary>
    /// Groups services by printer (TXT UUID; services without one by instance name, which the
    /// _ipp and _ipps instances of one printer share) and orders each printer's addresses:
    /// ipps first (a failed TLS handshake falls back to the ipp ones), IPv4 before the
    /// .local host name (which needs another lookup), IPv6 last. IPv6 link-local addresses
    /// without a zone (%interface) cannot be connected to and are skipped. Printers keep the
    /// order their first service was listed in; printers left without an address are dropped.
    /// </summary>
    public static IReadOnlyList<IppEndpoint> Choose(IEnumerable<IppService> services)
    {
        var list = services.Where(s => s.Port is >= 1 and <= 65535).ToList();
        var parsed = list.Select(s => (Service: s, Txt: IppTxtRecord.Parse(s.TextAttributes))).ToList();
        var uuidByInstance = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (service, txt) in parsed)
        {
            if (IppTxtRecord.UuidKey(txt.Uuid) is { } uuid) uuidByInstance.TryAdd(service.InstanceName, uuid);
        }

        var groups = new List<(string Key, List<(IppService Service, IppTxtRecord Txt)> Members)>();
        foreach (var entry in parsed)
        {
            string key = IppTxtRecord.UuidKey(entry.Txt.Uuid) is { } uuid ? "uuid:" + uuid
                : uuidByInstance.TryGetValue(entry.Service.InstanceName, out var shared) ? "uuid:" + shared
                : "name:" + entry.Service.InstanceName.ToLowerInvariant();
            var group = groups.FirstOrDefault(g => g.Key == key);
            if (group.Members is null) groups.Add((key, [entry]));
            else group.Members.Add(entry);
        }

        var endpoints = new List<IppEndpoint>();
        foreach (var (key, members) in groups)
        {
            var ordered = members.OrderByDescending(m => m.Service.Secure).ToList(); // stable: secure first
            var addresses = new List<PrinterAddress>();
            foreach (var (service, txt) in ordered)
            {
                foreach (string host in Hosts(service))
                {
                    if (PrinterAddress.Create(service.Secure, host, service.Port, txt.ResourcePath) is { } address
                        && !addresses.Contains(address))
                    {
                        addresses.Add(address);
                    }
                }
            }
            if (addresses.Count == 0) continue;
            var first = ordered[0];
            endpoints.Add(new IppEndpoint
            {
                Key = key,
                Name = ordered.Select(m => m.Txt.Model).FirstOrDefault(m => m is not null) ?? first.Service.InstanceName,
                Txt = first.Txt,
                Addresses = addresses,
                InstanceNames = [.. ordered.Select(m => m.Service.InstanceName).Distinct(StringComparer.OrdinalIgnoreCase)],
            });
        }
        return endpoints;
    }

    /// <summary>One service's hosts to try: IPv4 addresses, the host name, then usable IPv6 addresses.</summary>
    private static IEnumerable<string> Hosts(IppService service)
    {
        var v4 = new List<string>();
        var v6 = new List<string>();
        foreach (string text in service.Addresses)
        {
            string trimmed = text?.Trim() ?? "";
            if (!IPAddress.TryParse(trimmed, out var ip)) continue;
            if (ip.AddressFamily == AddressFamily.InterNetwork) v4.Add(ip.ToString());
            else if (PrinterAddress.ParseIPv6(trimmed) is { } zoned && (!zoned.IsIPv6LinkLocal || zoned.ScopeId != 0))
            {
                v6.Add(zoned.ToString());
            }
        }
        foreach (string ip in v4) yield return ip;
        if (!string.IsNullOrWhiteSpace(service.HostName)) yield return service.HostName.Trim();
        foreach (string ip in v6) yield return ip;
    }
}
