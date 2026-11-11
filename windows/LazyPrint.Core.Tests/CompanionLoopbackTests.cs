using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// The companion end to end over TLS on loopback (127.0.0.1 only): a fake phone client pairs with
// the pinned certificate, sends packages and is refused when it should be. Networks and DNS-SD are
// stand-ins, so nothing listens on or is advertised to the real network. Mirrored by
// Tests/LazyPrintTests/CompanionLoopbackTests.swift.

/// <summary>Networks a test sets and changes.</summary>
internal sealed class FakeNetworkSource : ICompanionNetworkSource
{
    private IReadOnlyList<CompanionNetwork> _networks;

    public FakeNetworkSource(params CompanionNetwork[] networks)
    {
        _networks = networks;
    }

    public IReadOnlyList<CompanionNetwork> Networks() => _networks;

    public event EventHandler? Changed;

    public void Set(params CompanionNetwork[] networks)
    {
        _networks = networks;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public static CompanionNetwork Loopback(CompanionNetworkCategory category = CompanionNetworkCategory.Private,
                                            string address = "127.0.0.1", int index = 1, string id = "{loopback}") =>
        new(id, "Test network", category, [new CompanionNetworkInterface(index, "adapter-" + index, [new LocalSubnet(IPAddress.Parse(address), 8)])]);
}

/// <summary>Records what would be advertised, and what was withdrawn.</summary>
internal sealed class FakeAdvertiser : IDnsSdAdvertiser
{
    public ConcurrentQueue<string> Log { get; } = new();
    public ConcurrentDictionary<int, DnsSdRegistration> Active { get; } = new();

    public IDisposable Register(DnsSdRegistration registration)
    {
        Active[registration.InterfaceIndex] = registration;
        Log.Enqueue($"register {registration.InterfaceIndex}:{registration.Port}");
        return new Handle(this, registration);
    }

    private sealed class Handle(FakeAdvertiser owner, DnsSdRegistration registration) : IDisposable
    {
        public void Dispose()
        {
            owner.Active.TryRemove(registration.InterfaceIndex, out _);
            owner.Log.Enqueue($"withdraw {registration.InterfaceIndex}:{registration.Port}");
        }
    }
}

/// <summary>A phone that pins the desktop's certificate by its fingerprint, as the iPhone app will.</summary>
internal sealed class FakePhone : IDisposable
{
    private readonly HttpClient _client;

    public FakePhone(byte[] pin, string id = "phone-0001")
    {
        Id = id;
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(5),
            PooledConnectionLifetime = TimeSpan.Zero,
            SslOptions = new SslClientAuthenticationOptions
            {
                // Pinning: the certificate's key must be the one in the pairing code; nothing else counts.
                RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                    certificate is not null && SpkiFingerprint.Of(certificate.GetRawCertData()) is { } fingerprint
                    && SpkiFingerprint.Matches(fingerprint, pin),
            },
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
    }

    public string Id { get; }
    public string? Secret { get; set; }
    public Uri? Base { get; set; }

    public async Task<HttpResponseMessage> PairAsync(PairingUri code, string? token = null)
    {
        Base = new Uri($"https://{code.Addresses[0]}:{code.Port}");
        var body = new StringContent(new PairRequest(token ?? code.Token, Id, "Test phone", "ios", "1.0").ToJson(), Encoding.UTF8, "application/json");
        var response = await _client.PostAsync(new Uri(Base, CompanionProtocol.PairPath), body);
        if (response.IsSuccessStatusCode)
        {
            Secret = PairResponse.FromJson(await response.Content.ReadAsByteArrayAsync())!.DeviceSecret;
        }
        return response;
    }

    public Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content = null,
                                               params (string, string)[] headers)
    {
        var request = new HttpRequestMessage(method, new Uri(Base!, path)) { Content = content };
        if (Secret is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Secret);
            request.Headers.Add(CompanionProtocol.DeviceIdHeader, Id);
        }
        foreach (var (name, value) in headers) request.Headers.Add(name, value);
        return _client.SendAsync(request);
    }

    public Task<HttpResponseMessage> UploadAsync(string packageId, byte[] package) =>
        SendAsync(HttpMethod.Put, CompanionProtocol.InboxPrefix + packageId, new ByteArrayContent(package));

    public void Dispose() => _client.Dispose();
}

