using LazyPrint.App.Services;
using LazyPrint.Core;
using System.Xml.Linq;
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

    [Fact]
    public void AQuotedPathWithSpacesArrivesAsOneFile()
    {
        // The manifest passes "%1" in quotes, which the process's argument parsing turns into one argument.
        Assert.Equal([@"C:\My Documents\Annual report.pdf"], LazyPrint.App.App.FilesOf([@"C:\My Documents\Annual report.pdf"]));
    }

    [Fact]
    public void TheStorePackageOpensThePhoneLinkPortInTheFirewall()
    {
        XNamespace desktop2 = "http://schemas.microsoft.com/appx/manifest/desktop/windows10/2";
        var rules = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "Package.appxmanifest")).Descendants(desktop2 + "Rule").ToList();
        var rule = Assert.Single(rules);
        string port = CompanionProtocol.DefaultPort.ToString();
        Assert.Equal("52732", port);
        Assert.Equal("in", (string?)rule.Attribute("Direction"));
        Assert.Equal("TCP", (string?)rule.Attribute("IPProtocol"));
        Assert.Equal(port, (string?)rule.Attribute("LocalPortMin"));
        Assert.Equal(port, (string?)rule.Attribute("LocalPortMax"));
        Assert.Equal("LazyPrint.exe", (string?)rule.Parent!.Attribute("Executable"));
    }
}
