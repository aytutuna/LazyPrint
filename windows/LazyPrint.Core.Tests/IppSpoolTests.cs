using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppSpoolTests.swift: the same cases.

public sealed class IppSpoolTests : IDisposable
{
    private readonly string _directory;

    public IppSpoolTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void SheetsAreAppendedInOrderAndTheFileGoesWithTheSpool()
    {
        string path;
        using (var spool = new IppSpool(_directory))
        {
            path = spool.Path;
            Assert.Equal(_directory, Path.GetDirectoryName(path));
            spool.Write(s => s.Write("RaS2"u8));
            spool.Write(s => s.Write([1, 2, 3]));
            spool.Write(s => s.Write([4]));
            Assert.Equal(path, spool.Complete());
            Assert.Equal([.. "RaS2"u8, 1, 2, 3, 4], File.ReadAllBytes(path));
        }
        Assert.False(File.Exists(path));
    }

    [Fact]
    public void AnAbandonedSpoolIsDeletedAndWritingAfterCompleteIsAMistake()
    {
        var spool = new IppSpool(_directory);
        spool.Write(s => s.Write([1]));
        spool.Dispose();
        Assert.Empty(Directory.GetFiles(_directory));
        spool.Dispose(); // twice is fine

        using var done = new IppSpool(_directory);
        done.Complete();
        Assert.Throws<InvalidOperationException>(() => done.Write(s => s.Write([1])));
    }

    [Fact]
    public void ASpoolLeftByAKilledRunIsSweptWhenANewOneStarts()
    {
        string old = Path.Combine(_directory, "lp-old.spool");
        string recent = Path.Combine(_directory, "lp-recent.spool");
        string other = Path.Combine(_directory, "notes.spool");
        foreach (string file in new[] { old, recent, other }) File.WriteAllBytes(file, [1]);
        File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-2));
        File.SetLastWriteTimeUtc(other, DateTime.UtcNow.AddDays(-2));

        using var spool = new IppSpool(_directory);
        Assert.False(File.Exists(old));
        Assert.True(File.Exists(recent));
        Assert.True(File.Exists(other));
    }

    [Fact]
    public void TwoSpoolsNeverShareAFile()
    {
        using var a = new IppSpool(_directory);
        using var b = new IppSpool(_directory);
        Assert.NotEqual(a.Path, b.Path);
    }
}
