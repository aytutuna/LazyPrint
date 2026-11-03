using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/PrinterAddress.swift: the same rules and tests on both platforms.

/// <summary>
/// Where an IPP printer answers: scheme, host, port and resource path. Parsed from what a
/// user types ("192.168.1.50", "printer.local:8631", "ipps://10.0.0.7", "[fe80::1%12]:631",
/// "http://host:8080/ipp/print") and written back in one canonical form, the text kept in
/// ipp-hosts.json. Secure means ipps (and https); http and https are read as ipp and ipps on
/// the port they name, so a printer-uri is always ipp or ipps.
/// </summary>
public sealed class PrinterAddress : IEquatable<PrinterAddress>
{
    /// <summary>The port IPP uses, for ipp and ipps alike.</summary>
    public const int DefaultPort = 631;
    /// <summary>The resource path IPP Everywhere printers answer at.</summary>
    public const string DefaultPath = "ipp/print";

    /// <summary>ipps (IPP over TLS) instead of plain ipp.</summary>
    public bool Secure { get; }
    /// <summary>Host name (lowercase) or IP address; IPv6 without brackets, with its zone (%12) when it has one.</summary>
    public string Host { get; }
    public int Port { get; }
    /// <summary>The IPP resource path below the host, without slashes ("ipp/print" unless given).</summary>
    public string ResourcePath { get; }

    private PrinterAddress(bool secure, string host, int port, string resourcePath)
    {
        Secure = secure;
        Host = host;
        Port = port;
        ResourcePath = resourcePath;
    }

    private bool IsIPv6 => Host.Contains(':');

    /// <summary>"host:port" (IPv6 in brackets), lowercase: identifies the endpoint, e.g. for certificate trust.</summary>
    public string Authority => $"{(IsIPv6 ? "[" + Host + "]" : Host)}:{Port.ToString(CultureInfo.InvariantCulture)}";

    /// <summary>
    /// The printer-uri an IPP request carries: ipp or ipps, always with the port. An IPv6 zone is
    /// left out, since only this machine knows what it means.
    /// </summary>
    public string PrinterUri => (Secure ? "ipps://" : "ipp://") + UriAuthority(zone: false) + PathText;

    /// <summary>
    /// Where requests are posted: the printer-uri over http or https. An IPv6 zone stays "%12"
    /// rather than RFC 6874's "%2512": System.Uri reads the zone unescaped (and leaves it out of AbsoluteUri).
    /// </summary>
    public Uri RequestUri => new((Secure ? "https://" : "http://") + UriAuthority(zone: true) + PathText);

    private string UriAuthority(bool zone)
    {
        string host = zone ? Host : Host.Split('%')[0];
        return $"{(IsIPv6 ? "[" + host + "]" : host)}:{Port.ToString(CultureInfo.InvariantCulture)}";
    }

    private string EscapedPath => Uri.EscapeDataString(ResourcePath).Replace("%2F", "/");

    private string PathText => "/" + EscapedPath;

    /// <summary>
    /// The canonical text: the bare host for the plain default ("192.168.1.50"), "host:port"
    /// for plain ipp on another port, otherwise a URL ("ipps://10.0.0.7",
    /// "ipp://host:8080/printers/office"). Parsing it gives an equal address, except for a resource
    /// at the root of the host, which only a discovered service can name (it reads back as /ipp/print).
    /// </summary>
    public override string ToString()
    {
        string bracketed = IsIPv6 ? "[" + Host + "]" : Host;
        if (!Secure && ResourcePath == DefaultPath)
        {
            return Port == DefaultPort ? bracketed : $"{bracketed}:{Port.ToString(CultureInfo.InvariantCulture)}";
        }
        string text = (Secure ? "ipps://" : "ipp://") + bracketed;
        if (Port != DefaultPort) text += ":" + Port.ToString(CultureInfo.InvariantCulture);
        if (ResourcePath != DefaultPath) text += "/" + EscapedPath;
        return text;
    }

