using LazyPrint.App.Services;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class LazyScanLookupTests
{
    [Fact]
    public void AnAnswerThatNeverComesCountsAsNotInstalled()
    {
        var never = new TaskCompletionSource<bool>();
        Assert.False(WindowsSystemDiagnostics.AnsweredYes(never.Task, TimeSpan.FromMilliseconds(50)));
    }

    [Fact]
    public void AnAnswerInTimeIsUsed()
    {
        Assert.True(WindowsSystemDiagnostics.AnsweredYes(Task.FromResult(true), TimeSpan.FromSeconds(1)));
        Assert.False(WindowsSystemDiagnostics.AnsweredYes(Task.FromResult(false), TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public void TheDirectBuildAsksOnlyTheRegistry()
    {
        Assert.False(Packaging.IsPackaged);
        using var key = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("lazyscan");
        Assert.Equal(key is not null, new WindowsSystemDiagnostics().LazyScanInstalled());
    }
}
