using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppProblemsTests.swift: the same cases.

public class IppProblemsTests
{
    private static IReadOnlyList<PrinterProblem> Describe(params string[] reasons) => IppProblems.Describe(reasons, null, true);

    [Theory]
    [InlineData("media-empty", "Out of paper", true)]
    [InlineData("media-empty-error", "Out of paper", true)]
    [InlineData("media-empty-warning", "Out of paper", false)]
    [InlineData("media-empty-report", "Out of paper", false)]
    [InlineData("media-needed", "Out of paper", false)]
    [InlineData("media-needed-error", "Out of paper", true)]
    [InlineData("media-jam", "Paper jam", true)]
    [InlineData("media-jam-warning", "Paper jam", false)]
    [InlineData("cover-open", "Cover open", true)]
    [InlineData("door-open-error", "Cover open", true)]
    [InlineData("marker-supply-empty", "Ink empty", true)]
    [InlineData("marker-supply-empty-warning", "Ink empty", false)]
    [InlineData("marker-supply-low", "Ink low", false)]
    [InlineData("marker-supply-low-warning", "Ink low", false)]
    [InlineData("marker-supply-low-error", "Ink low", true)]
    [InlineData("toner-empty-error", "Toner empty", true)]
    [InlineData("toner-low-report", "Toner low", false)]
    [InlineData("paused", "Printer paused", true)]
    [InlineData("output-area-full-error", "Output tray full", true)]
    [InlineData("marker-waste-full-error", "Waste tank full", true)]
    public void Describe_KnownReason_GivesTitleAndSeverity(string reason, string title, bool isError)
    {
        var problem = Assert.Single(Describe(reason));
        Assert.Equal(title, problem.Title);
        Assert.Equal(isError, problem.IsError);
        Assert.NotEmpty(problem.Advice);
    }

    [Fact]
    public void Describe_None_IsNothing()
    {
        Assert.Empty(Describe("none"));
        Assert.Empty(Describe());
    }

    [Fact]
    public void Describe_UnknownReasonsWithoutAnErrorSuffix_AreLeftOut()
    {
        Assert.Empty(Describe("connecting-to-device", "other-warning", "spool-area-full", "timed-out-report"));
    }

    [Fact]
    public void Describe_UnknownError_IsAPrinterErrorWithThePrintersMessage()
    {
        var problem = Assert.Single(IppProblems.Describe(["fuser-over-temp-error"], " Fuser too hot ", true));
        Assert.Equal("Printer error", problem.Title);
        Assert.Equal("Fuser too hot", problem.Advice);
        Assert.True(problem.IsError);
        Assert.Equal("Check the printer's display.", Assert.Single(IppProblems.Describe(["fuser-over-temp-error"], "", true)).Advice);
    }

    [Fact]
    public void Describe_ErrorsComeFirst_AndEachKindOnce()
    {
        var problems = Describe("toner-low-report", "media-empty-warning", "media-jam", "media-empty-error", "media-empty-error", "marker-supply-low");
        Assert.Equal(
            [("Paper jam", true), ("Out of paper", true), ("Toner low", false), ("Out of paper", false), ("Ink low", false)],
            problems.Select(p => (p.Title, p.IsError)));
    }

    [Fact]
    public void Describe_Unreachable_IsOfflineAlone()
    {
        var problem = Assert.Single(IppProblems.Describe(["media-jam"], null, false));
        Assert.Equal("Printer offline", problem.Title);
        Assert.True(problem.IsError);
    }

    [Fact]
    public void Describe_TheTextsOfTheContract()
    {
        Assert.Equal("Load paper in the tray, then press Resume.", Describe("media-empty-error")[0].Advice);
    }

    [Fact]
    public void Describe_CanonFixture_IsLowInkWithoutAnError()
    {
        var caps = IppFixtures.Capabilities("canon-pixma");
        var problem = Assert.Single(IppProblems.Describe(caps.StateReasons, caps.StateMessage, true));
        Assert.Equal("Ink low", problem.Title);
        Assert.False(problem.IsError);
    }
}
