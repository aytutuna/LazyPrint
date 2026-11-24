using System.Xml.Linq;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class ManifestTests
{
    [Fact]
    public void TheAppManifestIsWellFormedAndDeclaresCompatibility()
    {
        var root = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "app.manifest")).Root!;
        var compat = root.Element(XName.Get("compatibility", "urn:schemas-microsoft-com:compatibility.v1"));
        Assert.NotNull(compat);
    }
}