    public bool Equals(PrinterAddress? other) =>
        other is not null && string.Equals(ToString(), other.ToString(), StringComparison.OrdinalIgnoreCase);

    public override bool Equals(object? obj) => Equals(obj as PrinterAddress);

    public override int GetHashCode() => StringComparer.OrdinalIgnoreCase.GetHashCode(ToString());

    /// <summary>
    /// The ipps address to try when a host typed bare (no scheme, no path) got no answer over
    /// plain ipp on port 631; null for any other address.
    /// </summary>
    public PrinterAddress? HttpsFallback(string typed) =>
        !Secure && Port == DefaultPort && ResourcePath == DefaultPath && !typed.Contains('/')
            ? new PrinterAddress(secure: true, Host, Port, ResourcePath)
            : null;

    /// <summary>The same host, port and path over TLS or not: where the client goes on HTTP 426 or a failed handshake.</summary>
    internal PrinterAddress WithSecure(bool secure) => new(secure, Host, Port, ResourcePath);

    /// <summary>An address from its parts (a discovered service); null when the host is not usable.</summary>
    public static PrinterAddress? Create(bool secure, string host, int port, string resourcePath)
    {
        if (port is < 1 or > 65535) return null;
        string? normalized = NormalizeHost(host.Trim().TrimStart('[').TrimEnd(']'));
        return normalized is null ? null : new PrinterAddress(secure, normalized, port, resourcePath.Trim('/'));
    }

    /// <summary>Parses an address; throws <see cref="FormatException"/> with a user-facing message.</summary>
    public static PrinterAddress Parse(string text) =>
        TryParse(text, out var address, out string error) ? address! : throw new FormatException(error);

    /// <summary>
    /// Parses what a user typed. Accepted: an IPv4 or IPv6 address or host name, optionally
    /// with a port ("host:8631", "[2001:db8::1]:8631"), or an ipp, ipps, http or https URL with an
    /// optional port and resource path. Plain addresses mean ipp on port 631 at /ipp/print; an
    /// ipp or ipps URL without a port means 631, an http or https one the web's 80 or 443.
    /// <paramref name="error"/> says what is wrong, for the user.
    /// </summary>
    public static bool TryParse(string? text, out PrinterAddress? address, out string error)
    {
        address = null;
        error = "";
        string value = text?.Trim() ?? "";
        if (value.Length == 0)
        {
            error = "Enter the printer's IP address or host name.";
            return false;
        }
        if (value.Any(char.IsWhiteSpace))
        {
            error = "An address cannot contain spaces.";
            return false;
        }

        bool hasScheme = value.Contains("://", StringComparison.Ordinal);
        // "192.168.1.5/ipp/print": a path without a scheme means plain ipp.
        if (!hasScheme && value.Contains('/')) return TryParse("ipp://" + value, out address, out error);
        if (hasScheme) return TryParseUrl(value, out address, out error);

        string host;
        string? port = null;
        if (value.StartsWith('['))
        {
            int close = value.IndexOf(']');
            if (close < 0)
            {
                error = "An IPv6 address in brackets needs its closing \"]\".";
                return false;
            }
            host = value[1..close];
            string rest = value[(close + 1)..];
            if (rest.Length > 0)
            {
                if (!rest.StartsWith(':'))
                {
                    error = "That is not a valid address.";
                    return false;
                }
                port = rest[1..];
            }
        }
        else if (value.Count(c => c == ':') >= 2)
        {
            host = value; // a bare IPv6 address: no port
        }
        else
        {
            int colon = value.IndexOf(':');
            host = colon < 0 ? value : value[..colon];
            if (colon >= 0) port = value[(colon + 1)..];
        }

        int portNumber = DefaultPort;
        if (port is not null && !TryPort(port, out portNumber))
        {
            error = "The port must be a number from 1 to 65535.";
            return false;
        }
        if (NormalizeHost(host) is not { } normalized)
        {
            error = $"\"{host}\" is not a valid IP address or host name.";
            return false;
        }
        if (LacksZone(normalized))
        {
            error = "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12.";
            return false;
        }
        address = new PrinterAddress(secure: false, normalized, portNumber, DefaultPath);
        return true;
    }

