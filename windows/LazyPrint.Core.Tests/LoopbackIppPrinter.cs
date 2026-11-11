using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPrint.Core;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/LoopbackIppPrinter.swift: the same printer for the same cases.
// A printer on a loopback socket: plain HTTP, or TLS when it has a certificate (both on one port, told
// apart by the first byte). It records what it gets and answers from a script, else like a printer that
// is idle and takes everything.

/// <summary>One request as the printer received it. The body is de-chunked, but <see cref="Headers"/> shows whether it was.</summary>
internal sealed record LoopbackRequest(string Method, string Path, IReadOnlyDictionary<string, string> Headers, byte[] Body, bool Tls)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var value) ? value : null;

    /// <summary>The IPP message the body starts with.</summary>
    public IppMessage Ipp => IppMessage.Decode(Body).Message;

    /// <summary>What follows the IPP message: the document of a Print-Job.</summary>
    public byte[] Document => Body[IppMessage.Decode(Body).DocumentOffset..];
}

/// <summary>
/// What the printer answers: an HTTP status and body, after an optional wait. <paramref name="Chunked"/> sends the body
/// with no Content-Length; <paramref name="ClaimedLength"/> promises more than the body holds, then closes the connection.
/// </summary>
internal sealed record LoopbackAnswer(int Status, byte[] Body, TimeSpan Delay = default, string? RetryAfter = null,
                                      bool Chunked = false, int? ClaimedLength = null)
{
    /// <summary>An IPP response with the usual operation attributes, then <paramref name="groups"/>.</summary>
    public static LoopbackAnswer Ipp(IppStatus status, params IppGroup[] groups) => Ipp((ushort)status, groups);

    public static LoopbackAnswer Ipp(ushort status, params IppGroup[] groups)
    {
        IppGroup[] all =
        [
            new(IppTag.OperationAttributes,
            [
                new IppAttribute("attributes-charset", new IppValue.Charset("utf-8")),
                new IppAttribute("attributes-natural-language", new IppValue.Language("en")),
            ]),
            .. groups,
        ];
        return new LoopbackAnswer(200, new IppMessage(IppVersion.V20, status, 1, all).Encoded());
    }

    public static LoopbackAnswer Http(int status, string? retryAfter = null) => new(status, [], RetryAfter: retryAfter);

    /// <summary>A job group with the attributes a printer reports for a job.</summary>
    public static IppGroup Job(int id, int state, params string[] reasons) =>
        new(IppTag.JobAttributes,
        [
            new IppAttribute("job-id", new IppValue.Integer(id)),
            new IppAttribute("job-state", new IppValue.EnumValue(state)),
            new IppAttribute("job-state-reasons", [.. (reasons.Length == 0 ? ["none"] : reasons).Select(r => (IppValue)new IppValue.Keyword(r))]),
        ]);

    /// <summary>A printer group with its printer-state-reasons.</summary>
    public static IppGroup PrinterState(params string[] reasons) =>
        new(IppTag.PrinterAttributes,
        [
            new IppAttribute("printer-state-reasons", [.. (reasons.Length == 0 ? ["none"] : reasons).Select(r => (IppValue)new IppValue.Keyword(r))]),
        ]);

    public LoopbackAnswer After(TimeSpan delay) => this with { Delay = delay };
}

