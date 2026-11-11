using LazyPrint.App.Services;
using Microsoft.Win32;
using Xunit;

namespace LazyPrint.App.Tests;

// The lazyprint: scheme is written under a key of the tests' own in HKCU\Software, removed again
// afterwards; the user's real Software\Classes is never touched.

public sealed class FileAssociationTests : IDisposable
{
    private readonly string _keyPath = @"Software\LazyPrint.Tests-" + Guid.NewGuid().ToString("N");

    public void Dispose() => Registry.CurrentUser.DeleteSubKeyTree(_keyPath, throwOnMissingSubKey: false);

    private const string Exe = @"C:\Program Files\Lazy Print\LazyPrint.exe";

    [Fact]
    public void Entries_PointTheSchemeAtTheApp()
    {
        var entries = FileAssociation.Entries(Exe);
        string open = $"\"{Exe}\" \"%1\"";
        Assert.Contains(("lazyprint", "", "URL:Lazy Print"), entries);
        Assert.Contains(("lazyprint", "URL Protocol", ""), entries);
        Assert.Contains((@"lazyprint\shell\open\command", "", open), entries);
    }

    [Fact]
    public void Entries_ListTheAppInOpenWithAndNeverAsTheDefault()
    {
        var entries = FileAssociation.Entries(Exe);
        Assert.Contains((@"Applications\LazyPrint.exe\SupportedTypes", ".pdf", ""), entries);
        Assert.Contains((@"Applications\LazyPrint.exe\SupportedTypes", ".heic", ""), entries);
        Assert.Contains((@"Applications\LazyPrint.exe\SupportedTypes", ".heif", ""), entries);
        Assert.Contains((@"Applications\LazyPrint.exe\SupportedTypes", ".webp", ""), entries);
        Assert.Contains((@".txt\OpenWithProgids", "LazyPrint.File", ""), entries);
        Assert.Contains((@".pdf\OpenWithProgids", "LazyPrint.File", ""), entries);
        Assert.Contains((@".tiff\OpenWithProgids", "LazyPrint.File", ""), entries);
        Assert.DoesNotContain(entries, e => e.Key.StartsWith('.') && !e.Key.EndsWith(@"\OpenWithProgids"));
    }

    [Fact]
    public void Register_WritesOnceAndFollowsTheExe()
    {
        using var classes = Registry.CurrentUser.CreateSubKey(_keyPath);
        Assert.True(FileAssociation.Register(classes, Exe));
        foreach (var (name, valueName, value) in FileAssociation.Entries(Exe))
        {
            using var key = classes.OpenSubKey(name);
            Assert.Equal(value, key?.GetValue(valueName));
        }
        // A second start changes nothing; a moved exe is followed.
        Assert.False(FileAssociation.Register(classes, Exe));
        Assert.True(FileAssociation.Register(classes, @"D:\Apps\LazyPrint.exe"));
        using var command = classes.OpenSubKey(@"lazyprint\shell\open\command");
        Assert.Equal("\"D:\\Apps\\LazyPrint.exe\" \"%1\"", command?.GetValue(""));
    }
}
