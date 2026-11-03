namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppHostList.swift: the same rules and tests on both platforms.

/// <summary>
/// The network printers added by address: %APPDATA%\Lazy Print\ipp-hosts.json, a JSON list of
/// address strings (["192.168.1.50", "printer.local:8631", "ipps://10.0.0.7"]). The "Add printer
/// by address" dialog writes it, and entries written by hand keep working. Entries that do not
/// parse as an address are kept but not used. The file follows the settings-file rules
/// (CONTRACTS.md, Global rule 5): a file that does not decode is kept aside as
/// ipp-hosts.unreadable-&lt;timestamp&gt;.json, one that cannot be read is never overwritten.
/// </summary>
public sealed class IppHostList
{
    public IppHostList() : this(StoreFiles.DefaultDirectory) { }

    /// <summary>Keeps ipp-hosts.json in <paramref name="directory"/> instead of %APPDATA% (tests, harnesses).</summary>
    public IppHostList(string directory)
    {
        FilePath = Path.Combine(directory, "ipp-hosts.json");
    }

    public string FilePath { get; }

    /// <summary>The entries as written, in order; empty when there is no file or it could not be loaded.</summary>
    public List<string> LoadEntries() => StoreFiles.Load<List<string>>(FilePath) ?? [];

    /// <summary>The usable addresses, in order, without duplicates.</summary>
    public List<PrinterAddress> Load()
    {
        var addresses = new List<PrinterAddress>();
        foreach (string entry in LoadEntries())
        {
            if (PrinterAddress.TryParse(entry, out var address, out _) && !addresses.Contains(address!))
            {
                addresses.Add(address!);
            }
        }
        return addresses;
    }

    /// <summary>Adds <paramref name="address"/> in its canonical form; false when it is already listed.</summary>
    public bool Add(PrinterAddress address)
    {
        var entries = LoadEntries();
        if (entries.Any(e => Matches(e, address))) return false;
        entries.Add(address.ToString());
        StoreFiles.Write(entries, FilePath);
        return true;
    }

    /// <summary>Removes every entry meaning <paramref name="address"/>; false when none did.</summary>
    public bool Remove(PrinterAddress address)
    {
        var entries = LoadEntries();
        if (entries.RemoveAll(e => Matches(e, address)) == 0) return false;
        StoreFiles.Write(entries, FilePath);
        return true;
    }

    private static bool Matches(string entry, PrinterAddress address) =>
        PrinterAddress.TryParse(entry, out var parsed, out _) && parsed!.Equals(address);
}
