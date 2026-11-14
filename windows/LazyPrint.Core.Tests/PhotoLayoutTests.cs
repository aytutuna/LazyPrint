using LazyPrint.Core;
using Xunit;
using static LazyPrint.Core.Tests.LayoutFixtures;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PhotoLayoutTests.swift: the same case.

public class PhotoLayoutTests
{
    private static PhotoSize Size(string id) => PhotoSize.All.Single(s => s.Id == id);

    [Fact]
    public void All_ListsTheSizesWithTheirIds()
    {
        Assert.Equal(["4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm", "page"], PhotoSize.All.Select(s => s.Id));
        Assert.Equal("4 × 6 in", Size("4x6").Title);
        Assert.Equal("10 × 15 cm", Size("10x15cm").Title);
        Assert.Equal("Largest that fits", Size("page").Title);
        Assert.Equal(new LayoutSize(288, 432), Size("4x6").Size);
        Assert.Null(Size("page").Size);
        Assert.Equal(100 * 72 / 25.4, Size("10x15cm").Size!.Value.Width, 0.0001);
    }
}