[Collection(WallClockCollection.Name)]
public sealed class CompanionLoopbackTests : IAsyncLifetime
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
    private readonly FakeNetworkSource _networks = new(FakeNetworkSource.Loopback());
    private readonly FakeAdvertiser _advertiser = new();
    private readonly ConcurrentQueue<CompanionPackageReceivedEventArgs> _received = new();
    private readonly X509Certificate2 _certificate = MakeCertificate();
    private Func<X509Certificate2> _renew = MakeCertificate;
    // To the second, as packages and the outbox write dates.
    private DateTimeOffset _now = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    private CompanionService _service = null!;

    public async Task InitializeAsync()
    {
        _service = new CompanionService(new CompanionServiceOptions
        {
            SettingsDirectory = Path.Combine(_directory, "Settings"),
            DataDirectory = Path.Combine(_directory, "Data"),
            Certificate = () => _certificate,
            RenewCertificate = () => _renew(),
            Networks = _networks,
            Advertiser = _advertiser,
            Clock = () => _now,
            DesktopName = "TEST-PC",
            PreferredPort = 0,
            Server = new CompanionServerOptions { DiscardTimeout = TimeSpan.FromSeconds(1) },
        });
        _service.PackageReceived += (_, e) => _received.Enqueue(e);
        _service.Router.ApprovePairing = (_, _) => Task.FromResult(true);
        await _service.StartAsync();
    }

    public async Task DisposeAsync()
    {
        await _service.DisposeAsync();
        _certificate.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    /// <summary>A P-256 certificate whose key SChannel can use (a PFX round trip, as the app's store copy).</summary>
    internal static X509Certificate2 MakeCertificate()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Lazy Print test", key, HashAlgorithmName.SHA256);
        using var ephemeral = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
        return X509CertificateLoader.LoadPkcs12(ephemeral.Export(X509ContentType.Pfx), null);
    }

    private byte[] Pin => _service.Fingerprint;

    private async Task<(PairingUri Code, FakePhone Phone)> PairedPhone(string id = "phone-0001")
    {
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        var phone = new FakePhone(Pin, id);
        var response = await phone.PairAsync(code);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return (code, phone);
    }

    private static async Task<CompanionError?> Error(HttpResponseMessage response) =>
        CompanionError.FromJson(await response.Content.ReadAsByteArrayAsync());

    [Fact]
    public async Task NothingListens_UntilAPhoneIsPairedOrACodeIsShown()
    {
        Assert.Equal(CompanionListenState.Off, _service.Status.State);
        Assert.Empty(_service.Status.Endpoints);
        Assert.Empty(_advertiser.Active);
        Assert.Null(_service.PairingCode());
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        Assert.Equal(CompanionListenState.Listening, _service.Status.State);
        Assert.Equal(["127.0.0.1"], code.Addresses);
        Assert.Equal(_service.Status.Port, code.Port);
        Assert.Equal(SpkiFingerprint.Text(SpkiFingerprint.Of(_certificate.RawData)!), code.Fingerprint);
        Assert.Equal(code, PairingUri.Parse(code.Format()));
        var advertised = Assert.Single(_advertiser.Active.Values);
        Assert.Equal(1, advertised.InterfaceIndex);
        Assert.Equal(code.Port, advertised.Port);
        Assert.Contains(new KeyValuePair<string, string>("id", _service.Devices.DesktopId), advertised.Txt);
        // Closing the code without pairing stops listening again.
        await _service.ClosePairingAsync();
        Assert.Equal(CompanionListenState.Off, _service.Status.State);
        Assert.Empty(_advertiser.Active);
        await AssertNotListening(code.Port);
    }

    [Fact]
    public async Task Pair_ThenSend_ReceivesTheBatchOnce()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        var device = Assert.Single(_service.Devices.Devices);
        Assert.Equal("Test phone", device.Name);
        Assert.Equal(PairedDeviceStore.HashSecret(CompanionProtocol.DecodeBase64Url(phone.Secret)!), device.SecretHash);
        Assert.Null(_service.Pairing);

        var hello = HelloResponse.FromJson(await (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).Content.ReadAsByteArrayAsync());
        Assert.Equal("TEST-PC", hello?.DesktopName);
        var health = HealthResponse.FromJson(await (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HealthPath)).Content.ReadAsByteArrayAsync());
        Assert.Equal(new HealthResponse(1, true), health);

        byte[] first = CompanionFixtures.Package("batch-0001", 0, 2, "Report.pdf");
        byte[] last = CompanionFixtures.Package("batch-0001", 1, 2, "Report.pdf");
        var created = await phone.UploadAsync("package-0001", first);
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        Assert.Equal(new InboxResponse("package-0001", false), InboxResponse.FromJson(await created.Content.ReadAsByteArrayAsync()));
        var again = await phone.UploadAsync("package-0001", first);
        Assert.Equal(HttpStatusCode.OK, again.StatusCode);
        Assert.Equal(new InboxResponse("package-0001", true), InboxResponse.FromJson(await again.Content.ReadAsByteArrayAsync()));
        Assert.Single(_received);
        Assert.False(Assert.Single(_service.Inbox.Batches(_now)).IsWhole(_now));

        Assert.Equal(HttpStatusCode.Created, (await phone.UploadAsync("package-0002", last)).StatusCode);
        Assert.Equal(2, _received.Count);
        var batch = Assert.Single(_service.Inbox.Batches(_now));
        Assert.True(batch.IsWhole(_now));
        // The paired phone's name, not the one in the package.
        Assert.Equal("Test phone", batch.From);
        string[] files = [.. _service.Inbox.Take("batch-0001", _now)];
        Assert.Equal([Path.Combine(_directory, "Data", "Inbox", "batch-0001", "Report.pdf"),
                      Path.Combine(_directory, "Data", "Inbox", "batch-0001", "Report (2).pdf")], files);
        Assert.Equal(CompanionFixtures.Pdf, File.ReadAllBytes(files[1]));
        Assert.Empty(_service.Inbox.Batches(_now));
    }

    [Fact]
    public async Task WrongFingerprint_IsRefusedBeforeAnythingIsSent()
    {
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        var other = (byte[])Pin.Clone();
        other[0] ^= 0xFF;
        using var phone = new FakePhone(other);
        await Assert.ThrowsAsync<HttpRequestException>(() => phone.PairAsync(code));
        Assert.Empty(_service.Devices.Devices);
        Assert.NotNull(_service.Pairing);
        // The right pin still pairs with the same code.
        using var right = new FakePhone(Pin);
        Assert.Equal(HttpStatusCode.OK, (await right.PairAsync(code)).StatusCode);
    }

    [Fact]
    public async Task ExpiredAndReusedTokens_AreRefused()
    {
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        // A second, still-listening reason: a paired phone keeps the server up after the code expires.
        using var first = new FakePhone(Pin, "phone-0001");
        Assert.Equal(HttpStatusCode.OK, (await first.PairAsync(code)).StatusCode);
        using var second = new FakePhone(Pin, "phone-0002");
        var reused = await second.PairAsync(code);
        Assert.Equal(HttpStatusCode.Forbidden, reused.StatusCode);
        Assert.Equal(CompanionErrorCode.TokenUsed, (await Error(reused))?.Code);

        var fresh = await _service.OpenPairingAsync();
        Assert.NotNull(fresh);
        _now += PairingSession.Lifetime;
        var expired = await second.PairAsync(fresh);
        Assert.Equal(CompanionErrorCode.TokenExpired, (await Error(expired))?.Code);
        var wrong = await second.PairAsync(fresh, CompanionVectors.TokenText);
        Assert.Equal(HttpStatusCode.Forbidden, wrong.StatusCode);
        Assert.Single(_service.Devices.Devices);
    }

    [Fact]
    public async Task RemovedPhone_Gets401AndOthersKeepWorking()
    {
        var (_, kept) = await PairedPhone("phone-0001");
        var (_, removed) = await PairedPhone("phone-0002");
        using var a = kept;
        using var b = removed;
        Assert.Equal(HttpStatusCode.OK, (await removed.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);
        await _service.RemoveDeviceAsync("phone-0002");
        var refused = await removed.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath);
        Assert.Equal(HttpStatusCode.Unauthorized, refused.StatusCode);
        Assert.Equal(CompanionErrorCode.Unauthorized, (await Error(refused))?.Code);
        Assert.Equal(HttpStatusCode.Unauthorized, (await removed.UploadAsync("package-0001", CompanionFixtures.Package())).StatusCode);
        Assert.Empty(_received);
        Assert.Equal(HttpStatusCode.OK, (await kept.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);
        // The phone forgetting the desktop works the same way.
        Assert.Equal(HttpStatusCode.NoContent, (await kept.SendAsync(HttpMethod.Delete, CompanionProtocol.DeviceSelfPath)).StatusCode);
        Assert.Empty(_service.Devices.Devices);
    }

    [Fact]
    public async Task ForgettingAPhone_DeletesWhatItSentThatWaits()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        Assert.Equal(HttpStatusCode.Created, (await phone.UploadAsync("package-0001", CompanionFixtures.Package())).StatusCode);
        Assert.NotEmpty(_service.Inbox.Batches(_now));

        await _service.RemoveDeviceAsync("phone-0001");

        Assert.Empty(_service.Inbox.Batches(_now));
    }

    [Fact]
    public async Task APhoneForgettingTheDesktop_DeletesWhatItSentThatWaits()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        Assert.Equal(HttpStatusCode.Created, (await phone.UploadAsync("package-0001", CompanionFixtures.Package())).StatusCode);

        Assert.Equal(HttpStatusCode.NoContent, (await phone.SendAsync(HttpMethod.Delete, CompanionProtocol.DeviceSelfPath)).StatusCode);

        Assert.Empty(_service.Inbox.Batches(_now));
    }

    [Fact]
    public async Task MaliciousPackages_AreRefusedAndNotKept()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        byte[] damaged = CompanionFixtures.Package();
        damaged[0] ^= 0xFF;
        byte[] notAPdf = CompanionFixtures.Package();
        notAPdf[PrintPackage.Read(notAPdf).DataOffset] ^= 0xFF;
        byte[] traversal = CompanionFixtures.Raw("""{"name":"../../evil.pdf","contentType":"application/pdf","batch":"batch-0001","index":0,"count":1,"from":"x"}""");
        foreach (var (id, bytes) in new[] { ("package-0001", traversal), ("package-0002", damaged), ("package-0003", notAPdf),
                                             ("package-0004", Encoding.ASCII.GetBytes("PK not really")) })
        {
            var response = await phone.UploadAsync(id, bytes);
            Assert.Equal((HttpStatusCode)422, response.StatusCode);
            Assert.Equal(CompanionErrorCode.InvalidPackage, (await Error(response))?.Code);
        }
        Assert.Empty(_received);
        Assert.Empty(_service.Inbox.Batches(_now));
        Assert.False(File.Exists(Path.Combine(_directory, "Data", "evil.pdf")));
        Assert.False(File.Exists(Path.Combine(_directory, "evil.pdf")));
    }

    [Fact]
    public async Task OversizeAndChunkedUploads_AreRefusedWithoutTheirBody()
    {
        var (code, phone) = await PairedPhone();
        using var owned = phone;
        string auth = $"Authorization: Bearer {phone.Secret}\r\n{CompanionProtocol.DeviceIdHeader}: {phone.Id}\r\n";
        long tooLarge = CompanionProtocol.MaxUploadBytes + 1;
        var (status, text) = await Raw(code.Port, $"PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {tooLarge}\r\nExpect: 100-continue\r\n\r\n");
        Assert.Equal(413, status);
        Assert.DoesNotContain("100 Continue", text);
        Assert.Contains("\"tooLarge\"", text);
        (status, _) = await Raw(code.Port, $"PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {tooLarge}\r\n\r\n");
        Assert.Equal(413, status);
        (status, _) = await Raw(code.Port, $"PUT /v1/inbox/package-0001 HTTP/1.1\r\nHost: x\r\n{auth}Transfer-Encoding: chunked\r\n\r\n");
        Assert.Equal(501, status);
        (status, _) = await Raw(code.Port, "GET /v1/health HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n");
        Assert.Equal(400, status);
        // An upload that asks to wait gets "100 Continue", then its answer.
        byte[] package = CompanionFixtures.Package();
        (status, text) = await Raw(code.Port, $"PUT /v1/inbox/package-0009 HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {package.Length}\r\nExpect: 100-continue\r\n\r\n",
                                   package, waitForContinue: true);
        Assert.Equal(201, status);
        Assert.Single(_received);
    }

    [Fact]
    public async Task RefusedRequest_WithABodyThatTrickles_IsClosedAfterTheDiscardTimeout()
    {
        var (code, phone) = await PairedPhone();
        using var owned = phone;
        await _service.ClosePairingAsync();
        var started = DateTime.UtcNow;
        var (status, _) = await Raw(code.Port, "POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 8192\r\n\r\n", new byte[1]);
        Assert.Equal(403, status);
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(8));
    }

    [Fact]
    public async Task OneAddress_LeavesRoomForTheOthers()
    {
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        var held = new List<SslStream>();
        try
        {
            // A handshake, as a plain connect also succeeds for a connection the server then drops.
            for (int i = 0; i < new CompanionServerOptions().MaxConnectionsPerPeer; i++) held.Add(await Handshake("127.0.0.1", code.Port));

            using var refused = new TcpClient();
            await refused.ConnectAsync(IPAddress.Loopback, code.Port);
            int read;
            try
            {
                read = await refused.GetStream().ReadAsync(new byte[1]).AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (IOException)
            {
                read = 0;
            }
            Assert.Equal(0, read);

            await using var other = await Handshake("127.0.0.2", code.Port);
        }
        finally
        {
            held.ForEach(tls => tls.Dispose());
        }
    }

    [Fact]
    public async Task PlainHttp_GetsNoAnswer()
    {
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, code.Port);
        var stream = tcp.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n"));
        var buffer = new byte[1024];
        int read;
        try
        {
            read = await stream.ReadAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(15));
        }
        catch (IOException)
        {
            read = 0;
        }
        Assert.False(Encoding.ASCII.GetString(buffer, 0, read).StartsWith("HTTP/", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Listener_StopsWhenTheNetworkIsNoLongerTrusted()
    {
        var (code, phone) = await PairedPhone();
        using var owned = phone;
        Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HealthPath)).StatusCode);
        Assert.Single(_advertiser.Active);

        // The network turns Public (not approved): nothing listens or is advertised any more.
        _networks.Set(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public));
        await _service.RefreshAsync();
        Assert.Equal(CompanionListenState.NoTrustedNetwork, _service.Status.State);
        Assert.Empty(_advertiser.Active);
        Assert.Contains($"withdraw 1:{code.Port}", _advertiser.Log);
        await AssertNotListening(code.Port);
        await Assert.ThrowsAsync<HttpRequestException>(() => phone.SendAsync(HttpMethod.Get, CompanionProtocol.HealthPath));

        // The user allows receiving on it: listening again, on the same port.
        Assert.True(await _service.SetNetworkApprovedAsync(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public), true));
        Assert.Equal(CompanionListenState.Listening, _service.Status.State);
        Assert.Equal(code.Port, _service.Status.Port);
        Assert.Single(_advertiser.Active);
        Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);

        // Withdrawn again, then offline.
        await _service.SetNetworkApprovedAsync(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public), false);
        await AssertNotListening(code.Port);
        _networks.Set();
        await _service.RefreshAsync();
        Assert.Equal(CompanionListenState.Offline, _service.Status.State);
        Assert.Empty(_advertiser.Active);
    }

    [Fact]
    public async Task OnlyTrustedInterfaces_AreListenedOnAndAdvertised()
    {
        _networks.Set(FakeNetworkSource.Loopback(),
                      FakeNetworkSource.Loopback(CompanionNetworkCategory.Public, "127.0.0.2", 2, "{public}"));
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        Assert.Equal(["127.0.0.1"], _service.Status.Endpoints.Select(e => e.Address.ToString()));
        Assert.Equal([1], _advertiser.Active.Keys);
        await AssertNotListening(code.Port, "127.0.0.2");

        await _service.SetNetworkApprovedAsync(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public, "127.0.0.2", 2, "{public}"), true);
        Assert.Equal(["127.0.0.1", "127.0.0.2"], _service.Status.Endpoints.Select(e => e.Address.ToString()).Order());
        Assert.Equal([1, 2], _advertiser.Active.Keys.Order());
        Assert.All(_service.Status.Endpoints, e => Assert.Equal(code.Port, e.Port));
    }

    [Fact]
    public async Task RepeatedWrongSecrets_AreCutOff()
    {
        var (code, phone) = await PairedPhone();
        using var owned = phone;
        string secret = phone.Secret!;
        phone.Secret = CompanionVectors.SecretText;
        for (int i = 0; i < CompanionRateLimiter.MaxFailures; i++)
        {
            Assert.Equal(HttpStatusCode.Unauthorized, (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);
        }
        // Blocked: the connection is closed before TLS, even with the right secret.
        phone.Secret = secret;
        await Assert.ThrowsAsync<HttpRequestException>(() => phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath));
        _now += CompanionRateLimiter.Window;
        Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);
        Assert.Equal(code.Port, _service.Status.Port);
    }

    [Fact]
    public async Task ResetPairing_ChangesTheKeyAndUnpairsEveryone()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        byte[] before = Pin;
        Assert.Equal(HttpStatusCode.Created, (await phone.UploadAsync("package-0001", CompanionFixtures.Package())).StatusCode);
        await _service.ResetPairingAsync();
        Assert.Empty(_service.Devices.Devices);
        Assert.Empty(_service.Inbox.Batches(_now));
        Assert.NotEqual(before, _service.Fingerprint);
        Assert.Equal(CompanionListenState.Off, _service.Status.State);
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        // The old pin no longer connects.
        phone.Base = new Uri($"https://127.0.0.1:{code.Port}");
        await Assert.ThrowsAsync<HttpRequestException>(() => phone.SendAsync(HttpMethod.Get, CompanionProtocol.HealthPath));
    }

    [Fact]
    public async Task APhoneWaitingForTheAnswer_KeepsTheHostListening()
    {
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _service.Router.ApprovePairing = (_, _) => answer.Task;
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        using var phone = new FakePhone(Pin);
        var pairing = phone.PairAsync(code);
        await WaitUntil(() => _service.AwaitingApproval);
        // The session is used, and the code's five minutes run out while the user reads the question;
        // refreshes (the code's timer, a network change) keep listening for the phone.
        Assert.Null(_service.Pairing);
        _now += PairingSession.Lifetime + TimeSpan.FromMinutes(1);
        await _service.RefreshAsync();
        _networks.Set(FakeNetworkSource.Loopback());
        await _service.RefreshAsync();
        Assert.Equal(CompanionListenState.Listening, _service.Status.State);
        Assert.True(_service.Snapshot().PairingOpen);
        answer.SetResult(true);
        Assert.Equal(HttpStatusCode.OK, (await pairing).StatusCode);
        Assert.False(_service.AwaitingApproval);
        Assert.Single(_service.Devices.Devices);
        Assert.Equal(CompanionListenState.Listening, _service.Status.State);
    }

    [Fact]
    public async Task ADeclinedPhone_StopsTheListeningItKeptUp()
    {
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _service.Router.ApprovePairing = (_, _) => answer.Task;
        var code = await _service.OpenPairingAsync();
        Assert.NotNull(code);
        using var phone = new FakePhone(Pin);
        var pairing = phone.PairAsync(code);
        await WaitUntil(() => _service.AwaitingApproval);
        answer.SetResult(false);
        var declined = await pairing;
        Assert.Equal(HttpStatusCode.Forbidden, declined.StatusCode);
        Assert.Equal(CompanionErrorCode.Declined, (await Error(declined))?.Code);
        // Nothing is wanted any more: no phone, the code used.
        await WaitUntil(() => _service.Status.State == CompanionListenState.Off);
        Assert.Empty(_advertiser.Active);
        await AssertNotListening(code.Port);
    }

    [Fact]
    public async Task OpenPairing_WithoutATrustedNetwork_LeavesNoSessionOpen()
    {
        _networks.Set(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public));
        Assert.Null(await _service.OpenPairingAsync());
        // The status keeps the reason for the window, and no session waits for a code nobody saw.
        Assert.Equal(CompanionListenState.NoTrustedNetwork, _service.Status.State);
        Assert.Null(_service.Pairing);
        Assert.False(_service.Snapshot().PairingOpen);
        // Allowing the network later starts nothing: no code is shown, no phone is paired.
        Assert.True(await _service.SetNetworkApprovedAsync(FakeNetworkSource.Loopback(CompanionNetworkCategory.Public), true));
        Assert.Equal(CompanionListenState.Off, _service.Status.State);
        Assert.Empty(_advertiser.Active);
        Assert.Empty(_service.Status.Endpoints);
        // Pairing again now shows a code.
        Assert.NotNull(await _service.OpenPairingAsync());
    }

    [Fact]
    public async Task ResetPairing_WithoutANewKey_ChangesNothing()
    {
        var (_, phone) = await PairedPhone();
        using var owned = phone;
        byte[] before = Pin;
        _renew = () => throw new CryptographicException("The key could not be made.");
        await Assert.ThrowsAsync<CryptographicException>(() => _service.ResetPairingAsync());
        Assert.Single(_service.Devices.Devices);
        Assert.Equal(before, _service.Fingerprint);
        Assert.Equal(HttpStatusCode.OK, (await phone.SendAsync(HttpMethod.Get, CompanionProtocol.HelloPath)).StatusCode);
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Timed out waiting.");
            await Task.Delay(20);
        }
    }

    private static async Task<SslStream> Handshake(string from, int port)
    {
        var tcp = new TcpClient(new IPEndPoint(IPAddress.Parse(from), 0));
        await tcp.ConnectAsync(IPAddress.Loopback, port);
        var tls = new SslStream(tcp.GetStream(), false, (_, _, _, _) => true);
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "localhost" }).WaitAsync(TimeSpan.FromSeconds(5));
        return tls;
    }

    private static async Task AssertNotListening(int port, string address = "127.0.0.1")
    {
        using var tcp = new TcpClient();
        await Assert.ThrowsAnyAsync<SocketException>(() => tcp.ConnectAsync(IPAddress.Parse(address), port));
    }

    /// <summary>Sends a hand-written request over TLS (any certificate) and reads the status and whole answer.</summary>
    private static async Task<(int Status, string Text)> Raw(int port, string head, byte[]? body = null, bool waitForContinue = false)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, port);
        await using var tls = new SslStream(tcp.GetStream(), false, (_, _, _, _) => true);
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = "localhost" });
        await tls.WriteAsync(Encoding.ASCII.GetBytes(head));
        var answer = new MemoryStream();
        var buffer = new byte[65536];
        if (body is not null)
        {
            if (waitForContinue)
            {
                int read = await tls.ReadAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
                Assert.Equal("HTTP/1.1 100 Continue\r\n\r\n", Encoding.ASCII.GetString(buffer, 0, read));
            }
            await tls.WriteAsync(body);
        }
        while (true)
        {
            int read;
            try
            {
                read = await tls.ReadAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            }
            catch (IOException)
            {
                break;
            }
            if (read == 0) break;
            answer.Write(buffer, 0, read);
        }
        string text = Encoding.UTF8.GetString(answer.ToArray());
        return (int.Parse(text.Split(' ')[1], System.Globalization.CultureInfo.InvariantCulture), text);
    }

    [Fact]
    public async Task Server_KeepsServingOnTheAddressesThatBound_AndBindsTheOthersLater()
    {
        using var blocker = new TcpListener(IPAddress.Parse("127.0.0.1"), 0);
        blocker.Server.ExclusiveAddressUse = true;
        blocker.Start();
        int port = ((IPEndPoint)blocker.LocalEndpoint).Port;
        var router = new CompanionRouter(new PairedDeviceStore(Path.Combine(_directory, "Router")),
                                         new CompanionInbox(Path.Combine(_directory, "RouterInbox")), new CompanionRateLimiter(), () => _now);
        await using var server = new CompanionServer(_certificate, router, new CompanionRateLimiter());
        var bound = server.Start([new IPEndPoint(IPAddress.Parse("127.0.0.1"), port), new IPEndPoint(IPAddress.Parse("127.0.0.2"), port)]);
        Assert.Equal(IPAddress.Parse("127.0.0.2"), Assert.Single(bound).Address);
        Assert.Equal(IPAddress.Parse("127.0.0.1"), Assert.Single(server.FailedEndpoints).Address);
        Assert.False(server.RetryFailed());
        blocker.Stop();
        Assert.True(server.RetryFailed());
        Assert.Equal(2, server.LocalEndpoints.Count);
        Assert.Empty(server.FailedEndpoints);
    }
}
