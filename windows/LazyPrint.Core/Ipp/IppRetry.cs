using System.Diagnostics;
using System.Net;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppRetry.swift: the same rules and tests on both platforms.

/// <summary>
/// How long to keep retrying an IPP request a printer answers as busy (HTTP 503, or the IPP status
/// server-error-busy): the wait starts at <see cref="InitialDelay"/>, grows by
/// <see cref="Multiplier"/> up to <see cref="MaxDelay"/>, and retrying stops once another wait
/// would pass <see cref="GiveUpAfter"/> since the first attempt.
/// </summary>
public sealed record IppRetryPolicy(TimeSpan InitialDelay, double Multiplier, TimeSpan MaxDelay, TimeSpan GiveUpAfter)
{
    public static IppRetryPolicy Default { get; } =
        new(TimeSpan.FromSeconds(0.5), 1.5, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(60));

    /// <summary>
    /// The wait before retry number <paramref name="retry"/> (0-based). A Retry-After the
    /// printer sent replaces the computed wait, kept within [InitialDelay, MaxDelay].
    /// </summary>
    public TimeSpan DelayBefore(int retry, TimeSpan? retryAfter = null)
    {
        if (retryAfter is { } asked)
        {
            return asked < InitialDelay ? InitialDelay : asked > MaxDelay ? MaxDelay : asked;
        }
        double seconds = InitialDelay.TotalSeconds * Math.Pow(Multiplier, Math.Max(0, retry));
        return seconds >= MaxDelay.TotalSeconds ? MaxDelay : TimeSpan.FromSeconds(seconds);
    }
}

public static class IppRetry
{
    /// <summary>The HTTP status that is retried: 503 Service Unavailable.</summary>
    public static bool IsRetryable(HttpStatusCode status) => status == HttpStatusCode.ServiceUnavailable;

    /// <summary>The IPP status that is retried: server-error-busy (0x0507).</summary>
    public static bool IsRetryable(IppStatus status) => status == IppStatus.ServerErrorBusy;

    /// <summary>
    /// Send a request, repeating it while the printer says it is busy, per <paramref name="policy"/>
    /// (default <see cref="IppRetryPolicy.Default"/>). Returns the first other response, or the
    /// last busy one once the policy gives up; responses that are retried are disposed.
    /// <paramref name="send"/> must create a fresh request each time. Busy is HTTP 503, or, when
    /// <paramref name="isBusy"/> is given, whatever it says of the response (it may read the IPP
    /// status from a buffered body). <paramref name="delay"/> and <paramref name="elapsed"/> (time
    /// since the first attempt) default to real time and exist so tests can run without waiting.
    /// </summary>
    public static async Task<HttpResponseMessage> SendAsync(
        Func<CancellationToken, Task<HttpResponseMessage>> send,
        CancellationToken cancellationToken = default,
        IppRetryPolicy? policy = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<TimeSpan>? elapsed = null,
        Func<HttpResponseMessage, Task<bool>>? isBusy = null)
    {
        policy ??= IppRetryPolicy.Default;
        delay ??= Task.Delay;
        isBusy ??= response => Task.FromResult(IsRetryable(response.StatusCode));
        if (elapsed is null)
        {
            var clock = Stopwatch.StartNew();
            elapsed = () => clock.Elapsed;
        }
        for (int retry = 0; ; retry++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var response = await send(cancellationToken).ConfigureAwait(false);
            if (!await isBusy(response).ConfigureAwait(false)) return response;
            var wait = policy.DelayBefore(retry, response.Headers.RetryAfter?.Delta);
            if (elapsed() + wait > policy.GiveUpAfter) return response;
            response.Dispose();
            await delay(wait, cancellationToken).ConfigureAwait(false);
        }
    }
}
