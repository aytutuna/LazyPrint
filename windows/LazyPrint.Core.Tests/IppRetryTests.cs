using System.Net;
using System.Net.Http.Headers;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppRetryTests.swift (same cases). Time is simulated: the
// fake delay advances a fake clock instead of waiting.

public class IppRetryTests
{
    /// <summary>Answers with the queued statuses in order, then 200; records every request.</summary>
    private sealed class StubHandler(params HttpStatusCode[] statuses) : HttpMessageHandler
    {
        private readonly Queue<HttpStatusCode> _statuses = new(statuses);
        public int Requests { get; private set; }
        public TimeSpan? RetryAfter { get; init; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            var status = _statuses.Count > 0 ? _statuses.Dequeue() : HttpStatusCode.OK;
            var response = new HttpResponseMessage(status) { RequestMessage = request };
            if (status == HttpStatusCode.ServiceUnavailable && RetryAfter is { } after)
            {
                response.Headers.RetryAfter = new RetryConditionHeaderValue(after);
            }
            return Task.FromResult(response);
        }
    }

    private sealed class FakeClock
    {
        public TimeSpan Now { get; private set; }
        public List<TimeSpan> Delays { get; } = [];

        public Task Delay(TimeSpan wait, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Delays.Add(wait);
            Now += wait;
            return Task.CompletedTask;
        }
    }

    private static Task<HttpResponseMessage> Send(HttpClient client, FakeClock clock, CancellationToken token = default) =>
        IppRetry.SendAsync(ct => client.GetAsync("http://printer:631/ipp/print", ct),
                            token, policy: null, clock.Delay, () => clock.Now);

    [Fact]
    public async Task RetriesBusyThenSucceeds()
    {
        var handler = new StubHandler(HttpStatusCode.ServiceUnavailable, HttpStatusCode.ServiceUnavailable);
        var clock = new FakeClock();
        using var response = await Send(new HttpClient(handler), clock);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(3, handler.Requests);
        Assert.Equal([TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(0.75)], clock.Delays);
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.Conflict)]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.OK)]
    public async Task OtherStatusesAreNotRetried(HttpStatusCode status)
    {
        var handler = new StubHandler(status);
        var clock = new FakeClock();
        using var response = await Send(new HttpClient(handler), clock);
        Assert.Equal(status, response.StatusCode);
        Assert.Equal(1, handler.Requests);
        Assert.Empty(clock.Delays);
    }

    [Fact]
    public async Task GivesUpAfterSixtySecondsWithTheLast503()
    {
        var handler = new StubHandler(Enumerable.Repeat(HttpStatusCode.ServiceUnavailable, 100).ToArray());
        var clock = new FakeClock();
        using var response = await Send(new HttpClient(handler), clock);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        // 0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875 (10.390625 s), then nine waits of 5 s
        // (55.390625 s); one more would pass 60 s.
        Assert.Equal(15, clock.Delays.Count);
        Assert.Equal(16, handler.Requests);
        Assert.True(clock.Now <= TimeSpan.FromSeconds(60));
        Assert.True(clock.Now + TimeSpan.FromSeconds(5) > TimeSpan.FromSeconds(60));
    }

    [Fact]
    public void BackoffGrowsByHalfAndCapsAtFiveSeconds()
    {
        var policy = IppRetryPolicy.Default;
        double[] seconds = [.. Enumerable.Range(0, 8).Select(i => policy.DelayBefore(i).TotalSeconds)];
        Assert.Equal([0.5, 0.75, 1.125, 1.6875, 2.53125, 3.796875, 5, 5], seconds);
    }

    [Fact]
    public async Task RetryAfterIsHonoredWithinTheBounds()
    {
        var handler = new StubHandler(HttpStatusCode.ServiceUnavailable) { RetryAfter = TimeSpan.FromSeconds(2) };
        var clock = new FakeClock();
        using (await Send(new HttpClient(handler), clock)) { }
        Assert.Equal([TimeSpan.FromSeconds(2)], clock.Delays);

        Assert.Equal(TimeSpan.FromSeconds(5), IppRetryPolicy.Default.DelayBefore(0, TimeSpan.FromSeconds(120)));
        Assert.Equal(TimeSpan.FromSeconds(0.5), IppRetryPolicy.Default.DelayBefore(3, TimeSpan.Zero));
    }

    [Fact]
    public async Task CancellationStopsRetrying()
    {
        var handler = new StubHandler(Enumerable.Repeat(HttpStatusCode.ServiceUnavailable, 100).ToArray());
        using var cts = new CancellationTokenSource();
        var clock = new FakeClock();
        var task = IppRetry.SendAsync(
            ct => new HttpClient(handler).GetAsync("http://printer:631/ipp/print", ct), cts.Token, policy: null,
            (wait, ct) =>
            {
                if (clock.Delays.Count == 2) cts.Cancel();
                return clock.Delay(wait, ct);
            },
            () => clock.Now);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Equal(3, handler.Requests);
    }

    [Fact]
    public async Task ABusyIppStatusInsideA200IsRetriedToo()
    {
        // Every answer is a 200 with the IPP status as two bytes: busy twice, then done.
        var statuses = new Queue<IppStatus>([IppStatus.ServerErrorBusy, IppStatus.ServerErrorBusy, IppStatus.SuccessfulOk]);
        var clock = new FakeClock();
        int requests = 0;
        using var response = await IppRetry.SendAsync(
            _ =>
            {
                requests++;
                ushort status = (ushort)statuses.Dequeue();
                var content = new ByteArrayContent([(byte)(status >> 8), (byte)status]);
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
            },
            CancellationToken.None, policy: null, clock.Delay, () => clock.Now,
            isBusy: async r =>
            {
                byte[] body = await r.Content.ReadAsByteArrayAsync();
                return IppRetry.IsRetryable((IppStatus)((body[0] << 8) | body[1]));
            });
        Assert.Equal(3, requests);
        Assert.Equal([TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(0.75)], clock.Delays);
    }

    [Fact]
    public void OnlyBusyIsRetriedOfTheIppStatuses()
    {
        Assert.True(IppRetry.IsRetryable(IppStatus.ServerErrorBusy));
        Assert.False(IppRetry.IsRetryable(IppStatus.ServerErrorNotAcceptingJobs));
        Assert.False(IppRetry.IsRetryable(IppStatus.SuccessfulOk));
    }
}
