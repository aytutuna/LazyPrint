using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PagePickerTests.swift: the same cases.

public class PagePickerTests
{
    [Fact]
    public void Apply_All_KeepsEveryPageInOrder()
    {
        Assert.Equal([0, 1, 2, 3, 4], PagePicker.Apply([0, 1, 2, 3, 4], PageSelection.All, false));
    }

    [Fact]
    public void Apply_Odd_KeepsPagesNumberedOdd()
    {
        Assert.Equal([0, 2, 4], PagePicker.Apply([0, 1, 2, 3, 4], PageSelection.Odd, false));
    }

    [Fact]
    public void Apply_Even_KeepsPagesNumberedEven()
    {
        Assert.Equal([1, 3], PagePicker.Apply([0, 1, 2, 3, 4], PageSelection.Even, false));
    }

    [Fact]
    public void Apply_Reverse_TurnsTheListAround()
    {
        Assert.Equal([4, 3, 2, 1, 0], PagePicker.Apply([0, 1, 2, 3, 4], PageSelection.All, true));
        Assert.Equal([4, 2, 0], PagePicker.Apply([0, 1, 2, 3, 4], PageSelection.Odd, true));
    }

    [Fact]
    public void Apply_AfterARange_CountsPageNumbersNotPlacesInTheRange()
    {
        // The range 2-5 is indices 1 to 4: the odd page numbers in it are 3 and 5.
        Assert.Equal([2, 4], PagePicker.Apply([1, 2, 3, 4], PageSelection.Odd, false));
        Assert.Equal([4, 2], PagePicker.Apply([1, 2, 3, 4], PageSelection.Odd, true));
    }

    [Fact]
    public void Apply_KeepsTheOrderAndRepeatsOfARange()
    {
        Assert.Equal([2, 0, 0], PagePicker.Apply([2, 1, 0, 0], PageSelection.Odd, false));
    }
}
