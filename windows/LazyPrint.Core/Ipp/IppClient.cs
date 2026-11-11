using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Security.Authentication;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppClient.swift (URLSession there). This one takes the handler that carries the
// trust check; the Swift one builds it from its trust store. An IppCertificateException is thrown as it is so the
// caller can ask the user; every other failure is a PrintException.

/// <summary>Timeouts and retry timing of an <see cref="IppClient"/>.</summary>
public sealed class IppClientOptions
{
    /// <summary>Every request but Print-Job: a printer that is silent this long, before or while it answers, is treated as gone.</summary>
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(10);
    /// <summary>Print-Job: counted from the last byte sent, since printers answer only once they have taken the whole document.</summary>
    public TimeSpan PrintTimeout { get; init; } = TimeSpan.FromSeconds(120);
    /// <summary>Waits between busy answers; null = <see cref="IppRetryPolicy.Default"/>.</summary>
    public IppRetryPolicy? RetryPolicy { get; init; }
    /// <summary>How a retry waits; null = real time (tests pass a fake clock).</summary>
    public Func<TimeSpan, CancellationToken, Task>? Delay { get; init; }
    /// <summary>Time since a request's first attempt, for the retry policy; null = real time.</summary>
    public Func<Func<TimeSpan>>? StartClock { get; init; }
}