internal sealed class LoopbackIppPrinter : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly object _gate = new();
    private readonly List<LoopbackRequest> _requests = [];
    private readonly Queue<LoopbackAnswer> _script = new();
    private readonly List<TcpClient> _clients = [];
    private int _plainConnections;
    private int _tlsConnections;

    /// <summary>The Get-Printer-Attributes fixture this printer answers with (Tests/Fixtures/Ipp/printers).</summary>
    public string Fixture { get; init; } = "hp-laserjet";
    /// <summary>Serves TLS with this certificate; without one a TLS handshake is closed on.</summary>
    public X509Certificate2? Certificate { get; set; }
    /// <summary>Answers every plain request HTTP 426 (upgrade required), as a printer that wants ipps does.</summary>
    public bool UpgradeRequired { get; init; }

    public int Port { get; }
    public int PlainConnections => Volatile.Read(ref _plainConnections);
    public int TlsConnections => Volatile.Read(ref _tlsConnections);

    public LoopbackIppPrinter()
    {
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _ = Task.Run(AcceptAsync);
    }

    public PrinterAddress Address(bool secure = false) =>
        PrinterAddress.Parse($"{(secure ? "ipps" : "ipp")}://127.0.0.1:{Port}");

    /// <summary>Answers the next requests with these, in order, before falling back to the printer's own answers.</summary>
    public LoopbackIppPrinter Script(params LoopbackAnswer[] answers)
    {
        lock (_gate)
        {
            foreach (var answer in answers) _script.Enqueue(answer);
        }
        return this;
    }

    /// <summary>The requests received, whatever they were answered with.</summary>
    public IReadOnlyList<LoopbackRequest> Requests
    {
        get
        {
            lock (_gate) return [.. _requests];
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        lock (_gate)
        {
            foreach (var client in _clients) client.Dispose();
        }
    }

    private async Task AcceptAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token);
            }
            catch (Exception)
            {
                return;
            }
            lock (_gate) _clients.Add(client);
            _ = Task.Run(() => ServeAsync(client));
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        try
        {
            var first = new byte[1];
            if (await client.Client.ReceiveAsync(first, SocketFlags.Peek, _stop.Token) == 0) return;
            Stream stream = client.GetStream();
            bool tls = first[0] == 0x16;
            if (tls)
            {
                Interlocked.Increment(ref _tlsConnections);
                if (Certificate is null) return;
                var ssl = new SslStream(stream);
                await ssl.AuthenticateAsServerAsync(Certificate);
                stream = ssl;
            }
            else
            {
                Interlocked.Increment(ref _plainConnections);
            }
            var reader = new Reader(stream, _stop.Token);
            while (await ReadRequestAsync(reader, tls) is { } request)
            {
                LoopbackAnswer answer = UpgradeRequired && !tls ? LoopbackAnswer.Http(426) : AnswerFor(request);
                if (answer.Delay > TimeSpan.Zero) await Task.Delay(answer.Delay, _stop.Token);
                await WriteAnswerAsync(stream, answer);
                if (answer.ClaimedLength > answer.Body.Length) break;
            }
        }
        catch (Exception)
        {
            // The client went away, or the test is over.
        }
        finally
        {
            client.Dispose();
        }
    }

    private async Task<LoopbackRequest?> ReadRequestAsync(Reader reader, bool tls)
    {
        string? line = await reader.LineAsync();
        if (line is null) return null;
        string[] start = line.Split(' ');
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        while (await reader.LineAsync() is { Length: > 0 } header)
        {
            int colon = header.IndexOf(':');
            headers[header[..colon]] = header[(colon + 1)..].Trim();
        }
        byte[] body;
        if (headers.TryGetValue("Transfer-Encoding", out var encoding) && encoding.Contains("chunked", StringComparison.OrdinalIgnoreCase))
        {
            var chunks = new MemoryStream();
            while (Convert.ToInt32((await reader.LineAsync())!, 16) is var size and > 0)
            {
                chunks.Write(await reader.ExactlyAsync(size));
                await reader.LineAsync();
            }
            await reader.LineAsync();
            body = chunks.ToArray();
        }
        else
        {
            body = await reader.ExactlyAsync(headers.TryGetValue("Content-Length", out var length) ? int.Parse(length) : 0);
        }
        var request = new LoopbackRequest(start[0], start[1], headers, body, tls);
        lock (_gate) _requests.Add(request);
        return request;
    }

    private LoopbackAnswer AnswerFor(LoopbackRequest request)
    {
        lock (_gate)
        {
            if (_script.Count > 0) return _script.Dequeue();
        }
        switch ((IppOperation)request.Ipp.Code)
        {
            case IppOperation.GetPrinterAttributes:
                return new LoopbackAnswer(200, IppFixtures.Printer(Fixture));
            case IppOperation.PrintJob:
                return LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 3));
            case IppOperation.GetJobAttributes:
                return LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 9, "job-completed-successfully"));
            default:
                return LoopbackAnswer.Ipp(IppStatus.SuccessfulOk);
        }
    }

    private static async Task WriteAnswerAsync(Stream stream, LoopbackAnswer answer)
    {
        string framing = answer.Chunked ? "Transfer-Encoding: chunked" : $"Content-Length: {answer.ClaimedLength ?? answer.Body.Length}";
        var head = new StringBuilder($"HTTP/1.1 {answer.Status} Status\r\nContent-Type: application/ipp\r\n{framing}\r\n");
        if (answer.RetryAfter is { } after) head.Append($"Retry-After: {after}\r\n");
        head.Append("\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head.ToString()));
        if (answer.Chunked)
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"{answer.Body.Length:x}\r\n"));
            await stream.WriteAsync(answer.Body);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("\r\n0\r\n\r\n"));
        }
        else
        {
            await stream.WriteAsync(answer.Body);
        }
        await stream.FlushAsync();
    }

    private sealed class Reader(Stream stream, CancellationToken token)
    {
        private readonly byte[] _buffer = new byte[8192];
        private int _start;
        private int _end;

        private async Task<int> ByteAsync()
        {
            if (_start == _end)
            {
                _start = 0;
                _end = await stream.ReadAsync(_buffer, token);
                if (_end == 0) return -1;
            }
            return _buffer[_start++];
        }

        public async Task<string?> LineAsync()
        {
            var line = new StringBuilder();
            while (await ByteAsync() is var b and >= 0)
            {
                if (b == '\n') return line.ToString().TrimEnd('\r');
                line.Append((char)b);
            }
            return line.Length == 0 ? null : line.ToString();
        }

        public async Task<byte[]> ExactlyAsync(int count)
        {
            var result = new byte[count];
            int done = 0;
            while (done < count)
            {
                if (_start == _end)
                {
                    _start = 0;
                    _end = await stream.ReadAsync(_buffer, token);
                    if (_end == 0) throw new EndOfStreamException();
                }
                int take = Math.Min(count - done, _end - _start);
                Array.Copy(_buffer, _start, result, done, take);
                _start += take;
                done += take;
            }
            return result;
        }
    }

    /// <summary>A self-signed certificate a TLS server can serve.</summary>
    public static X509Certificate2 SelfSigned(string subject)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest($"CN={subject}", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var ephemeral = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        return X509CertificateLoader.LoadPkcs12(ephemeral.Export(X509ContentType.Pfx), null);
    }
}
