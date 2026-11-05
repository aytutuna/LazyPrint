using LazyPrint.App.Services;
using LazyPrint.Core;
using Microsoft.Win32;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class PackagingTests
{
    [Fact]
    public void ThePackageCallAnswersTooSmallABufferOnlyInsideAPackage()
    {
        Assert.True(Packaging.IsPackageResult(122));
        Assert.False(Packaging.IsPackageResult(15700)); // APPMODEL_ERROR_NO_PACKAGE
        Assert.False(Packaging.IsPackageResult(0));
    }

    [Fact]
    public void TheTestHostIsNotPackaged() => Assert.False(Packaging.IsPackaged);

    [Fact]
    public void APackagedAppWritesNothingToTheUsersClasses()
    {
        static bool Registered()
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Classes\" + LazyPrintUrl.Scheme);
            return key is not null;
        }
        bool before = Registered();
        Packaging.IsPackaged = true;
        try
        {
            FileAssociation.RegisterForCurrentUser();
        }
        finally
        {
            Packaging.IsPackaged = false;
        }
        Assert.Equal(before, Registered());
    }
}
