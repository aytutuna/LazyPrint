using System.Printing;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class PrinterQueueTests
{
    [Theory]
    [InlineData(PrintJobStatus.Spooling, QueuedJobState.Waiting)]
    [InlineData(PrintJobStatus.None, QueuedJobState.Waiting)]
    [InlineData(PrintJobStatus.Printing, QueuedJobState.Printing)]
    [InlineData(PrintJobStatus.Paused, QueuedJobState.Held)]
    [InlineData(PrintJobStatus.Printing | PrintJobStatus.PaperOut, QueuedJobState.Stopped)]
    [InlineData(PrintJobStatus.Error, QueuedJobState.Stopped)]
    public void TheSpoolersStatusIsTheJobsState(PrintJobStatus status, QueuedJobState state) =>
        Assert.Equal(state, PrinterQueue.StateOf(status));

    [Fact]
    public void OnlyPrintersWithAQueueHaveOne()
    {
        PrinterInfo Info(PrinterRoute route, IppEndpoint? endpoint) =>
            new("x", "X", null, null, route, endpoint, false, PrinterState.Idle, [], []);
        Assert.True(PrinterQueue.Has(Info(PrinterRoute.System, null)));
        Assert.False(PrinterQueue.Has(Info(PrinterRoute.Ipp, null)));
        Assert.False(PrinterQueue.Has(Info(PrinterRoute.Demo, null)));
    }
}