    private static bool TryParseUrl(string value, out PrinterAddress? address, out string error)
    {
        address = null;
        error = "";
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Host.Length == 0)
        {
            error = "That is not a valid address.";
            return false;
        }
        bool secure;
        if (uri.Scheme is "ipp" or "http") secure = false;
        else if (uri.Scheme is "ipps" or "https") secure = true;
        else
        {
            error = "Use an address that starts with ipp://, ipps://, http:// or https://, or just the IP address or host name.";
            return false;
        }
        if (uri.UserInfo.Length > 0)
        {
            error = "Leave out the user name and password; printers do not need them.";
            return false;
        }
        if (NormalizeHost(uri.DnsSafeHost) is not { } host)
        {
            error = uri.HostNameType == UriHostNameType.IPv6
                ? "That is not a valid address."
                : $"\"{uri.Host}\" is not a valid IP address or host name.";
            return false;
        }
        if (LacksZone(host))
        {
            error = "Use the printer's IPv4 address; a link-local IPv6 address needs its interface, like fe80::1%12.";
            return false;
        }
        string path = Uri.UnescapeDataString(uri.AbsolutePath).Trim('/');
        // System.Uri has no default port for ipp and ipps (-1).
        int port = uri.Port < 0 ? DefaultPort : uri.Port;
        address = new PrinterAddress(secure, host, port, path.Length == 0 ? DefaultPath : path);
        return true;
    }

    /// <summary>A link-local IPv6 address with no zone: it cannot be reached, as discovery also finds.</summary>
    private static bool LacksZone(string host) =>
        host.Contains(':') && ParseIPv6(host) is { IsIPv6LinkLocal: true, ScopeId: 0 };

    private static bool TryPort(string text, out int port) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out port) && port is >= 1 and <= 65535;

    /// <summary>
    /// A host name in lowercase or an IP address in its standard form (IPv6 keeps its zone);
    /// null when it is neither.
    /// </summary>
    private static string? NormalizeHost(string host)
    {
        if (host.Length == 0) return null;
        if (host.Contains(':')) return ParseIPv6(host)?.ToString().ToLowerInvariant();
        if (host.All(c => char.IsAsciiDigit(c) || c == '.'))
        {
            // Digits and dots only: it has to be a complete dotted IPv4 address ("192.168.1"
            // would otherwise pass as a host name, and IPAddress would read it as 192.168.0.1).
            string[] parts = host.Split('.');
            return parts.Length == 4 && parts.All(p => p.Length is > 0 and <= 3 && int.Parse(p, CultureInfo.InvariantCulture) <= 255)
                ? string.Join('.', parts.Select(p => int.Parse(p, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)))
                : null;
        }
        return Uri.CheckHostName(host) == UriHostNameType.Dns ? host.TrimEnd('.').ToLowerInvariant() : null;
    }

    /// <summary>
    /// An IPv6 address with an optional zone, an interface number ("fe80::1%12") or the name of an
    /// interface on this device, read as its number; null when it is not one, or when its zone is
    /// neither (IPAddress reads such a zone as none, and a link-local address without its interface
    /// cannot be reached).
    /// </summary>
    internal static IPAddress? ParseIPv6(string text)
    {
        if (!IPAddress.TryParse(text, out var ip) || ip.AddressFamily != AddressFamily.InterNetworkV6) return null;
        int percent = text.IndexOf('%');
        if (percent >= 0 && ip.ScopeId == 0)
        {
            string zone = text[(percent + 1)..];
            bool isZero = uint.TryParse(zone, NumberStyles.None, CultureInfo.InvariantCulture, out uint number) && number == 0;
            if (zone.Length > 0 && !isZero) return null;
        }
        return ip;
    }
}
