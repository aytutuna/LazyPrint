using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppStatusTests.swift: the same cases.

public class IppStatusTests
{
    [Theory]
    [InlineData((ushort)0x0000, "successful-ok")]
    [InlineData((ushort)0x0001, "successful-ok-ignored-or-substituted-attributes")]
    [InlineData((ushort)0x0406, "client-error-not-found")]
    [InlineData((ushort)0x040A, "client-error-document-format-not-supported")]
    [InlineData((ushort)0x0411, "client-error-document-format-error")]
    [InlineData((ushort)0x041B, "client-error-document-unprintable-error")]
    [InlineData((ushort)0x0503, "server-error-version-not-supported")]
    [InlineData((ushort)0x0506, "server-error-not-accepting-jobs")]
    [InlineData((ushort)0x0507, "server-error-busy")]
    [InlineData((ushort)0x0999, "0x0999")]
    public void Name_IsTheKeywordOrTheNumber(ushort code, string name) => Assert.Equal(name, IppStatuses.Name(code));

    [Fact]
    public void Numbers_AreThoseOfRfc8011()
    {
        Assert.Equal(0x0402, (int)IppStatus.ClientErrorNotAuthenticated);
        Assert.Equal(0x0420, (int)IppStatus.ClientErrorNotFetchable);
        Assert.Equal(0x050C, (int)IppStatus.ServerErrorTooManyDocuments);
    }
}
