using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppHostListTests.swift: the same cases. The printers added by
// address (ipp-hosts.json).

public sealed class IppHostListTests : IDisposable
{
    private readonly string _directory;

    public IppHostListTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void AddsCanonicalAddressesOnce()
    {
        var hosts = new IppHostList(_directory);
        Assert.Empty(hosts.Load());
        Assert.True(hosts.Add(PrinterAddress.Parse("ipp://192.168.1.50:631/ipp/print")));
        Assert.False(hosts.Add(PrinterAddress.Parse("192.168.1.50")));
        Assert.True(hosts.Add(PrinterAddress.Parse("ipps://10.0.0.7")));
        Assert.Equal(["192.168.1.50", "ipps://10.0.0.7"], hosts.LoadEntries());
        Assert.True(hosts.Remove(PrinterAddress.Parse("192.168.1.50")));
        Assert.False(hosts.Remove(PrinterAddress.Parse("192.168.1.50")));
        Assert.Equal(["ipps://10.0.0.7"], hosts.LoadEntries());
    }

    [Fact]
    public void HandWrittenEntriesKeepWorking()
    {
        var hosts = new IppHostList(_directory);
        File.WriteAllText(hosts.FilePath, """["192.168.1.50", "epson.local:8631", "not an address", "192.168.1.50"]""");
        Assert.Equal(["192.168.1.50", "epson.local:8631"], hosts.Load().Select(a => a.ToString()));
        // Adding keeps the other entries, including the one that is not an address.
        Assert.True(hosts.Add(PrinterAddress.Parse("10.0.0.9")));
        Assert.Equal(["192.168.1.50", "epson.local:8631", "not an address", "192.168.1.50", "10.0.0.9"], hosts.LoadEntries());
    }

    [Fact]
    public void AnUndecodableListIsKeptAside()
    {
        var hosts = new IppHostList(_directory);
        File.WriteAllText(hosts.FilePath, """{"hosts": ["192.168.1.50"]}""");
        Assert.Empty(hosts.Load());
        Assert.Single(Directory.GetFiles(_directory, "ipp-hosts.unreadable-*.json"));
        Assert.True(hosts.Add(PrinterAddress.Parse("10.0.0.9")));
        Assert.Equal(["10.0.0.9"], hosts.LoadEntries());
    }

    [Fact]
    public void TheFileIsIppHostsJsonInTheDirectory()
    {
        Assert.Equal(Path.Combine(_directory, "ipp-hosts.json"), new IppHostList(_directory).FilePath);
    }
}
