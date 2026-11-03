using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/SystemQueueProblemsTests.swift: the same cases.

public class SystemQueueProblemsTests
{
    [Theory]
    [InlineData(SystemQueueState.Paused, "Printer paused", true)]
    [InlineData(SystemQueueState.Error, "Printer error", true)]
    [InlineData(SystemQueueState.Offline, "Printer offline", true)]
    [InlineData(SystemQueueState.PaperOut, "Out of paper", true)]
    [InlineData(SystemQueueState.PaperJam, "Paper jam", true)]
    [InlineData(SystemQueueState.DoorOpen, "Cover open", true)]
    [InlineData(SystemQueueState.TonerLow, "Toner low", false)]
    [InlineData(SystemQueueState.NoToner, "Toner empty", true)]
    [InlineData(SystemQueueState.UserIntervention, "Printer error", true)]
    public void Describe_State_GivesTheTitleIppGives(SystemQueueState state, string title, bool isError)
    {
        var problem = Assert.Single(SystemQueueProblems.Describe([state]));
        Assert.Equal(title, problem.Title);
        Assert.Equal(isError, problem.IsError);
        Assert.NotEmpty(problem.Advice);
    }

    [Fact]
    public void Describe_HasTheAdviceOfIpp()
    {
        Assert.Equal("Load paper in the tray, then press Resume.", SystemQueueProblems.Describe([SystemQueueState.PaperOut])[0].Advice);
        Assert.Equal(IppProblems.Describe(["media-jam"], null, true), SystemQueueProblems.Describe([SystemQueueState.PaperJam]));
        Assert.Equal(IppProblems.Describe(["toner-low-report"], null, true), SystemQueueProblems.Describe([SystemQueueState.TonerLow]));
        Assert.Equal(IppProblems.Describe([], null, false), SystemQueueProblems.Describe([SystemQueueState.Offline]));
    }

    [Fact]
    public void Describe_Busy_IsNotAProblem()
    {
        Assert.Empty(SystemQueueProblems.Describe([SystemQueueState.Busy]));
        Assert.Empty(SystemQueueProblems.Describe([]));
    }

    [Fact]
    public void Describe_ErrorsComeFirst_AndEachKindOnce()
    {
        var problems = SystemQueueProblems.Describe(
            [SystemQueueState.TonerLow, SystemQueueState.Error, SystemQueueState.UserIntervention, SystemQueueState.PaperJam, SystemQueueState.Busy]);
        Assert.Equal([("Printer error", true), ("Paper jam", true), ("Toner low", false)], problems.Select(p => (p.Title, p.IsError)));
    }

    [Fact]
    public void Describe_Offline_IsOfflineAlone()
    {
        var problem = Assert.Single(SystemQueueProblems.Describe([SystemQueueState.PaperJam, SystemQueueState.Offline]));
        Assert.Equal("Printer offline", problem.Title);
    }
}