/// <summary>
/// IPP over HTTP for one printer: its capabilities, Print-Job, Get-Job-Attributes and Cancel-Job. The
/// transport is an injected <see cref="HttpMessageHandler"/> (no proxy, and for ipps the one of
/// <see cref="IppCertificateValidator.CreateHandler"/>), so it runs against a loopback printer in tests.
/// Failures are <see cref="PrintException"/>s, or an <see cref="IppCertificateException"/> when
/// <paramref name="validator"/> refused the printer's certificate.
/// </summary>
/// <param name="address">Where the printer answers; <see cref="Address"/> follows it to ipps or back to ipp.</param>
/// <param name="handler">Owned by the client and disposed with it.</param>
/// <param name="printerName">The printer's name in messages.</param>
/// <param name="userName">requesting-user-name: the account name, "iPhone" on the iPhone. The same for every request, or Cancel-Job is refused.</param>
public sealed class IppClient(PrinterAddress address, HttpMessageHandler handler, string printerName, string userName,
                              IppCertificateValidator? validator = null, IppClientOptions? options = null) : IDisposable
{
    private readonly IppClientOptions _options = options ?? new IppClientOptions();
    private readonly HttpClient _http = new(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
    // host:port of printers that never completed a TLS handshake and were never trusted, for the session.
    private static readonly ConcurrentDictionary<string, bool> NoTls = new();
    private int _requestId;
    private bool _speaks11;

    /// <summary>Where requests go now: moved to ipps by an HTTP 426, or back to ipp when the TLS handshake failed.</summary>
    public PrinterAddress Address { get; private set; } = address;
    public string PrinterName { get; } = printerName;
    /// <summary>The printer is reached over plain ipp because its ipps would not complete a handshake.</summary>
    public bool NotEncrypted { get; private set; }

    /// <summary>
    /// Get-Printer-Attributes. Remembers a printer without IPP 2.0 as 1.1 for the session, and pins a
    /// certificate accepted for first use once the printer's UUID shows it is not another key for a
    /// printer trusted before (<see cref="IppCertificateValidator.RememberDevice"/>).
    /// </summary>
    public async Task<PrinterCapabilities> CapabilitiesAsync(CancellationToken token = default)
    {
        var response = await RoundTrip((uri, id) => IppRequests.GetPrinterAttributes(uri, userName, id), null, token).ConfigureAwait(false);
        Succeeded(response);
        var capabilities = PrinterCapabilities.From(response);
        if (capabilities.IppVersionsSupported.Count > 0 && !capabilities.Speaks20) _speaks11 = true;
        validator?.RememberDevice(capabilities.Uuid);
        return capabilities;
    }

    /// <summary>
    /// Print-Job: the encoded request, then the file at <paramref name="document"/> (an <see cref="IppSpool"/>'s),
    /// in one body with a Content-Length. A busy printer is asked again with the file sent again. The file is
    /// the caller's to delete.
    /// </summary>
    public async Task<IppJob> PrintAsync(string document, IppJobTicket ticket, CancellationToken token = default)
    {
        // A first-use certificate is pinned (or refused) before the document goes out over it.
        if (validator is { HasPendingFirstUse: true } && Address.Secure) await CapabilitiesAsync(token).ConfigureAwait(false);
        var response = await RoundTrip((uri, id) => IppRequests.PrintJob(uri, userName, ticket, id), document, token).ConfigureAwait(false);
        // A printer that refuses media-col is asked once more for the paper by its name.
        if (response.Code == (ushort)IppStatus.ClientErrorAttributesOrValuesNotSupported && ticket.Media.Entry is not null)
        {
            var plain = ticket with { Media = ticket.Media with { Entry = null } };
            response = await RoundTrip((uri, id) => IppRequests.PrintJob(uri, userName, plain, id), document, token).ConfigureAwait(false);
        }
        Succeeded(response);
        var job = IppJob.From(response) ?? throw new PrintException(new PrintError.BadResponse());
        if (job.Reasons.Contains("job-password-wait"))
        {
            try { await CancelAsync(job.Id, token).ConfigureAwait(false); } catch (PrintException) { }
            throw Failure(new PrintError.NeedsSignIn());
        }
        return job;
    }

    /// <summary>
    /// Get-Job-Attributes. A printer that no longer knows an accepted job may have finished it or lost it: that is
    /// <see cref="PrintError.LostContact"/>, since nothing says it was printed.
    /// </summary>
    public async Task<IppJob> JobAsync(int id, CancellationToken token = default)
    {
        var response = await RoundTrip((uri, requestId) => IppRequests.GetJobAttributes(uri, userName, id, requestId), null, token).ConfigureAwait(false);
        if (response.Code == (ushort)IppStatus.ClientErrorNotFound) throw Failure(new PrintError.LostContact(PrinterName));
        Succeeded(response);
        return IppJob.From(response, id)!;
    }

    /// <summary>The printer's printer-state-reasons, for saying why a job waits.</summary>
    public async Task<IReadOnlyList<string>> PrinterReasonsAsync(CancellationToken token = default)
    {
        var response = await RoundTrip((uri, id) => IppRequests.GetPrinterReasons(uri, userName, id), null, token).ConfigureAwait(false);
        Succeeded(response);
        return response["printer-state-reasons"] is { } reasons ? [.. reasons.Values.OfType<IppValue.Keyword>().Select(k => k.Value)] : [];
    }

    /// <summary>Cancel-Job. A job the printer does not know, or can no longer cancel, is already over.</summary>
    public async Task CancelAsync(int id, CancellationToken token = default)
    {
        var response = await RoundTrip((uri, requestId) => IppRequests.CancelJob(uri, userName, id, requestId), null, token).ConfigureAwait(false);
        if (response.Code is (ushort)IppStatus.ClientErrorNotFound or (ushort)IppStatus.ClientErrorNotPossible) return;
        Succeeded(response);
    }

    public void Dispose()
    {
        _http.Dispose();
        handler.Dispose();
    }

    /// <summary>
    /// Sends one request and returns the printer's answer, whatever its IPP status. Busy answers are
    /// retried; HTTP 426 moves to ipps, a failed handshake to ipp, and IPP 0x0503 to version 1.1, each once.
    /// </summary>
    private async Task<IppMessage> RoundTrip(Func<string, int, IppMessage> build, string? document, CancellationToken token)
    {
        bool switched = false;
        if (Address.Secure && validator is not null && NoTls.ContainsKey(Address.Authority) && !validator.Knows(Address.Authority))
        {
            Address = Address.WithSecure(false);
            NotEncrypted = true;
        }
        while (true)
        {
            validator?.TakeRejection(); // a refusal left by an earlier request is not this one's
            var certificateSeen = new StrongBox<bool>();
            var request = build(Address.PrinterUri, Interlocked.Increment(ref _requestId));
            if (_speaks11) request = IppRequests.Downgraded(request);
            byte[] head = request.Encoded();
            HttpResponseMessage response;
            try
            {
                response = await IppRetry.SendAsync(ct => Post(head, document, certificateSeen, ct), token, _options.RetryPolicy,
                    _options.Delay, _options.StartClock?.Invoke(), IsBusy).ConfigureAwait(false);
            }
            catch (HttpRequestException e)
            {
                if (validator?.TakeRejection() is { } rejection) throw rejection;
                // Only a handshake that failed before any certificate was seen, for a printer not trusted before,
                // means the printer has no usable TLS; anything else could be someone cutting the connection.
                if (IsHandshakeFailure(e) && Address.Secure && !switched
                    && validator is not null && !certificateSeen.Value && !validator.Knows(Address.Authority))
                {
                    NoTls[Address.Authority] = true;
                    Address = Address.WithSecure(false);
                    NotEncrypted = true;
                    switched = true;
                    continue;
                }
                throw Failure(new PrintError.Unreachable(PrinterName, IsHandshakeFailure(e) ? "no secure connection" : Reason(e)));
            }
            catch (OperationCanceledException)
            {
                validator?.TakeRejection();
                if (token.IsCancellationRequested) throw;
                throw Failure(new PrintError.Unreachable(PrinterName, "it did not answer in time"));
            }

            using (response)
            {
                if ((int)response.StatusCode == 426 && !Address.Secure && !switched)
                {
                    Address = Address.WithSecure(true);
                    switched = true;
                    continue;
                }
                if (response.StatusCode == HttpStatusCode.Unauthorized) throw Failure(new PrintError.NeedsSignIn());
                if (IppRetry.IsRetryable(response.StatusCode)) throw Failure(new PrintError.Busy());
                var message = TryDecode(await response.Content.ReadAsByteArrayAsync(token).ConfigureAwait(false));
                if (message is null)
                {
                    throw Failure(response.IsSuccessStatusCode
                        ? new PrintError.BadResponse()
                        : new PrintError.Unreachable(PrinterName, $"it answered HTTP {(int)response.StatusCode}"));
                }
                if (message.Code == (ushort)IppStatus.ServerErrorVersionNotSupported && !_speaks11)
                {
                    _speaks11 = true;
                    continue;
                }
                return message;
            }
        }
    }

    /// <summary>
    /// POSTs a request. The timeout is an idle one: re-armed with every chunk written (a document), after the last byte, and
    /// with every chunk of the answer read, so a printer that keeps sending a long answer slowly is not cut off.
    /// </summary>
    private async Task<HttpResponseMessage> Post(byte[] head, string? document, StrongBox<bool> certificateSeen, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        TimeSpan limit = document is null ? _options.RequestTimeout : _options.PrintTimeout;
        timeout.CancelAfter(limit);
        var content = new IppContent(head, document, () => timeout.CancelAfter(limit));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/ipp");
        using var request = new HttpRequestMessage(HttpMethod.Post, Address.RequestUri) { Content = content };
        request.Headers.ExpectContinue = false;
        try
        {
            var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            try
            {
                await LimitBody(response, () => timeout.CancelAfter(limit), timeout.Token).ConfigureAwait(false);
            }
            catch
            {
                response.Dispose();
                throw;
            }
            return response;
        }
        finally
        {
            if (request.Options.TryGetValue(IppCertificateValidator.CertificateSeen, out bool seen) && seen)
                certificateSeen.Value = true;
        }
    }

    // A printer's answer is a few hundred KB at most; a bigger one is refused before it is all read.
    private const int MaxResponse = 8 * 1024 * 1024;

    private static async Task LimitBody(HttpResponseMessage response, Action armTimeout, CancellationToken token)
    {
        if (response.Content.Headers.ContentLength > MaxResponse) throw Failure(new PrintError.BadResponse());
        var body = new MemoryStream();
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
            var chunk = new byte[81920];
            int read;
            while ((read = await stream.ReadAsync(chunk, token).ConfigureAwait(false)) > 0)
            {
                armTimeout();
                if (body.Length + read > MaxResponse) throw Failure(new PrintError.BadResponse());
                body.Write(chunk, 0, read);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            // A reply cut off mid-body is the connection dropping, as it was before the body was read here.
            throw new HttpRequestException(HttpRequestError.ResponseEnded, e.Message, e);
        }
        response.Content = new ByteArrayContent(body.ToArray());
    }

    private static async Task<bool> IsBusy(HttpResponseMessage response)
    {
        if (IppRetry.IsRetryable(response.StatusCode)) return true;
        var message = TryDecode(await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false));
        return message is not null && IppRetry.IsRetryable((IppStatus)message.Code);
    }

    private static IppMessage? TryDecode(byte[] body)
    {
        try
        {
            return IppMessage.Decode(body).Message;
        }
        catch (PrintException)
        {
            return null;
        }
    }

    private static bool IsHandshakeFailure(HttpRequestException e) =>
        e.HttpRequestError == HttpRequestError.SecureConnectionError || e.InnerException is AuthenticationException;

    private static string Reason(HttpRequestException e) =>
        e.HttpRequestError == HttpRequestError.ConnectionError ? "it did not answer" : e.Message;

    private static PrintException Failure(PrintError error) => new(error);

    private static void Succeeded(IppMessage response)
    {
        if (response.IsSuccess) return;
        ushort code = response.Code;
        if (code is (ushort)IppStatus.ClientErrorNotAuthenticated or (ushort)IppStatus.ClientErrorNotAuthorized)
            throw Failure(new PrintError.NeedsSignIn());
        if (code == (ushort)IppStatus.ServerErrorBusy) throw Failure(new PrintError.Busy());
        string detail = code == (ushort)IppStatus.ServerErrorNotAcceptingJobs
            ? "The printer is not accepting jobs"
            : response["status-message"]?.Values.FirstOrDefault() is IppValue.Text message ? message.Value : "";
        throw Failure(new PrintError.Refused(code, detail));
    }

    /// <summary>The request body: the encoded operation, then the document. Its length is known, so it is never chunked.</summary>
    private sealed class IppContent(byte[] head, string? document, Action armTimeout) : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken token)
        {
            armTimeout();
            await stream.WriteAsync(head, token).ConfigureAwait(false);
            if (document is not null)
            {
                await using var file = new FileStream(document, FileMode.Open, FileAccess.Read, FileShare.Read);
                var chunk = new byte[81920];
                int read;
                while ((read = await file.ReadAsync(chunk, token).ConfigureAwait(false)) > 0)
                {
                    armTimeout();
                    await stream.WriteAsync(chunk.AsMemory(0, read), token).ConfigureAwait(false);
                }
            }
            armTimeout();
        }

        protected override bool TryComputeLength(out long length)
        {
            length = head.Length + (document is null ? 0 : new FileInfo(document).Length);
            return true;
        }
    }
}
