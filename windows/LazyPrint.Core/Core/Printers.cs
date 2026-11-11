using System.Text;
using System.Text.RegularExpressions;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/Printers.swift (Lazy Scan's DeviceMerge, for printers): the printer list.

/// <summary>How a job goes to a printer: the system's queue, straight to IPP, or to the demo printer.</summary>
public enum PrinterRoute
{
    System,
    Ipp,
    Demo,
}

public enum PrinterState
{
    Unknown,
    Idle,
    Printing,
    Stopped,
    Offline,
}

/// <summary>One ink or toner supply; <paramref name="Level"/> is a percent, null when the printer does not say.</summary>
public sealed record Supply(string Name, string? Color, int? Level, bool IsLow);

/// <summary>What the system says about a queue, kept apart from what IPP says so a refresh can tell them apart.</summary>
public sealed record QueueStatus(PrinterState State, IReadOnlyList<PrinterProblem> Problems)
{
    public bool Equals(QueueStatus? other) => other is not null && State == other.State && Problems.SequenceEqual(other.Problems);

    public override int GetHashCode() => HashCode.Combine(State, Problems.Count);
}

/// <summary>One physical printer as the app lists it.</summary>
/// <param name="Id">Stable across runs: "system:" and the queue's name, "ipp:" and the printer's UUID for a network printer without a queue, "demo" for the demo printer.</param>
/// <param name="Address">What the troubleshooter and the test page show.</param>
/// <param name="Route">The system's queue when it has one, else IPP.</param>
/// <param name="IppEndpoint">Also set for a system printer matched to its IPP twin, for status and supplies.</param>
/// <param name="Queue">The state and problems of a system printer's queue; a refresh keeps them beside what IPP says.</param>
public sealed record PrinterInfo(
    string Id,
    string Name,
    string? Model,
    string? Address,
    PrinterRoute Route,
    IppEndpoint? IppEndpoint,
    bool IsDefault,
    PrinterState State,
    IReadOnlyList<PrinterProblem> Problems,
    IReadOnlyList<Supply> Supplies,
    QueueStatus? Queue = null)
{
    public bool Equals(PrinterInfo? other) =>
        other is not null && Id == other.Id && Name == other.Name && Model == other.Model && Address == other.Address
        && Route == other.Route && IppEndpoint?.Key == other.IppEndpoint?.Key
        && Equals(IppEndpoint?.Addresses[0], other.IppEndpoint?.Addresses[0]) && IsDefault == other.IsDefault
        && State == other.State && Problems.SequenceEqual(other.Problems) && Supplies.SequenceEqual(other.Supplies)
        && Queue == other.Queue;

    public override int GetHashCode() => HashCode.Combine(Id, Name, Route, State);
}

public static partial class PrinterMerge
{
    public const string DemoId = "demo";
    public const string DemoName = "Demo Printer";

    /// <summary>
    /// One row per physical printer, whichever ways it is listed. A system queue and the IPP printer it points at are one
    /// row, found by UUID, else by a host or address in the queue's port or device URI (IP_ and WSD port names, ipp://,
    /// http:// and dnssd:// URIs), else by the service's instance name, else by name; it is routed through the queue and
    /// keeps the IPP endpoint for status. Each way is tried for all queues before the next, so a weak match never takes
    /// a printer from a queue that points at it. A name that fits more than one printer matches none, and a queue whose
    /// port names a host is not matched by name. The first queue that matches an endpoint keeps it; another queue for the
    /// same printer is a row of its own. Virtual queues (PDF, XPS, OneNote, fax) are left out. System queues come first,
    /// then the network printers no queue matched, then the demo printer.
    /// </summary>
    public static IReadOnlyList<PrinterInfo> Merge(IReadOnlyList<SystemPrinter> system, IReadOnlyList<IppService> network, bool demo)
    {
        var left = IppEndpoint.Choose(network).ToList();
        var queues = system.Where(q => !IsVirtual(q)).Select(q => (Queue: q, Hints: Hints(q))).ToList();
        var twins = new IppEndpoint?[queues.Count];
        Func<SystemPrinter, PortHints, List<IppEndpoint>, IppEndpoint?>[] ways = [ByUuid, ByHost, ByInstance, ByName];
        foreach (var way in ways)
        {
            for (int i = 0; i < queues.Count; i++)
            {
                if (twins[i] is null && way(queues[i].Queue, queues[i].Hints, left) is { } found)
                {
                    twins[i] = found;
                    left.Remove(found);
                }
            }
        }

        var rows = queues.Select((q, i) => FromQueue(q.Queue, q.Hints, twins[i])).ToList();
        rows.AddRange(left.Select(FromEndpoint));
        if (demo)
        {
            rows.Add(new PrinterInfo(DemoId, DemoName, null, null, PrinterRoute.Demo, null, false, PrinterState.Idle, [], []));
        }
        return rows;
    }

    /// <summary>
    /// The printer's state, problems and supplies from what it just said; <c>null</c> is a printer that did not answer.
    /// Supplies that hold waste (waste ink, waste toner) are left out: their level is how full they are. A printer with a
    /// queue keeps the queue's problems beside IPP's, and its offline or stopped state wins; one that does not answer IPP
    /// is as the queue says, since it may print through its port all the same.
    /// </summary>
    public static PrinterInfo Refresh(PrinterInfo printer, PrinterCapabilities? capabilities)
    {
        var queue = printer.Route == PrinterRoute.System ? printer.Queue : null;
        if (capabilities is null)
        {
            return queue is not null
                ? printer with { State = queue.State, Problems = queue.Problems, Supplies = [] }
                : printer with { State = PrinterState.Offline, Problems = IppProblems.Describe([], null, false), Supplies = [] };
        }

        var state = capabilities.State switch
        {
            IppPrinterState.Processing => PrinterState.Printing,
            IppPrinterState.Stopped => PrinterState.Stopped,
            _ => PrinterState.Idle,
        };
        var problems = IppProblems.Describe(capabilities.StateReasons, capabilities.StateMessage, true);
        if (queue is not null)
        {
            if (queue.State is PrinterState.Offline or PrinterState.Stopped) state = queue.State;
            problems = [.. queue.Problems, .. problems.Where(p => queue.Problems.All(q => q.Title != p.Title))];
        }
        return printer with
        {
            State = state,
            Problems = problems,
            Supplies = SuppliesOf(capabilities),
        };
    }

    /// <summary>The marker levels a printer reported, without the supplies that hold waste.</summary>
    public static IReadOnlyList<Supply> SuppliesOf(PrinterCapabilities capabilities) =>
        [.. capabilities.Supplies
            .Where(s => !s.Type.StartsWith("waste", StringComparison.OrdinalIgnoreCase))
            .Select(s => new Supply(
                s.Name,
                string.IsNullOrEmpty(s.Color) ? null : s.Color,
                s.Level is >= 0 and <= 100 ? s.Level : null,
                s.Level >= 0 && s.LowLevel is { } low && s.Level <= low))];

    private static PrinterInfo FromQueue(SystemPrinter queue, PortHints hints, IppEndpoint? endpoint)
    {
        var problems = SystemQueueProblems.Describe(queue.States);
        var state = queue.States.Contains(SystemQueueState.Offline) ? PrinterState.Offline
            : problems.Any(p => p.IsError) ? PrinterState.Stopped
            : queue.States.Contains(SystemQueueState.Busy) ? PrinterState.Printing
            : PrinterState.Idle;
        return new PrinterInfo(
            "system:" + queue.Name,
            queue.Name,
            endpoint?.Txt.Model ?? Blank(queue.Model),
            endpoint?.Addresses[0].Host ?? hints.Hosts.FirstOrDefault(),
            PrinterRoute.System,
            endpoint,
            queue.IsDefault,
            state,
            problems,
            [],
            new QueueStatus(state, problems));
    }

    private static PrinterInfo FromEndpoint(IppEndpoint endpoint) =>
        new("ipp:" + (UuidOf(endpoint) ?? endpoint.Key), endpoint.Name, endpoint.Txt.Model, endpoint.Addresses[0].Host,
            PrinterRoute.Ipp, endpoint, false, PrinterState.Unknown, [], []);

    private static string? Blank(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    private static string? UuidOf(IppEndpoint endpoint) => UuidText(endpoint.Uuid);

    /// <summary>A UUID in lower case without "urn:uuid:"; null when there is none.</summary>
    private static string? UuidText(string? uuid)
    {
        if (string.IsNullOrWhiteSpace(uuid)) return null;
        string text = uuid.Trim().ToLowerInvariant();
        return text.StartsWith("urn:uuid:", StringComparison.Ordinal) ? text["urn:uuid:".Length..] : text;
    }

    private static IppEndpoint? ByUuid(SystemPrinter queue, PortHints hints, List<IppEndpoint> endpoints)
    {
        foreach (string? uuid in new[] { hints.Uuid, hints.PortUuid }.Select(IppTxtRecord.UuidKey))
        {
            if (uuid is not null && endpoints.FirstOrDefault(e => IppTxtRecord.UuidKey(e.Uuid) == uuid) is { } found) return found;
        }
        return null;
    }

    private static IppEndpoint? ByHost(SystemPrinter queue, PortHints hints, List<IppEndpoint> endpoints) =>
        Candidates(hints, endpoints).FirstOrDefault(e => e.Addresses.Any(a => hints.Hosts.Contains(HostKey(a.Host))));

    // The name of a queue or the service of a dnssd URI, exactly as the printer advertises it ("... (A1B2C3)" tells two
    // printers of one model apart).
    private static IppEndpoint? ByInstance(SystemPrinter queue, PortHints hints, List<IppEndpoint> endpoints)
    {
        if (hints.Hosts.Count > 0) return null;
        string?[] names = [queue.Name.Trim().ToLowerInvariant(), hints.Instance?.Trim().ToLowerInvariant()];
        return Only(Candidates(hints, endpoints).Where(e => e.InstanceNames.Any(n => names.Contains(n.Trim().ToLowerInvariant()))));
    }

    private static IppEndpoint? ByName(SystemPrinter queue, PortHints hints, List<IppEndpoint> endpoints)
    {
        if (hints.Hosts.Count > 0) return null;
        var names = new[] { NameKey(queue.Name), NameKey(queue.Model), NameKey(hints.Instance) }.OfType<string>().ToList();
        return Only(Candidates(hints, endpoints).Where(e =>
            (NameKey(e.Name) is { } key && names.Contains(key)) || e.InstanceNames.Any(n => NameKey(n) is { } k && names.Contains(k))));
    }

    /// <summary>The endpoint when it is the only one; two that fit are not told apart.</summary>
    private static IppEndpoint? Only(IEnumerable<IppEndpoint> found)
    {
        var list = found.Take(2).ToList();
        return list.Count == 1 ? list[0] : null;
    }

    // Two printers of one model have different UUIDs: a queue that names its printer's UUID is not another one's.
    private static IEnumerable<IppEndpoint> Candidates(PortHints hints, List<IppEndpoint> endpoints)
    {
        string? own = IppTxtRecord.UuidKey(hints.Uuid);
        return endpoints.Where(e => own is null || IppTxtRecord.UuidKey(e.Uuid) is not { } other || other == own);
    }

    private static bool IsVirtual(SystemPrinter queue) =>
        queue.IsVirtual
        || VirtualName().IsMatch(queue.Name)
        || (queue.Port?.StartsWith("PORTPROMPT:", StringComparison.OrdinalIgnoreCase) ?? false)
        || (queue.Port?.StartsWith("SHRFAX:", StringComparison.OrdinalIgnoreCase) ?? false);

    [GeneratedRegex(@"print to pdf|send to|\b(xps|onenote)\b|^\s*fax\s*$|\(fax\)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex VirtualName();

    [GeneratedRegex(@"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9.])", RegexOptions.CultureInvariant)]
    private static partial Regex Ipv4();

    [GeneratedRegex(@"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Guid();

    [GeneratedRegex(@"[?&]uuid=([^&#]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex UuidParameter();

    [GeneratedRegex(@"\(\s*(?:copy|redirected)\s*\d*\s*\)", RegexOptions.CultureInvariant)]
    private static partial Regex CopySuffix();

    /// <summary>What a queue's port or URI says about the printer behind it.</summary>
    /// <param name="Hosts">Host names and addresses, lower case.</param>
    /// <param name="Instance">The DNS-SD service name of a dnssd:// URI.</param>
    /// <param name="Uuid">The printer's UUID, from the system or a "uuid=" in the device URI.</param>
    /// <param name="PortUuid">Any UUID found in the port name (a WSD port's, which may be the printer's).</param>
    private sealed record PortHints(IReadOnlyList<string> Hosts, string? Instance, string? Uuid, string? PortUuid);

    private static PortHints Hints(SystemPrinter queue)
    {
        string port = queue.Port?.Trim() ?? "";
        var hosts = new List<string>();
        string? instance = null;
        int scheme = port.IndexOf("://", StringComparison.Ordinal);
        if (scheme > 0)
        {
            string authority = port[(scheme + 3)..];
            int end = authority.IndexOfAny(['/', '?', '#']);
            if (end >= 0) authority = authority[..end];
            authority = authority[(authority.LastIndexOf('@') + 1)..];
            string host = authority.StartsWith('[') && authority.IndexOf(']') is > 0 and var close
                ? authority[1..close]
                : authority.Split(':')[0];
            host = Uri.UnescapeDataString(host);
            // A DNS-SD URI names the service, "Name._ipp._tcp.local", not a host.
            if (host.Contains("._tcp", StringComparison.OrdinalIgnoreCase)) instance = host[..host.IndexOf("._", StringComparison.Ordinal)];
            else if (host.Length > 0) hosts.Add(HostKey(host));
        }
        else
        {
            string text = port.StartsWith("IP_", StringComparison.OrdinalIgnoreCase) ? port[3..] : port;
            hosts.AddRange(Ipv4().Matches(text).Select(m => m.Value));
            string name = text.Split(':')[0];
            if (hosts.Count == 0 && name.Contains('.') && Uri.CheckHostName(name) == UriHostNameType.Dns) hosts.Add(HostKey(name));
        }

        string? uuid = queue.Uuid ?? (UuidParameter().Match(port) is { Success: true } q ? q.Groups[1].Value : null);
        return new PortHints(hosts, instance, uuid, Guid().Match(port) is { Success: true } m ? m.Value : null);
    }

    /// <summary>A host in lower case without a trailing dot or an IPv6 zone, so the ways it is written compare equal.</summary>
    private static string HostKey(string host)
    {
        string text = host.Trim().Trim('[', ']').TrimEnd('.').ToLowerInvariant();
        int zone = text.IndexOf('%');
        return zone >= 0 ? text[..zone] : text;
    }

    /// <summary>A name's letters and digits as lower-case words, a "(Copy 1)" or "(Redirected 1)" left out; null when none are left.</summary>
    private static string? NameKey(string? name)
    {
        if (name is null) return null;
        string text = CopySuffix().Replace(name.ToLowerInvariant(), " ");
        var words = new List<string>();
        var word = new StringBuilder();
        foreach (char c in text)
        {
            if (c is >= 'a' and <= 'z' or >= '0' and <= '9') word.Append(c);
            else if (word.Length > 0)
            {
                words.Add(word.ToString());
                word.Clear();
            }
        }
        if (word.Length > 0) words.Add(word.ToString());
        return words.Count > 0 ? string.Join(' ', words) : null;
    }
}
